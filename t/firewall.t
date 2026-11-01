use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config::Plugin::Nftables;

# Model Webmin rule storage to check failure handling and table ownership.
{
  package FixtureFirewall;
  use parent -norequire, 'Cloudmin::Config::Plugin::Nftables';
  # use_webmin(self) Keeps the fixture independent of installed Webmin.
  sub use_webmin { }
  # spin(self, [message]) Suppresses progress output in unit tests.
  sub spin { }
  # done(self, result) Rejects failed completion without terminal output.
  sub done { $_[1] == 1 or die 'failed' }
  # host_ruleset(self) Supplies a model table without querying libvirt.
  sub host_ruleset { { family => 'inet', name => 'webmin_profile_virtualization' } }
  # systemd_state(self, unit) Returns simulated installation and boot state.
  sub systemd_state { $main::units{$_[1]} || {LoadState => $_[1] eq 'nftables.service' ? 'loaded' : 'not-found', UnitFileState => 'enabled'} }
  # systemd_action(self, action, unit) Records service calls and their order.
  sub systemd_action { push @main::commands, "$_[1] $_[2]"; push @main::events, "$_[1] $_[2]"; 1 }
  # run_command(self, command) Records commands without executing them.
  sub run_command { push @main::commands, $_[1]; 1 }
  package Cloudmin::Config::Plugin::Nftables;
  # foreign_require(module, library) Uses the in-memory nftables fixture.
  sub foreign_require { }
  package nftables;
  # create_profile_ruleset(name, profile, interface) Rejects unexpected use.
  sub create_profile_ruleset { die 'overridden by fixture' }
  sub profile_base_table_name { 'webmin_profile_virtualization' }
  # check_nftables() Models an available nftables installation.
  sub check_nftables { '' }
  # get_active_nftables_save() Supplies simulated active tables.
  sub get_active_nftables_save { (\@main::active, '') }
  sub table_is_externally_managed { $_[0]->{flags} }
  # Readback parsing restores rule comments from the persisted text.
  sub get_nftables_save {
    for my $rule (map { @{$_->{rules} || []} } @main::saved) {
      $rule->{comment} = $1 if $rule->{text} =~ /comment "([^"]+)"/;
    }
    return @main::saved;
  }
  # add_profile_rule(table, chain, text) Appends a rule to the model table.
  sub add_profile_rule { push @{$_[0]->{rules}}, {chain => $_[1], text => $_[2]} }
  # save_configuration([tables...]) Captures the requested saved rules.
  sub save_configuration { @main::tables = @_ }
  # apply_restore() Records application and returns an injected error.
  sub apply_restore { push @main::events, 'apply'; $main::apply_error }
  sub delete_active_table {
    push @main::events, "delete $_[0]->{name}";
    return $main::delete_error;
  }
}
our (@tables, @commands, @events, @saved, @active, %units, $apply_error, $delete_error);
@saved = ({family => 'inet', name => 'administrator'});
my $p = FixtureFirewall->new();
# Applying failed rules must not enable them for the next boot.
$apply_error = 'Kernel rejected the rules';
eval { $p->actions() };
like($@, qr/Kernel rejected/, 'firewall apply failure is fatal');
is_deeply(\@commands, [], 'failed rules are not enabled at boot');
is_deeply([map { $_->{name} } @tables], ['administrator', 'webmin_profile_virtualization'],
  'existing saved table is preserved with the new profile name');
is_deeply(\@events, ['apply'], 'failed apply does not remove the legacy firewall');
# A successful apply enables boot loading without flushing live rules.
$apply_error = '';
ok(eval { $p->actions(); 1 }, 'successful rules enable boot loading');
is_deeply(\@commands, ['enable nftables.service'], 'boot enable is verified without restart');
# Competing managers must finish cleanup before our rules are installed.
%units = ('ufw.service' => { LoadState => 'loaded', UnitFileState => 'enabled' });
@events = ();
ok(eval { $p->actions(); 1 }, 'an installed competing manager is disabled');
is_deeply(\@events, ['stop ufw.service', 'disable ufw.service', 'apply', 'delete cloudmin', 'enable nftables.service'],
  'firewall stop cannot remove the newly applied rules');

# Preserve source-restricted NFS rules while rebuilding the generated profile.
my @nfs_rules = map {
  my ($proto, $ports) = @$_;
  { chain => 'input', comment => "webmin-nfs-client-$proto",
    text => qq(ip saddr 192.0.2.10 $proto dport { $ports } accept comment "webmin-nfs-client-$proto") }
} (['tcp', '111, 2049, 20048'], ['udp', '111, 20048']);
push @saved, {family => 'inet', name => 'cloudmin', rules => [@nfs_rules,
  {chain => 'input', text => 'tcp dport 4444 accept', comment => 'unrelated'}]};
ok(eval { $p->actions(); 1 }, 'NFS clients survive a profile rebuild');
is_deeply([map { $_->{text} } @{$tables[-1]->{rules}}],
  [map { $_->{text} } @nfs_rules], 'only the two marked NFS rules are retained');
my $rebuilt = {rules => []};
$p->preserve_nfs_client_rules($rebuilt, $saved[-1], $saved[0]);
is(scalar(@{$rebuilt->{rules}}), 2, 'NFS preservation is independent of saved table order');

# Single-port NFSv4 and an explicit storage subnet retain their restrictions.
my $v4_rule = {chain => 'input', comment => 'webmin-nfs-client-tcp',
  text => 'ip saddr 192.0.2.0/24 tcp dport 2049 accept comment "webmin-nfs-client-tcp"'};
$rebuilt = {rules => []};
$p->preserve_nfs_client_rules($rebuilt,
  {family => 'inet', name => 'cloudmin', rules => [$v4_rule, $v4_rule]});
is_deeply([map { $_->{text} } @{$rebuilt->{rules}}], [$v4_rule->{text}],
  'NFSv4 subnet rule is retained once');

# Merge both table names during migration, and retain clients on later runs.
@saved = (
  {family => 'inet', name => 'administrator'},
  {family => 'inet', name => 'cloudmin', rules => [@nfs_rules]},
  {family => 'inet', name => 'webmin_profile_virtualization', rules => [$v4_rule, @nfs_rules]},
);
ok(eval { $p->actions(); 1 }, 'both old and new profile tables can be migrated');
is_deeply([map { $_->{name} } @tables], ['administrator', 'webmin_profile_virtualization'],
  'migration removes only the legacy saved table and replaces the profile');
is_deeply([map { $_->{text} } @{$tables[-1]->{rules}}],
  [map { $_->{text} } @nfs_rules, $v4_rule], 'migration retains and deduplicates NFS clients');
@saved = @tables;
ok(eval { $p->actions(); 1 }, 'new profile can be rebuilt without a legacy table');
is(scalar(@{$tables[-1]->{rules}}), 3, 'new profile retains its NFS clients');

# Ownership failures and cleanup errors must be visible without weakening rules.
for my $name ('cloudmin', 'webmin_profile_virtualization') {
  @active = ({family => 'inet', name => $name, flags => 'owner'});
  @events = ();
  eval { $p->actions() };
  like($@, qr/belongs to another service/, "$name ownership prevents replacement");
  is_deeply(\@events, [], 'ownership is checked before service or firewall changes');
}
@active = ();
$delete_error = 'Cannot remove the legacy table';
eval { $p->actions() };
like($@, qr/Cannot remove the legacy table/, 'failed legacy cleanup is reported');
$delete_error = '';

# Markers cannot turn an unrestricted or unrelated accept rule into an NFS rule.
for my $invalid (
  'tcp dport 2049 accept comment "webmin-nfs-client-tcp"',
  'ip saddr 192.0.2.10 tcp dport 22 accept comment "webmin-nfs-client-tcp"',
  'ip saddr 999.0.2.10 tcp dport 2049 accept comment "webmin-nfs-client-tcp"',
  'ip saddr 0.0.0.0/0 tcp dport 2049 accept comment "webmin-nfs-client-tcp"',
  'ip saddr 192.0.2.10 udp dport 111 accept comment "webmin-nfs-client-tcp"'
) {
  @saved = ({family => 'inet', name => 'cloudmin', rules => [
    {chain => 'input', comment => 'webmin-nfs-client-tcp', text => $invalid}]});
  @commands = ();
  eval { $p->actions() };
  like($@, qr/Invalid saved NFS client/, 'invalid marked rule stops configuration');
  is_deeply(\@commands, [], 'invalid NFS rule is rejected before service changes');
}
done_testing();
