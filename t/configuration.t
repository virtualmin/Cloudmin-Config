use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config;
use Cloudmin::Config::Plugin;
use Cloudmin::Config::Plugin::Platform;
use Cloudmin::Config::Plugin::KVM;

# The framework must reject excluded dependencies before invoking any plugin.
my $config = Cloudmin::Config->new(bundle => 'KVM');
is_deeply([$config->list_bundles()], ['KVM'], 'bundle listing excludes internal helpers');
my @ordered = $config->_order_plugins($config->_gather_plugins());
is_deeply(\@ordered, [qw(Platform Etckeeper KVM Webmin Nftables Fail2ban Readiness)], 'required bundle order');
# Every shipped plugin must have a role in the default installation.
is_deeply([$config->list_plugins()], [sort @ordered], 'no unused plugins are shipped');
$config = Cloudmin::Config->new(bundle => 'KVM', exclude => ['Nftables']);
eval { $config->_order_plugins($config->_gather_plugins()); };
like($@, qr/Required plugin Nftables was excluded/, 'cannot skip a required dependency');
$config = Cloudmin::Config->new(bundle => 'KVM', exclude => ['Readiness']);
eval { $config->_gather_plugins(); };
like($@, qr/Readiness is required/, 'cannot omit the final readiness check');
# Explicit includes still resolve dependencies; unknown names fail early.
$config = Cloudmin::Config->new(include => 'Webmin');
is_deeply([$config->_order_plugins($config->_gather_plugins())], [qw(Platform Webmin)], 'scalar include resolves dependencies');
$config = Cloudmin::Config->new(include => ['MissingPlugin']);
eval { $config->_order_plugins($config->_gather_plugins()); };
like($@, qr/MissingPlugin/, 'unknown plugins fail before any configuration');
# Names must not allow a caller to load arbitrary paths.
eval { Cloudmin::Config::_valid_name('../../etc/passwd') };
like($@, qr/Invalid/, 'plugin names cannot be paths');
{
  # Supply two in-memory plugins to test cycles without touching services.
  package Cloudmin::Config::Plugin::CycleA;
  # new(class) Creates a plugin with no configuration actions.
  sub new { bless {}, shift }
  # depends(self) Points to CycleB to form a dependency cycle.
  sub depends { ['CycleB'] }
  package Cloudmin::Config::Plugin::CycleB;
  # new(class) Creates a plugin with no configuration actions.
  sub new { bless {}, shift }
  # depends(self) Points to CycleA to form a dependency cycle.
  sub depends { ['CycleA'] }
}
# Resolve the cycle using the fixture packages instead of disk modules.
local $INC{'Cloudmin/Config/Plugin/CycleA.pm'} = __FILE__;
local $INC{'Cloudmin/Config/Plugin/CycleB.pm'} = __FILE__;
eval { $config->_order_plugins('CycleA') };
like($@, qr/Dependency cycle/, 'dependency cycles are errors');
# Failed completion must raise an error, not merely change the display.
my $plugin = Cloudmin::Config::Plugin->new(name => 'Failure');
eval { $plugin->done(0, 'test failure') };
like($@, qr/test failure/, 'failed configuration cannot report success');

# The installer and configuration tool support the same host versions.
for my $id (qw(rocky almalinux)) {
  for my $arch (qw(x86_64 aarch64)) {
    ok(Cloudmin::Config::Plugin::Platform::supported($id, '10.2', $arch), "$id 10.2 $arch supported");
    ok(!Cloudmin::Config::Plugin::Platform::supported($id, '9.6', $arch), "$id 9 rejected");
  }
}
# Similar distribution names and unsupported versions are not aliases.
for my $id (qw(debian ubuntu rhel centos fedora)) {
  ok(!Cloudmin::Config::Plugin::Platform::supported($id, '10', 'aarch64'), "$id 10 is unsupported");
}

# Debian and Ubuntu support is limited to the declared release versions.
for my $arch (qw(x86_64 aarch64)) {
  ok(Cloudmin::Config::Plugin::Platform::supported('debian', '13', $arch), "Debian 13 $arch supported");
  ok(Cloudmin::Config::Plugin::Platform::supported('ubuntu', '26.04', $arch), "Ubuntu 26.04 $arch supported");
  ok(!Cloudmin::Config::Plugin::Platform::supported('debian', '12', $arch), 'Debian 12 rejected');
  ok(!Cloudmin::Config::Plugin::Platform::supported('ubuntu', '24.04', $arch), 'Ubuntu 24.04 rejected');
}

# Network conflicts include subnets and host routes but not adjacent ranges.
ok(Cloudmin::Config::Plugin::KVM::_overlap('192.168.122.1/24', '192.168.0.0/16'), 'broader route overlaps');
ok(Cloudmin::Config::Plugin::KVM::_overlap('192.168.122.1/24', '192.168.122.3'), 'host route overlaps');
ok(!Cloudmin::Config::Plugin::KVM::_overlap('192.168.122.1/24', '192.168.123.0/24'), 'adjacent range is safe');
ok(!Cloudmin::Config::Plugin::KVM::_overlap('192.168.122.1/24', '10.0.0.0/8'), 'unrelated range is safe');
eval { Cloudmin::Config::Plugin::KVM::_overlap('192.168.122.1/44', '10.0.0.0/8') };
like($@, qr/Invalid/, 'invalid prefixes fail');
done_testing();
