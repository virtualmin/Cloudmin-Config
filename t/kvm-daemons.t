use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config::Plugin::KVM;

{
  package TestKVM;
  use parent -norequire, 'Cloudmin::Config::Plugin::KVM';
  # new(class, [options]) Models units without accessing host services.
  sub new { my ($class, %options) = @_; bless { commands => [], %options }, $class }
  # libvirt_plan(self) Uses the fixture's chosen daemon layout.
  sub libvirt_plan { Cloudmin::Config::Libvirt::service_plan($_[0]->{modular}) }
  # systemd_state(self, unit) Reads the simulated load, boot and active state.
  sub systemd_state {
    my ($self, $unit) = @_;
    $_ = ''; # Webmin helpers may use the default iterator internally.
    return { LoadState => $self->{missing}{$unit} ? 'not-found' : 'loaded',
      UnitFileState => $self->{enabled}{$unit} ? 'enabled' : 'disabled',
      ActiveState => $self->{active}{$unit} ? 'active' : 'inactive' };
  }
  # systemd_action(self, action, unit) Records calls and updates fixture state.
  sub systemd_action {
    my ($self, $action, $unit) = @_;
    push @{$self->{commands}}, "$action $unit";
    # Inject failure before changing the modeled unit.
    die "Action failed\n" if ($self->{fail} || '') eq "$action $unit";
    # Model boot enable/disable separately from starting a unit now.
    $self->{enabled}{$unit} = 1 if $action eq 'enable';
    delete $self->{enabled}{$unit} if $action eq 'disable';
    $self->{active}{$unit} = 1 if $action eq 'start';
    return 1;
  }
}
my @legacy = qw(libvirtd.service libvirtd.socket libvirtd-ro.socket
  libvirtd-admin.socket libvirtd-tcp.socket libvirtd-tls.socket);
# Every required unit must exist before either daemon layout is changed.
for my $modular (0, 1) {
  my $plan = Cloudmin::Config::Libvirt::service_plan($modular);
  my @required = (@{$plan->{services}}, @{$plan->{sockets}});
  for my $unit (@required) {
    my $p = TestKVM->new(modular => $modular, missing => { $unit => 1 });
    eval { $p->_enable_libvirt_daemons() };
    like($@, qr/Required systemd unit is unavailable: \Q$unit\E/, 'partial package installation fails clearly');
    is_deeply($p->{commands}, [], 'missing units leave services unchanged');
  }
  # Repeated setup must preserve running guests and enable boot services.
  my $p = TestKVM->new(modular => $modular);
  ok($p->_enable_libvirt_daemons(), "$plan->{layout} setup succeeds");
  is_deeply([sort keys %{$p->{enabled}}], [sort @required], 'sockets and boot services enabled');
  ok($p->_enable_libvirt_daemons(), 'setup can run again');
  ok(!grep(/^(stop|restart|kill) /, @{$p->{commands}}), 'setup avoids stop, restart and kill commands');
  # Idle daemons may exit, but listening sockets and boot settings matter.
  my $unit = $plan->{services}[0];
  delete $p->{active}{$unit};
  ok($p->require_unit($unit, 0, 1), 'idle daemon may exit while boot activation remains enabled');
  delete $p->{active}{$plan->{sockets}[0]};
  eval { $p->require_unit($plan->{sockets}[0], 1, 1) };
  like($@, qr/not active/, 'inactive socket fails readiness');
  delete $p->{enabled}{$unit};
  eval { $p->require_unit($unit, 0, 1) };
  like($@, qr/not enabled/, 'socket activation alone is not boot readiness');
}
# Any active legacy entry point blocks an automatic layout switch.
for my $unit (@legacy) {
  my $p = TestKVM->new(modular => 1, active => { $unit => 1 });
  eval { $p->_enable_libvirt_daemons() };
  like($@, qr/\Q$unit\E is active; migrate/, 'active legacy driver requires explicit migration');
  is_deeply($p->{commands}, [], 'active legacy hosts remain untouched');
}
# Inactive legacy units can be disabled; absent legacy units need no work.
my $p = TestKVM->new(modular => 1, enabled => { map { $_ => 1 } @legacy });
ok($p->_enable_libvirt_daemons(), 'inactive legacy units can be disabled');
ok(!grep(/^libvirtd/, keys %{$p->{enabled}}), 'legacy units cannot return on reboot');
$p = TestKVM->new(modular => 1, missing => { map { $_ => 1 } @legacy });
ok($p->_enable_libvirt_daemons(), 'modular-only packages are supported');
# A native service failure must stop all later setup actions.
for my $action ('disable libvirtd.service', 'enable virtlogd.socket', 'start virtnetworkd.service') {
  $p = TestKVM->new(modular => 1, enabled => { 'libvirtd.service' => 1 }, fail => $action);
  eval { $p->_enable_libvirt_daemons() };
  like($@, qr/Action failed/, 'native API failure is fatal');
  is($p->{commands}[-1], $action, 'no service actions follow failure');
}
done_testing();
