use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config::Plugin::Etckeeper;

{
  package FixtureEtckeeper;
  use parent 'Cloudmin::Config::Plugin::Etckeeper';
  # use_webmin(self) Keeps system configuration out of the unit fixture.
  sub use_webmin { }
  # spin(self) Suppresses progress output during assertions.
  sub spin { }
  # done(self, result, [error]) Records the reported status and its cause.
  sub done { push @{$_[0]->{events}}, ['done', @_[1 .. $#_]]; }
  # run_command(self, command) Records initialization and models command failure.
  sub run_command {
    my ($self, $command) = @_;
    push @{$self->{events}}, ['command', $command];
    die "Initialization failed\n" if ($self->{fail} || '') eq 'init';
  }
  # systemd_action(self, action, unit) Models failed service actions.
  sub systemd_action {
    my ($self, $action, $unit) = @_;
    push @{$self->{events}}, [$action, $unit];
    die "Timer $action failed\n" if ($self->{fail} || '') eq $action;
  }
  # require_unit(self, unit, active, enabled) Models an unhealthy timer.
  sub require_unit {
    my ($self, @args) = @_;
    push @{$self->{events}}, ['require', @args];
    die "Timer inactive\n" if ($self->{fail} || '') eq 'verify';
  }
}

# Rocky and AlmaLinux need the setup their RPM package does not perform.
no warnings 'redefine';
local *Cloudmin::Config::Plugin::Etckeeper::has_command = sub { '/usr/bin/etckeeper' };
local $Cloudmin::Config::Plugin::Etckeeper::gconfig{os_type} = 'redhat-linux';
my $plugin = FixtureEtckeeper->new();
ok(eval { $plugin->actions(); 1 }, 'RPM setup succeeds') or diag $@;
is_deeply($plugin->{events}, [
  ['command', 'etckeeper init'], ['enable', 'etckeeper.timer'],
  ['start', 'etckeeper.timer'], ['require', 'etckeeper.timer', 1, 1], ['done', 1]
], 'history is initialized before the daily timer is enabled and checked');

# Failed history setup warns instead of aborting the remaining configuration.
my %steps = (init => 1, enable => 2, start => 3, verify => 4);
for my $failure (qw(init enable start verify)) {
  $plugin = FixtureEtckeeper->new();
  $plugin->{fail} = $failure;
  ok(eval { $plugin->actions(); 1 }, "$failure failure is nonfatal") or diag $@;
  is($plugin->{events}[-1][1], 2, 'failure reports a warning');
  like($plugin->{events}[-1][2], qr/failed|inactive/, 'warning retains the cause');
  is(scalar @{$plugin->{events}}, $steps{$failure} + 1,
     'later Etckeeper steps do not run after failure');
}

# Debian and Ubuntu already set up history and scheduling in the package.
for my $os (qw(debian-linux ubuntu-linux)) {
  local $Cloudmin::Config::Plugin::Etckeeper::gconfig{os_type} = $os;
  $plugin = FixtureEtckeeper->new();
  ok(eval { $plugin->actions(); 1 }, "$os setup succeeds") or diag $@;
  is_deeply($plugin->{events}, [['done', 1]], 'package-managed setup is left unchanged');
}

# A missing package is reported without blocking unrelated configuration.
local *Cloudmin::Config::Plugin::Etckeeper::has_command = sub { undef };
$plugin = FixtureEtckeeper->new();
ok(eval { $plugin->actions(); 1 }, 'missing package is nonfatal') or diag $@;
is_deeply($plugin->{events}, [['done', 2, "Etckeeper is not installed\n"]],
  'missing package warns without making changes');
done_testing();
