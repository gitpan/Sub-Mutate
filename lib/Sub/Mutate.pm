=head1 NAME

Sub::Mutate - examination and modification of subroutines

=head1 SYNOPSIS

	use Sub::Mutate qw(
		sub_body_type
		sub_closure_role
		sub_is_lvalue
		sub_is_constant
		sub_is_method mutate_sub_is_method
		sub_is_debuggable mutate_sub_is_debuggable
		sub_prototype mutate_sub_prototype
	);

	$type = sub_body_type($sub);
	$type = sub_closure_role($sub);
	if(sub_is_lvalue($sub)) { ...
	if(sub_is_constant($sub)) { ...
	if(sub_is_method($sub)) { ...
	mutate_sub_is_method($sub, 1);
	if(sub_is_debuggable($sub)) { ...
	mutate_sub_is_debuggable($sub, 0);
	$proto = sub_prototype($sub);
	mutate_sub_prototype($sub, $proto);

	use Sub::Mutate qw(when_sub_bodied);

	when_sub_bodied($sub, sub { mutate_sub_foo($_[0], ...) });

=head1 DESCRIPTION

This module contains functions that examine and modify many aspects of
subroutines in Perl.  It is intended to help in the implementation of
attribute handlers, and for other such special effects.

=cut

package Sub::Mutate;

{ use 5.008; }
use warnings;
use strict;

our $VERSION = "0.003";

use parent "Exporter";
our @EXPORT_OK = qw(
	sub_body_type
	sub_closure_role
	sub_is_lvalue
	sub_is_constant
	sub_is_method mutate_sub_is_method
	sub_is_debuggable mutate_sub_is_debuggable
	sub_prototype mutate_sub_prototype
	when_sub_bodied
);

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

=head1 FUNCTIONS

Each of these functions takes an argument I<SUB>, which must be a
reference to a subroutine.  The function operates on the subroutine
referenced by I<SUB>.

The C<mutate_> functions modify a subroutine in place.  The subroutine's
identity is not changed, but the attributes of the existing subroutine
object are changed.  All references to the existing subroutine will see
the new attributes.  Beware of action at a distance.

=over

=item sub_body_type(SUB)

Returns a keyword indicating the general nature of the implementation
of I<SUB>:

=over

=item B<PERL>

The subroutine's body consists of a network of op nodes for the Perl
interpreter.  Subroutines written in Perl are almost always of this form.

=item B<UNDEF>

The subroutine has no body, and so cannot be successfully called.

=item B<XSUB>

The subroutine's body consists of native machine code.  Usually these
subroutines have been mainly written in C.  Constant-valued subroutines
written in Perl can also acquire this type of body.

=back

=item sub_closure_role(SUB)

Returns a keyword indicating the status of I<SUB> with respect to the
generation of closures in the Perl language:

=over

=item B<CLOSURE>

The subroutine is a closure: it was generated from Perl code referencing
external lexical variables, and now references a particular set of those
variables to make up a complete subroutine.

=item B<PROTOTYPE>

The subroutine is a prototype for closures: it consists of Perl code
referencing external lexical variables, and has not been attached to a
particular set of those variables.  This is not a complete subroutine
and cannot be successfully called.  It is an oddity of Perl that this
type of object is represented as if it were a subroutine, and the
situations where one can get access to this kind of object are rare.
Prototype subroutines will mainly be encountered by attribute handlers.

=item B<STANDALONE>

The subroutine is independent of external lexical variables.

=back

=item sub_is_lvalue(SUB)

Returns a truth value indicating whether I<SUB> is expected to return an
lvalue.  An lvalue subroutine is usually created by using the C<:lvalue>
attribute, which affects how the subroutine body is compiled and also
sets the flag that this function extracts.

=item sub_is_constant(SUB)

Returns a truth value indicating whether I<SUB> returns a constant
value and can therefore be inlined.  It is possible for a subroutine
to actually be constant-valued without the compiler detecting it and
setting this flag.

=item sub_is_method(SUB)

Returns a truth value indicating whether I<SUB> is marked as a method.
This marker can be applied by use of the C<:method> attribute, and
(as of Perl 5.10) affects almost nothing.

=item mutate_sub_is_method(SUB, NEW_METHODNESS)

Marks or unmarks I<SUB> as a method, depending on the truth value of
I<NEW_METHODNESS>.

=item sub_is_debuggable(SUB)

Returns a truth value indicating whether, when the Perl debugger
is activated, calls to I<SUB> can be intercepted by C<DB::sub> (see
L<perldebguts>).  Normally this is true for all subroutines, but note
that whether a particular call is intercepted also depends on the nature
of the calling site.

=item mutate_sub_is_debuggable(SUB, NEW_DEBUGGABILITY)

Changes whether the Perl debugger will intercept calls to I<SUB>,
depending on the truth value of I<NEW_DEBUGGABILITY>.

=item sub_prototype(SUB)

Returns the prototype of I<SUB>, which is a string, or C<undef> if the
subroutine has no prototype.  (No prototype is different from the empty
string prototype.)  Prototypes affect the compilation of calls to the
subroutine, where the identity of the called subroutine can be resolved
at compile time.  (This is unrelated to the closure prototypes described
for L</sub_closure_role>.)

=item mutate_sub_prototype(SUB, NEW_PROTOTYPE)

Sets or deletes the prototype of I<SUB>, to match I<NEW_PROTOTYPE>,
which must be either a string or C<undef>.

=item when_sub_bodied(SUB, ACTION)

Queues a modification of I<SUB>, to occur when I<SUB> has acquired a body.
This is required due to an oddity of how Perl constructs Perl-language
subroutines.  A subroutine object is initially created with no body, and
then the body is later attached.  Attribute handlers are executed before
the body is attached, but it is otherwise unusual to see the subroutine
in that intermediate state.  If the implementation of an attribute can
only be completed after the body is attached, this function is the way
to schedule the implementation.

If this function is called when I<SUB> is in the intermediate state, with
body not yet attached, then I<ACTION> is added to a queue.  Shortly after
a body is attached to I<SUB>, the queued actions are performed.  I<ACTION>
must be a reference to a function, which is called with one argument, a
reference to the subroutine to act on.  The subroutine passed to I<ACTION>
is not necessarily the same object as the original I<SUB>: some subroutine
construction sequences cause the partially-built subroutine to move from
one object to another part way through, and the queue of pending actions
moves with it.

If this function is called when I<SUB> already has a body, the action
will be performed immediately, or nearly so.  Actions are always
performed sequentially, in the order in which they were queued, so if
an action is requested while another action is already executing then
the newly-requested action will have to wait until the executing one
has finished.

If a subroutine with pending actions is replaced, in the same subroutine
object, by a new subroutine, then the queue of pending actions is
discarded.  This occurs in the case of a so-called "forward declaration",
such as "C<sub foo ($);>".  The declaration creates a subroutine with
no body, to influence compilation of calls to the subroutine, and it
is intended that the empty subroutine will later be replaced by a full
subroutine which has a body.

=back

=head1 BUGS

The code behind C<when_sub_bodied> is an ugly experimental hack, which
may turn out to be fragile.  Details of its behaviour may change in
future versions of this module, if better ways of achieving the desired
effect are found.

Before Perl 5.10, C<when_sub_bodied> has a particular problem with
redefining subroutines.  A subroutine redefinition, including if the
previous definition had no body (a pre-declaration), is the situation
that causes a partially-built subroutine to move from one subroutine
object to another.  On pre-5.10 Perls, it is impossible to locate the
destination object at the critical point in this process, and as a result
any pending actions are lost.

=head1 SEE ALSO

L<Attribute::Lexical>

=head1 AUTHOR

Andrew Main (Zefram) <zefram@fysh.org>

=head1 COPYRIGHT

Copyright (C) 2009, 2010 Andrew Main (Zefram) <zefram@fysh.org>

=head1 LICENSE

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
