#!/usr/bin/perl
# Verify that plugin errors reach the configurator without duplicate diagnostics.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use Cloudmin::Config::Plugin;
{
  package ErrorFixture;
  use parent 'Cloudmin::Config::Plugin';
  # actions(self) Initializes Webmin from a plugin before raising a known error.
  sub actions {
    $_[0]->use_webmin();
    WebminCore::error('Expected configuration error');
  }
}
my $stderr = '';
{
  open(my $capture, '>', \$stderr) or die $!;
  local *STDERR = $capture;
  eval { ErrorFixture->new(name => 'WebminErrorTest')->actions() };
  like($@, qr/Expected configuration error/, 'plugin error can be caught by the configurator');
}
is($stderr, '', 'Webmin does not print a second copy of the error');
done_testing();
