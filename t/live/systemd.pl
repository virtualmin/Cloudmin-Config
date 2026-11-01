#!/usr/bin/perl
# Test Webmin's service API with a temporary unit that fails to start.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use Cloudmin::Config::Plugin;
$^O eq 'linux' && $< == 0 or die "Run this test as root on a disposable Linux VM\n";
my $plugin = Cloudmin::Config::Plugin->new(name => 'NativeApiTest');
# Use a process-specific name in the runtime unit directory.
my $unit = "cloudmin-api-check-$$.service";
my $path = "/run/systemd/system/$unit";
my $ok = eval {
  $plugin->use_webmin();
  foreign_require('systemd', 'systemd-lib.pl');
  my ($missing, $error) = systemd::get_unit_state($unit);
  is($error, undef, 'missing unit can be inspected');
  is($missing->{LoadState}, 'not-found', 'missing state is explicit');
  # Create a service that must fail, after confirming its path is unused.
  -e $path and die "Fixture path already exists\n";
  open(my $fh, '>', $path) or die $!;
  print {$fh} "[Unit]\nDescription=Cloudmin failing unit fixture\n[Service]\nType=oneshot\nExecStart=/bin/false\n";
  close($fh) or die $!;
  # Verify both the action result and the subsequent systemd service state.
  systemd::reload_manager();
  my ($started, $out) = systemd::start_unit($unit);
  ok(!$started, 'real failing start is reported even after journal diagnostics');
  like($out, qr/failed/i, 'native failure is returned');
  my ($state) = systemd::get_unit_state($unit);
  is($state->{ActiveState}, 'failed', 'fresh state reports actual failure');
  1;
};
my $error = $@;
# Stop through Webmin and clear the fixture's deliberate failure before removal.
if (-e $path) {
  systemd::stop_unit($unit);
  system('systemctl', 'reset-failed', $unit) == 0
    or die "Cannot reset fixture failure\n";
  unlink($path) or die $!;
  systemd::reload_manager();
}
die $error unless $ok;
done_testing();
