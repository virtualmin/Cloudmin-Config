use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config;
use Cloudmin::Config::Plugin;
use Cloudmin::Config::Plugin::Platform;

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

done_testing();
