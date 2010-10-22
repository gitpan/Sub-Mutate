use warnings;
use strict;

use Test::More tests => 10;

BEGIN { use_ok "Sub::Mutate", qw(when_sub_bodied sub_body_type); }

our @acted;
sub action($;$) {
	my($id, $extra) = @_;
	return sub {
		push @acted, [ $_[0], sub_body_type($_[0]), $id ];
		if($extra) {
			$extra->($_[0]);
			push @acted, [ $_[0], sub_body_type($_[0]), $id."x" ];
		}
	};
}
sub match_acted($) {
	my($expected) = @_;
	ok @acted == @$expected && !(grep {
		my $got = $acted[$_];
		my $exp = $expected->[$_];
		!($got->[0] == $exp->[0] && $got->[1] eq $exp->[1] &&
			$got->[2] eq $exp->[2]);
	} 0..$#acted);
}

@acted = ();
when_sub_bodied(\&sub_body_type, action("0"));
match_acted [ [ \&sub_body_type, "XSUB", "0" ] ];

@acted = ();
sub t0 { }
when_sub_bodied(\&t0, action("1"));
match_acted [ [ \&t0, "PERL", "1" ] ];

@acted = ();
when_sub_bodied(\&sub_body_type,
	action("2", sub { when_sub_bodied($_[0], action("3")) }));
match_acted [
	[ \&sub_body_type, "XSUB", "2" ],
	[ \&sub_body_type, "XSUB", "2x" ],
	[ \&sub_body_type, "XSUB", "3" ],
];

@acted = ();
sub t1 { }
when_sub_bodied(\&t1,
	action("4", sub { when_sub_bodied($_[0], action("5")) }));
match_acted [
	[ \&t1, "PERL", "4" ],
	[ \&t1, "PERL", "4x" ],
	[ \&t1, "PERL", "5" ],
];

sub MODIFY_CODE_ATTRIBUTES {
	shift(@_);
	my $subject = shift(@_);
	foreach my $attr (@_) {
		when_sub_bodied($subject,
			action($attr, sub {
				when_sub_bodied($_[0], action($attr."e"))
			}));
	}
	return ();
}

@acted = ();
eval q{ sub t2 :a0 :a1 { } 1 } or die $@;
match_acted [
	[ \&t2, "PERL", "a0" ],
	[ \&t2, "PERL", "a0x" ],
	[ \&t2, "PERL", "a1" ],
	[ \&t2, "PERL", "a1x" ],
	[ \&t2, "PERL", "a0e" ],
	[ \&t2, "PERL", "a1e" ],
];

@acted = ();
eval q{ sub t3 :a2 :a3; 1 } or die $@;
match_acted [];
@acted = ();
eval q{ sub t3 :a4 :a5 { } 1 } or die $@;
SKIP: {
	skip "predeclarations cause attribute lossage on pre-5.10 perl", 1
		unless "$]" >= 5.010;
	match_acted [
		[ \&t3, "PERL", "a4" ],
		[ \&t3, "PERL", "a4x" ],
		[ \&t3, "PERL", "a5" ],
		[ \&t3, "PERL", "a5x" ],
		[ \&t3, "PERL", "a4e" ],
		[ \&t3, "PERL", "a5e" ],
	];
}
@acted = ();
eval q{ sub t3 :a6 :a7; 1 } or die $@;
match_acted [
	[ \&t3, "PERL", "a6" ],
	[ \&t3, "PERL", "a6x" ],
	[ \&t3, "PERL", "a6e" ],
	[ \&t3, "PERL", "a7" ],
	[ \&t3, "PERL", "a7x" ],
	[ \&t3, "PERL", "a7e" ],
];

@acted = ();
sub t4 { }
sub t5 { }
when_sub_bodied(\&t4, action("6", sub {
	when_sub_bodied(\&t5, action("7", sub {
		when_sub_bodied(\&t4, action("8"));
		when_sub_bodied(\&t5, action("9"));
	}));
}));
match_acted [
	[ \&t4, "PERL", "6" ],
	[ \&t5, "PERL", "7" ],
	[ \&t5, "PERL", "7x" ],
	[ \&t5, "PERL", "9" ],
	[ \&t4, "PERL", "6x" ],
	[ \&t4, "PERL", "8" ],
];

1;
