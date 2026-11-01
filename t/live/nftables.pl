#!/usr/bin/perl
# Test Webmin rule storage and application in a private network namespace.
use strict;
use warnings;
no warnings 'once';
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Temp qw(tempdir);
use Test::More;
use Cloudmin::Config::Plugin::Nftables;
use Cloudmin::Config::Plugin::Readiness;
# Refuse kernel firewall tests in the host's network namespace.
$> == 0 && $^O eq 'linux' or die "Run this test as root on a disposable Linux VM\n";
readlink('/proc/self/ns/net') ne readlink('/proc/1/ns/net')
  or die "Run this test with unshare --net\n";
my $dir = tempdir('/tmp/cloudmin-nft-apply-XXXXXX', CLEANUP => 1);
{
  package FixtureNftables;
  use parent -norequire, 'Cloudmin::Config::Plugin::Nftables';
  # systemd_state(self, unit) Keeps service discovery inside this fixture.
  sub systemd_state {
    return { LoadState => $_[1] eq 'nftables.service' ? 'loaded' : 'not-found',
      UnitFileState => 'enabled' };
  }
  # systemd_action(self, action, unit) Never changes the host's boot settings.
  sub systemd_action {
    $_[1] eq 'enable' && $_[2] eq 'nftables.service'
      or die 'Unexpected service action';
    return 1;
  }
}
my $p = FixtureNftables->new();
$p->use_webmin();
foreign_require('nftables', 'nftables-lib.pl');
# Redirect every Webmin persistence file before invoking the production plugin.
$nftables::nftables_rules_file_cache = "$dir/rules.nft";
$nftables::last_config_change_flag = "$dir/config-flag";
$nftables::last_restart_time_flag = "$dir/restart-flag";
{
  no warnings 'redefine';
  # enable_nftables_at_boot() Leaves the host's service settings untouched.
  local *nftables::enable_nftables_at_boot = sub { };
  system('nft', 'add', 'table', 'ip', 'libvirt_network') == 0 or die 'Cannot create external table';
  # Seed the old deployment name, including a source-restricted NFS exception.
  my $legacy = nftables::create_profile_ruleset('cloudmin', 'management', '*');
  delete $legacy->{chains}{forward};
  delete $legacy->{chains}{output};
  nftables::add_profile_rule($legacy, 'input',
    'ip saddr 192.0.2.10 tcp dport 2049 accept comment "webmin-nfs-client-tcp"');
  nftables::save_configuration($legacy);
  is(nftables::apply_restore(), undef, 'legacy firewall fixture is active');
  ok(eval { $p->actions(); 1 }, 'production plugin saves and applies through Webmin') or diag $@;
  ok(-s "$dir/rules.nft", 'rules persist in the service configuration file');
  is(system('nft', 'list', 'table', 'ip', 'libvirt_network'), 0, 'external libvirt table survives');
  my ($active, $error) = nftables::get_active_nftables_save();
  is($error, undef, 'kernel rules can be read after migration');
  ok(!grep({ $_->{family} eq 'inet' && $_->{name} eq 'cloudmin' } @$active),
    'legacy input drop policy is removed from the kernel');
  my ($profile) = grep { $_->{name} eq 'webmin_profile_virtualization' } @$active;
  ok($profile, 'kernel uses the Webmin profile name');
  is_deeply([sort keys %{$profile->{chains}}], ['input'], 'profile controls host input only');
  ok(grep({ ($_->{comment} || '') eq 'webmin-nfs-client-tcp' } @{$profile->{rules}}),
    'NFS client exception reaches the new active table');
  my @saved = nftables::get_nftables_save();
  is_deeply([map { $_->{name} } @saved], ['webmin_profile_virtualization'],
    'boot configuration contains only the replacement profile');
  ok(eval { $p->actions(); 1 }, 'applying the same configuration twice works') or diag $@;
  @saved = nftables::get_nftables_save();
  ok(grep({ ($_->{comment} || '') eq 'webmin-nfs-client-tcp' } @{$saved[0]->{rules}}),
    'NFS client exception survives another profile rebuild');

  # Exercise the final readiness gate against the migrated kernel table.
  # Service state and worker boot checks have separate live fixtures.
  local *Cloudmin::Config::Plugin::Readiness::require_unit = sub { 1 };
  local *Cloudmin::Config::Plugin::Readiness::check_workers = sub { 1 };
  local *Cloudmin::Config::Plugin::Readiness::run_command = sub {
    my ($self, $command) = @_;
    # Keep this fixture focused on the real nft command, not Fail2ban jails.
    return 1 if $command =~ /^fail2ban-client /;
    return Cloudmin::Config::Plugin::run_command($self, $command);
  };
  my $ready = Cloudmin::Config::Plugin::Readiness->new();
  ok(eval { $ready->actions(); 1 }, 'readiness finds the migrated profile table') or diag $@;
}
done_testing();
