#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifndef CvISXSUB
# define CvISXSUB(cv) !!CvXSUB(cv)
#endif /* !CvISXSUB */

#ifndef SvSTASH_set
# define SvSTASH_set(sv, stash) (SvSTASH(sv) = (stash))
#endif /* !SvSTASH_set */

static SV *safe_av_fetch(AV *av, I32 key)
{
	SV **item_ptr = av_fetch(av, key, 0);
	return item_ptr ? *item_ptr : &PL_sv_undef;
}

static void sv_unbless(SV *sv)
{
	SV *oldstash;
	if(!SvOBJECT(sv)) return;
	SvOBJECT_off(sv);
	if((oldstash = (SV*)SvSTASH(sv))) {
		SvSTASH_set(sv, NULL);
		SvREFCNT_dec(oldstash);
	}
}

#define sv_is_undef(sv) (SvTYPE(sv) != SVt_PVGV && !SvOK(sv))

#define sv_is_string(sv) \
	(SvTYPE(sv) != SVt_PVGV && \
	 (SvFLAGS(sv) & (SVf_IOK|SVf_NOK|SVf_POK|SVp_IOK|SVp_NOK|SVp_POK)))

/*
 * when_sub_bodied() mechanism:
 *
 * Pending actions to apply to a sub are handled in several stages.  The
 * mechanism is quite convoluted, which is unavoidable given the lack of
 * support from the core.
 *
 * Initially, when an action is to be tied to a partially-built sub, a
 * marker object gets stored in the sub's pad.  Specifically, it is
 * added to the slot used by the @_-in-waiting.  The pad and the future
 * @_ will be created if necessary.  If the pad gets thrown away, by the
 * CV dying or being "undef"ed, the marker object also dies, and the
 * actions are never triggered.  If the partial sub content is moved
 * from one CV to another, such as by "sub foo; sub foo { ... }", the
 * marker moves with it.  The marker doesn't know which CV it is
 * attached to; it is the presence of the marker in a CV's pad that is
 * significant.
 *
 * The actions waiting to be performed are stored in the marker object.
 * If another action is requested, on a CV that already has a marker, it
 * gets added to the existing marker.
 *
 * When a partially-built sub gets its body attached, the peephole
 * optimiser is triggered.  Code in this module is in the chain, and
 * looks for the marker.  If present, it removes the marker from the
 * CV (actually: makes it a non-marker) and starts processing actions.
 *
 * While actions are being processed, the queue of pending actions is
 * made accessible through a chain of AVs (whenbodied_running).  If
 * another action is requested, while this is in progress, it gets added
 * to the queue.
 *
 * If an action is requested on a sub that already has a body and does
 * not have a running queue, the queueing function sets up a running
 * queue and starts processing actions.  Doing this, rather than just
 * performing the action directly, keeps actions sequential, in case
 * another action is requested while one is already executing.
 */

static void (*whenbodied_next_peep)(pTHX_ OP*);
static void whenbodied_peep(pTHX_ OP*);
static SV *whenbodied_running;
static HV *stash_whenbodied;

static AV *new_minimal_padlist(void)
{
	AV *padlist, *pad;
	pad = newAV();
	av_store(pad, 0, &PL_sv_undef);
	padlist = newAV();
	AvREAL_off(padlist);
	av_extend(padlist, 1);
	av_store(padlist, 0, (SV*)newAV());
	av_store(padlist, 1, (SV*)pad);
	return padlist;
}

static AV *cv_find_whenbodied(CV *sub)
{
	AV *padlist;
	AV *argav;
	I32 pos;
	if(CvDEPTH(sub) != 0) return NULL;
	padlist = CvPADLIST(sub);
	if(!padlist) return NULL;
	argav = (AV*)safe_av_fetch((AV*)*av_fetch(padlist, 1, 0), 0);
	if(SvTYPE((SV*)argav) != SVt_PVAV) return NULL;
	for(pos = av_len(argav); pos >= 0; pos--) {
		SV *v = safe_av_fetch(argav, pos);
		if(SvTYPE(v) == SVt_PVAV && SvOBJECT(v) &&
				SvSTASH(v) == stash_whenbodied)
			return (AV*)v;
	}
	return NULL;
}

static AV *cv_force_whenbodied(CV *sub)
{
	AV *padlist;
	AV *pad, *argav, *wb;
	I32 pos;
	padlist = CvPADLIST(sub);
	if(!padlist) goto create_padlist;
	pad = (AV*)*av_fetch(padlist, 1, 0);
	argav = (AV*)safe_av_fetch(pad, 0);
	if(SvTYPE((SV*)argav) != SVt_PVAV) goto create_argav;
	for(pos = av_len(argav); pos >= 0; pos--) {
		SV *v = safe_av_fetch(argav, pos);
		if(SvTYPE(v) == SVt_PVAV && SvOBJECT(v) &&
				SvSTASH(v) == stash_whenbodied)
			return (AV*)v;
	}
	goto create_whenbodied;
	create_padlist:
	CvPADLIST(sub) = padlist = new_minimal_padlist();
	create_argav:
	argav = newAV();
	av_extend(argav, 0);
	av_store(pad, 0, (SV*)argav);
	create_whenbodied:
	wb = newAV();
	sv_bless(sv_2mortal(newRV_inc((SV*)wb)), stash_whenbodied);
	av_push(argav, (SV*)wb);
	if(!whenbodied_next_peep) {
		whenbodied_next_peep = PL_peepp;
		PL_peepp = whenbodied_peep;
	}
	return wb;
}

static AV *whenbodied_find_running(CV *sub)
{
	AV *runav = (AV*)whenbodied_running;
	while(SvTYPE((SV*)runav) == SVt_PVAV) {
		CV *runsubject = (CV*)*av_fetch(runav, 0, 0);
		if(runsubject == sub)
			return (AV*)*av_fetch(runav, 1, 0);
		runav = (AV*)*av_fetch(runav, 2, 0);
	}
	return NULL;
}

static void whenbodied_setup_run(CV *sub, AV *wb)
{
	AV *runav = newAV();
	av_extend(runav, 2);
	av_store(runav, 0, SvREFCNT_inc((SV*)sub));
	av_store(runav, 1, SvREFCNT_inc((SV*)wb));
	av_store(runav, 2, SvREFCNT_inc(whenbodied_running));
	SAVEGENERICSV(whenbodied_running);
	whenbodied_running = (SV*)runav;
}

static void whenbodied_run_actions(CV *sub, AV *wb)
{
	SV *subject_ref = sv_2mortal(newRV_inc((SV*)sub));
	while(av_len(wb) != -1) {
		dSP;
		PUSHMARK(SP);
		XPUSHs(subject_ref);
		PUTBACK;
		call_sv(sv_2mortal(av_shift(wb)), G_VOID|G_DISCARD);
	}
}

static void whenbodied_peep(pTHX_ OP*o)
{
	CV *sub = PL_compcv;
	AV *wb = cv_find_whenbodied(PL_compcv);
	if(!wb || whenbodied_find_running(sub)) {
		whenbodied_next_peep(aTHX_ o);
		return;
	}
	ENTER;
	whenbodied_setup_run(sub, wb);
	sv_unbless((SV*)wb);
	whenbodied_next_peep(aTHX_ o);
	whenbodied_run_actions(sub, wb);
	LEAVE;
}

static void when_sub_bodied(CV *sub, CV *action)
{
	AV *wb;
	if(!CvROOT(sub) && !CvXSUB(sub)) {
		wb = cv_force_whenbodied(sub);
		av_push(wb, SvREFCNT_inc((SV*)action));
	} else if((wb = cv_find_whenbodied(sub))) {
		av_push(wb, SvREFCNT_inc((SV*)action));
	} else if((wb = whenbodied_find_running(sub))) {
		av_push(wb, SvREFCNT_inc((SV*)action));
	} else {
		wb = newAV();
		av_push(wb, SvREFCNT_inc((SV*)action));
		ENTER;
		whenbodied_setup_run(sub, wb);
		SvREFCNT_dec(wb);
		whenbodied_run_actions(sub, wb);
		LEAVE;
	}
}

MODULE = Sub::Mutate PACKAGE = Sub::Mutate

BOOT:
	stash_whenbodied = gv_stashpv("Sub::Mutate::__WHEN_BODIED__", 1);
	whenbodied_running = &PL_sv_no;

const char *
sub_body_type(CV *sub)
PROTOTYPE: $
CODE:
	if(!CvROOT(sub) && !CvXSUB(sub)) {
		RETVAL = "UNDEF";
	} else {
		RETVAL = CvISXSUB(sub) ? "XSUB" : "PERL";
	}
OUTPUT:
	RETVAL

const char *
sub_closure_role(CV *sub)
PROTOTYPE: $
CODE:
	RETVAL = CvCLONED(sub) ? "CLOSURE" :
		CvCLONE(sub) ? "PROTOTYPE" :
		"STANDALONE";
OUTPUT:
	RETVAL

bool
sub_is_lvalue(CV *sub)
PROTOTYPE: $
CODE:
	RETVAL = !!CvLVALUE(sub);
OUTPUT:
	RETVAL

bool
sub_is_constant(CV *sub)
PROTOTYPE: $
CODE:
	RETVAL = !!CvCONST(sub);
OUTPUT:
	RETVAL

bool
sub_is_method(CV *sub)
PROTOTYPE: $
CODE:
	RETVAL = !!CvMETHOD(sub);
OUTPUT:
	RETVAL

void
mutate_sub_is_method(CV *sub, bool new_methodness)
PROTOTYPE: $$
CODE:
	if(new_methodness) {
		CvMETHOD_on(sub);
	} else {
		CvMETHOD_off(sub);
	}

bool
sub_is_debuggable(CV *sub)
PROTOTYPE: $
CODE:
	RETVAL = !CvNODEBUG(sub);
OUTPUT:
	RETVAL

void
mutate_sub_is_debuggable(CV *sub, bool new_debuggability)
PROTOTYPE: $$
CODE:
	if(new_debuggability) {
		CvNODEBUG_off(sub);
	} else {
		CvNODEBUG_on(sub);
	}

SV *
sub_prototype(CV *sub)
PROTOTYPE: $
CODE:
	RETVAL = SvPOK(sub) ? newSVpvn(SvPVX(sub), SvCUR(sub)) : &PL_sv_undef;
OUTPUT:
	RETVAL

void
mutate_sub_prototype(CV *sub, SV *new_prototype)
PROTOTYPE: $$
CODE:
	if(sv_is_undef(new_prototype)) {
		SvPOK_off((SV*)sub);
	} else if(sv_is_string(new_prototype)) {
		STRLEN proto_len;
		char *proto_chars;
		if(SvUTF8(new_prototype)) {
			new_prototype = sv_2mortal(newSVsv(new_prototype));
			sv_utf8_downgrade(new_prototype, 0);
		}
		proto_chars = SvPV((SV*)new_prototype, proto_len);
		sv_setpvn((SV*)sub, proto_chars, proto_len);
	} else {
		croak("new_prototype is not a string or undef");
	}

void
when_sub_bodied(CV *sub, CV *action)
PROTOTYPE: $$
