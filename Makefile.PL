# Build the Cloudmin configuration tool and its plugins.
use strict;
use warnings;

use 5.026;

use ExtUtils::MakeMaker;

my %WriteMakefileArgs = (
  "ABSTRACT"           => "Configure a system for use by Cloudmin",
  "AUTHOR"             => [
    'Ilia Ross <ilia@webmin.dev>',
    'Joe Cooper <joe@webmin.com>',
    'Jamie Cameron <jamie@webmin.com>',
  ],
  "CONFIGURE_REQUIRES" => {"ExtUtils::MakeMaker" => 0},
  "DISTNAME"           => "Cloudmin-Config",
  "EXE_FILES"          => ["bin/cloudmin-config-system"],
  "LICENSE"            => "gpl",
  "MIN_PERL_VERSION"   => "5.026",
  "NAME"               => "Cloudmin::Config",
  "PREREQ_PM" =>
    {"Log::Log4perl" => 0, "Term::ANSIColor" => 0, "Module::Load" => 0,
     "Sys::Virt" => 0, "XML::LibXML" => 0, "JSON::PP" => 0},
  "TEST_REQUIRES" =>
    {"ExtUtils::MakeMaker" => 0, "File::Spec" => 0, "Test::More" => 0},
  "VERSION" => "10.0.0",
  "test"    => {"TESTS" => "t/*.t"}
);


WriteMakefile(%WriteMakefileArgs);
