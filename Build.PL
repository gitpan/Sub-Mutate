use warnings;
use strict;

use Module::Build;

Module::Build->new(
	module_name => "Sub::Mutate",
	dist_version => "0.000",
	license => "perl",
	build_requires => {
		"ExtUtils::CBuilder" => "0.15",
		"Module::Build" => 0,
		"Test::More" => 0,
		"perl" => "5.008",
		"strict" => 0,
		"warnings" => 0,
	},
	requires => {
		"XSLoader" => 0,
		"parent" => 0,
		"perl" => "5.008",
		"strict" => 0,
		"warnings" => 0,
	},
	dynamic_config => 0,
	meta_add => { distribution_type => "module" },
	create_makefile_pl => "passthrough",
	sign => 1,
)->create_build_script;

exit 0;
