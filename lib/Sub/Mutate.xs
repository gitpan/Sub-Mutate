#define PERL_NO_GET_CONTEXT 1
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define PERL_VERSION_DECIMAL(r,v,s) (r*1000000 + v*1000 + s)
#define PERL_DECIMAL_VERSION \
	PERL_VERSION_DECIMAL(PERL_REVISION,PERL_VERSION,PERL_SUBVERSION)
#define PERL_VERSION_GE(r,v,s) \
	(PERL_DECIMAL_VERSION >= PERL_VERSION_DECIMAL(r,v,s))

#ifndef CvISXSUB
# define CvISXSUB(cv) !!CvXSUB(cv)
#endif /* !CvISXSUB */

#ifndef SvSTASH_set
# define SvSTASH_set(sv, stash) (SvSTASH(sv) = (stash))
#endif /* !SvSTASH_set */

#ifndef gv_stashpvs
# define gv_stashpvs(name, flags) gv_stashpvn(""name"", sizeof(name)-1, flags)
#endif /* !gv_stashpvs */

#ifdef PadlistARRAY
# define QUSE_PADLIST_STRUCT 1
#else /* !PadlistARRAY */
# define QUSE_PADLIST_STRUCT 0
typedef AV PADNAMELIST;
# define PadlistARRAY(pl) ((PAD**)AvARRAY(pl))
# define PadlistNAMES(pl) (PadlistARRAY(pl)[0])
#endif /* !PadlistARRAY */

#define safe_av_fetch(av, key) THX_safe_av_fetch(aTHX_ av, key)
static SV *THX_safe_av_fetch(pTHX_ AV *av, I32 key)
{
	SV **item_ptr = av_fetch(av, key, 0);
	return item_ptr ? *item_ptr : &PL_sv_undef;
}

#define sv_unbless(sv) THX_sv_unbless(aTHX_ sv)
static void THX_sv_unbless(pTHX_ SV *sv)
{
	SV *oldstash;
	if(!SvOBJECT(sv)) return;
	SvOBJECT_off(sv);
	if((oldstash = (SV*)SvSTASH(sv))) {
		PL_sv_objcount--;
		SvSTASH_set(sv, NULL);
		SvREFCNT_dec(oldstash);
	}
}

#define sv_is_glob(sv) (SvTYPE(sv) == SVt_PVGV)

#if PERL_VERSION_GE(5,11,0)
# define sv_is_regexp(sv) (SvTYPE(sv) == SVt_REGEXP)
#else /* <5.11.0 */
# define sv_is_regexp(sv) 0
#endif /* <5.11.0 */

#define sv_is_undef(sv) (!sv_is_glob(sv) && !sv_is_regexp(sv) && !SvOK(sv))

#define sv_is_string(sv) \
	(!sv_is_glob(sv) && !sv_is_regexp(sv) && \
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

#define new_minimal_padlist() THX_new_minimal_padlist(aTHX)
static PADLIST *THX_new_minimal_padlist(pTHX)
{
	PADLIST *padlist;
	PAD *pad;
	PADNAMELIST *padname;
	pad = newAV();
	av_store(pad, 0, &PL_sv_undef);
#if QUSE_PADLIST_STRUCT
	Newxz(padlist, 1, PADLIST);
	Newx(PadlistARRAY(padlist), 2, PAD *);
#else /* !QUSE_PADLIST_STRUCT */
	padlist = newAV();
# if !PERL_VERSION_GE(5,15,3)
	AvREAL_off(padlist);
# endif /* < 5.15.3 */
	av_extend(padlist, 1);
#endif /* !QUSE_PADLIST_STRUCT */
	padname = newAV();
#ifdef AvPAD_NAMELIST_on
	AvPAD_NAMELIST_on(padname);
#endif /* AvPAD_NAMELIST_on */
	PadlistNAMES(padlist) = padname;
	PadlistARRAY(padlist)[1] = pad;
	return padlist;
}

#define cv_find_whenbodied(sub) THX_cv_find_whenbodied(aTHX_ sub)
static AV *THX_cv_find_whenbodied(pTHX_ CV *sub)
{
	PADLIST *padlist;
	AV *argav;
	I32 pos;
	if(CvDEPTH(sub) != 0) return NULL;
	padlist = CvPADLIST(sub);
	if(!padlist) return NULL;
	argav = (AV*)safe_av_fetch(PadlistARRAY(padlist)[1], 0);
	if(SvTYPE((SV*)argav) != SVt_PVAV) return NULL;
	for(pos = av_len(argav); pos >= 0; pos--) {
		SV *v = safe_av_fetch(argav, pos);
		if(SvTYPE(v) == SVt_PVAV && SvOBJECT(v) &&
				SvSTASH(v) == stash_whenbodied)
			return (AV*)v;
	}
	return NULL;
}

#define cv_force_whenbodied(sub) THX_cv_force_whenbodied(aTHX_ sub)
static AV *THX_cv_force_whenbodied(pTHX_ CV *sub)
{
	PADLIST *padlist;
	PAD *pad;
	AV *argav, *wb;
	I32 pos;
	padlist = CvPADLIST(sub);
	if(!padlist) goto create_padlist;
	pad = PadlistARRAY(padlist)[1];
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
	pad = PadlistARRAY(padlist)[1];
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

#define whenbodied_find_running(sub) THX_whenbodied_find_running(aTHX_ sub)
static AV *THX_whenbodied_find_running(pTHX_ CV *sub)
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

#define whenbodied_setup_run(sub, wb) THX_whenbodied_setup_run(aTHX_ sub, wb)
static void THX_whenbodied_setup_run(pTHX_ CV *sub, AV *wb)
{
	AV *runav = newAV();
	av_extend(runav, 2);
	av_store(runav, 0, SvREFCNT_inc((SV*)sub));
	av_store(runav, 1, SvREFCNT_inc((SV*)wb));
	av_store(runav, 2, SvREFCNT_inc(whenbodied_running));
	SAVEGENERICSV(whenbodied_running);
	whenbodied_running = (SV*)runav;
}

#define whenbodied_run_actions(sub, wb) \
	THX_whenbodied_run_actions(aTHX_ sub, wb)
static void THX_whenbodied_run_actions(pTHX_ CV *sub, AV *wb)
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

#define when_sub_bodied(sub, action) THX_when_sub_bodied(aTHX_ sub, action)
static void THX_when_sub_bodied(pTHX_ CV *sub, CV *action)
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

PROTOTYPES: DISABLE

BOOT:
	stash_whenbodied = gv_stashpvs("Sub::Mutate::__WHEN_BODIED__", 1);
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
