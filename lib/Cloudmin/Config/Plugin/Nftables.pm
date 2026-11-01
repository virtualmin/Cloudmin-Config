package Cloudmin::Config::Plugin::Nftables;
use strict;
use warnings;
use parent 'Cloudmin::Config::Plugin';

# new(class, [options]) Runs after libvirt and the Webmin service are configured.
sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(name => 'Nftables', depends => [qw(KVM Webmin)], %args);
}

# host_ruleset(self) Extends Webmin's Cloudmin profile for custom libvirt bridges.
sub host_ruleset {
  my ($self) = @_;
  my $table = nftables::create_profile_ruleset(
    nftables::profile_base_table_name('cloudmin'), 'cloudmin', '*');
  require Sys::Virt;
  require XML::LibXML;
  my $connection = Sys::Virt->new(uri => 'qemu:///system', readonly => 1);
  my %bridges;
  for my $network ($connection->list_all_networks(0)) {
    my $doc = XML::LibXML->load_xml(string => $network->get_xml_description(0), no_network => 1);
    my $mode = $doc->findvalue('/network/forward/@mode');
    # Include isolated, NAT and routed networks; skip external bridges.
    next if $mode && $mode ne 'nat' && $mode ne 'route';
    # Safe custom names can be quoted directly in nftables rules.
    my $bridge = $doc->findvalue('/network/bridge/@name');
    $bridges{$bridge} = 1 if $bridge !~ /^virbr/ &&
      $bridge =~ /\A[a-zA-Z0-9_.-]{1,15}\z/;
  }
  # Webmin covers virbr*; add guest DNS/DHCP for other managed bridge names.
  for my $bridge (sort keys %bridges) {
    nftables::add_profile_rule($table, 'input', qq(iifname "$bridge" udp dport { 53, 67, 547 } accept));
    nftables::add_profile_rule($table, 'input', qq(iifname "$bridge" tcp dport 53 accept));
  }
  return $table;
}

# preserve_nfs_client_rules(self, table, [saved_tables...]) Keeps NFS clients.
# table is the replacement profile; saved_tables are parsed saved tables.
# Only marked IPv4 accept rules for the fixed NFS ports survive a profile rebuild.
sub preserve_nfs_client_rules {
  my ($self, $table, @saved) = @_;
  my $name = nftables::profile_base_table_name('cloudmin');
  my @previous = grep { $_->{family} eq 'inet' &&
    ($_->{name} eq 'cloudmin' || $_->{name} eq $name) } @saved;
  # Both names can coexist while migrating; duplicate definitions cannot.
  my %names;
  for my $previous (@previous) {
    die "Several saved $previous->{name} firewall tables were found\n"
      if $names{$previous->{name}}++;
  }
  # A fresh profile has no client exceptions to retain.
  return if !@previous;
  my %seen;
  for my $rule (map { @{$_->{rules} || []} } @previous) {
    my $comment = $rule->{comment} || '';
    # Unmarked rules are outside the NFS exceptions preserved on rebuild.
    next unless $comment =~ /\Awebmin-nfs-client-(tcp|udp)\z/;
    my $tag_proto = $1;
    my $text = $rule->{text} || '';
    # Parse the full rule so its marker cannot conceal a broader allowance.
    my ($ip, $prefix, $proto, $ports, $text_proto) = $text =~ m{
      \Aip\s+saddr\s+(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?
      \s+(tcp|udp)\s+dport\s+(\{[\d,\s]+\}|\d+)
      \s+accept\s+comment\s+"webmin-nfs-client-(tcp|udp)"\s*;?\z
    }x;
    # Refuse malformed marked rules before stopping services or saving changes.
    die "Invalid saved NFS client rule\n" if
      ($rule->{chain} || '') ne 'input' || !defined($ip) ||
      $proto ne $tag_proto || $proto ne $text_proto || (grep { $_ > 255 } split(/\./, $ip)) ||
      (defined($prefix) && ($prefix < 1 || $prefix > 32));
    # Accept only the fixed NFS ports for the rule's declared protocol.
    $ports =~ s/[{}\s]//g;
    my %allowed = map { $_ => 1 } ($proto eq 'tcp' ? (111, 2049, 20048) : (111, 20048));
    die "Invalid saved NFS client ports\n" if
      $ports eq '' || grep { !$allowed{$_} } split(/,/, $ports, -1);
    # Deduplicate saved copies without retaining unrelated custom rules.
    next if $seen{$text}++;
    nftables::add_profile_rule($table, 'input', $text);
  }
}

# actions(self) Saves and applies host rules through the Webmin profile API.
sub actions {
  my ($self) = @_;
  $self->use_webmin();
  $self->spin();
  foreign_require('nftables', 'nftables-lib.pl');
  die "Webmin's current nftables module is required\n"
    unless defined &nftables::create_profile_ruleset && defined &nftables::apply_restore &&
      defined &nftables::profile_base_table_name && defined &nftables::delete_active_table;
  my $error = nftables::check_nftables();
  # Abort before changing services if the nftables environment is unusable.
  die "$error\n" if $error;
  my $table = $self->host_ruleset();
  my $name = $table->{name};
  my @saved = nftables::get_nftables_save();
  $self->preserve_nfs_client_rules($table, @saved);
  # Read the kernel state before attempting to replace owned tables.
  my ($active, $active_error) = nftables::get_active_nftables_save();
  die "$active_error\n" if $active_error;
  for my $t (@$active) {
    die "The cloudmin firewall table belongs to another service\n"
      if $t->{family} eq 'inet' && ($t->{name} eq 'cloudmin' || $t->{name} eq $name) &&
        nftables::table_is_externally_managed($t);
  }
  # Remove competing managers before applying our rules; their stop actions
  # can otherwise remove rules that were just installed.
  for my $service (qw(firewalld iptables ip6tables netfilter-persistent ufw)) {
    my $unit = "$service.service";
    my $state = $self->systemd_state($unit);
    # A manager that is not installed needs no service action.
    next if $state->{LoadState} eq 'not-found';
    $self->require_unit($unit);
    $self->systemd_action('stop', $unit);
    # Prevent an enabled competitor from restoring its rules at boot.
    $self->systemd_action('disable', $unit)
      if $state->{UnitFileState} eq 'enabled';
  }
  my @tables = grep { !($_->{family} eq 'inet' &&
    ($_->{name} eq 'cloudmin' || $_->{name} eq $name)) }
    @saved;
  nftables::save_configuration(@tables, $table);

  # Apply validates syntax and replaces only saved tables, preserving libvirt.
  $error = nftables::apply_restore();
  die "$error\n" if $error;
  # Keep the old firewall until its replacement is active, then remove it.
  # Otherwise its input drop policy would still block newly allowed services.
  $error = nftables::delete_active_table({family => 'inet', name => 'cloudmin'});
  die "$error\n" if $error;
  # Do not restart nftables: its stop action can flush libvirt tables.
  $self->systemd_action('enable', 'nftables.service');
  $self->require_unit('nftables.service', 0, 1);
  $self->done(1);
}

1;
