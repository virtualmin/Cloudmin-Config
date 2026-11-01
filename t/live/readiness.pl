#!/usr/bin/perl
# Run on a disposable installed Cloudmin host; no existing guests are changed.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Temp qw(tempdir);
use Cloudmin::Config::Plugin::Platform;
use Cloudmin::Config::Plugin::KVM;
use Cloudmin::Config::Plugin::Nftables;
use Cloudmin::Config::Plugin::Readiness;
$> == 0 && $^O eq 'linux' or die "Run this test as root on a disposable Linux VM\n";

# Check the installed platform and firmware before exercising resources.
my $platform = Cloudmin::Config::Plugin::Platform->new();
ok(eval { $platform->actions(); 1 }, 'supported platform passes') or diag $@;
my $kvm = Cloudmin::Config::Plugin::KVM->new();
ok(eval { $kvm->_check_firmware(); 1 }, 'stock firmware supports EFI') or diag $@;
# Reuse an installed default network and pool, starting them if needed.
# On an unconfigured host, these helpers may create their default definitions.
ok(eval { $kvm->_ensure_default_network(); 1 }, 'existing NAT network remains usable') or diag $@;
ok(eval { $kvm->_ensure_default_pool(); 1 }, 'storage volume can be created and removed') or diag $@;
# Run real workers with temporary inputs, without attaching guest disks.
my $ready = Cloudmin::Config::Plugin::Readiness->new();
ok(eval { $ready->check_workers(); 1 }, 'real isolated key and disk workers run') or diag $@;

# Inspect generated firewall rules without applying them to the host.
my $firewall = Cloudmin::Config::Plugin::Nftables->new();
$firewall->use_webmin();
foreign_require('nftables', 'nftables-lib.pl');
my $table = $firewall->host_ruleset();
is($table->{chains}{input}{policy}, 'drop', 'host input defaults to deny');
ok(!exists $table->{chains}{forward}, 'guest forwarding remains under libvirt control');
my $rules = nftables::dump_nftables_save($table);
like($rules, qr/virbr.*udp dport.*53.*67/, 'guest DNS and DHCP allowed');
unlike($rules, qr/flush ruleset/, 'does not flush external tables');
# Pass the generated rules to a separate namespace for kernel validation.
my $dir = tempdir('/tmp/cloudmin-nft-test-XXXXXX', CLEANUP => 1);
open(my $fh, '>', "$dir/rules.nft") or die $!;
print {$fh} $rules;
close($fh) or die $!;
# nft is exercised in a separate network namespace, never against the host firewall.
is(system('unshare', '--net', 'sh', '-ec',
  'nft add table ip libvirt_fixture; nft -c -f "$1"; nft -f "$1"; nft list table ip libvirt_fixture; nft list table inet webmin_profile_virtualization',
  'check', "$dir/rules.nft"), 0, 'kernel accepts rules and retains unrelated tables');
done_testing();
