package Cloudmin::Config::Plugin::KVM;
use strict;
use warnings;
no warnings qw(once);
use parent 'Cloudmin::Config::Plugin';
use File::Path qw(make_path);
use Cloudmin::Config::Libvirt;

our $config_directory;
our (%gconfig, %miniserv);
our $trust_unknown_referers = 1;

my $log = Log::Log4perl->get_logger("cloudmin-config-system");

# new(class, [options]) Requires platform checks before libvirt setup.
sub new {
  my ($class, %args) = @_;

  my $self = $class->SUPER::new(name => 'KVM', depends => ['Platform'], %args);

  return $self;
}

# actions(self)
# Enables KVM and libvirt, then checks NAT, storage and EFI firmware.
sub actions {
  my $self = shift;

  $self->spin('Configuring KVM and libvirt');
  # Check each prerequisite before proceeding to the dependent resource.
  my $ok = eval {
    $self->_enable_kvm();
    $self->_enable_libvirt_daemons();
    $self->_ensure_default_network();
    $self->_ensure_default_pool();
    $self->_check_firmware();
    1;
  };
  # Preserve the failed step's error when ending the progress display.
  if (!$ok) {
    my $error = $@ || 'Unknown KVM configuration error';
    $error =~ s/\s+$//;
    $log->error($error);
    $self->done(0, $error);
  }
  $self->done(1);
  return 1;
}

# _enable_kvm(self)
# Loads the generic KVM module when needed and requires the KVM device.
sub _enable_kvm {
  my ($self) = @_;
  # Try loading KVM only when the kernel has not exposed its device.
  if (!-c '/dev/kvm') {
    $self->logsystem('modprobe kvm') == 0
      or die "Failed to load the KVM kernel module\n";
  }
  -c '/dev/kvm'
    or die "KVM is unavailable: /dev/kvm was not created\n";
  return 1;
}

# libvirt_plan(self) Selects the installed daemon layout; overridable by tests.
sub libvirt_plan {
  return Cloudmin::Config::Libvirt::installed_plan();
}

# _enable_libvirt_daemons(self) Enables native sockets and boot-time autostart.
sub _enable_libvirt_daemons {
  my ($self) = @_;
  my $plan = $self->libvirt_plan();
  # Validate every required unit before modifying any service.
  for my $unit (@{$plan->{services}}, @{$plan->{sockets}}) {
    $self->require_unit($unit);
  }
  if ($plan->{layout} eq 'modular') {
    # Require manual migration before replacing active libvirtd units.
    my @legacy = qw(libvirtd.service libvirtd.socket libvirtd-ro.socket
      libvirtd-admin.socket libvirtd-tcp.socket libvirtd-tls.socket);
    my @installed;
    for my $unit (@legacy) {
      my $state = $self->systemd_state($unit);
      # Modular-only packages need not install the legacy units.
      next if $state->{LoadState} eq 'not-found';
      # Active legacy drivers may serve guests and must not be replaced.
      die "$unit is active; migrate this host to modular libvirt before configuring Cloudmin\n"
        if $state->{ActiveState} =~ /\A(?:active|activating|reloading)\z/;
      # Disable inactive legacy units that would otherwise return at boot.
      push @installed, $unit if $state->{UnitFileState} eq 'enabled';
    }
    for my $unit (@installed) { $self->systemd_action('disable', $unit); }
  }
  # Sockets accept clients; services autostart guests, pools and networks.
  for my $unit (@{$plan->{sockets}}, @{$plan->{services}}) {
    $self->systemd_action('enable', $unit);
    $self->systemd_action('start', $unit);
  }
  return 1;
}

# _ensure_default_pool(self)
# Starts an existing default pool or creates one when no pool is active.
sub _ensure_default_pool {
  my ($self) = @_;
  require Sys::Virt;

  my $connection = Sys::Virt->new(
    uri => 'qemu:///system',
    readonly => 0,
  );
  my @pools = $connection->list_all_storage_pools(0);
  my ($pool) = grep { $_->get_name() eq 'default' } @pools;
  my $check_write = $pool && $self->_is_cloudmin_default_pool($pool);

  # Preserve an already usable custom storage configuration.
  return 1 if (!$pool && grep { eval { $_->is_active() } } @pools);

  # Create only the standard local directory needed by the default pool.
  if (!$pool) {
    my $target = '/var/lib/libvirt/images';
    make_path($target, { mode => 0711 }) if (!-d $target);
    # Restore the packaged SELinux context where restorecon is available.
    if (-x '/usr/sbin/restorecon') {
      $self->logsystem("/usr/sbin/restorecon -R $target") == 0
        or die "Failed to restore the storage directory security label\n";
    }
    my $xml = <<'EOF';
<pool type='dir'>
  <name>default</name>
  <target>
    <path>/var/lib/libvirt/images</path>
  </target>
</pool>
EOF
    $pool = $connection->define_storage_pool($xml, 0);
    $check_write = 1;
  }

  # Make the persistent pool usable now and after a host reboot.
  $pool->create() if (!$pool->is_active());
  $pool->set_autostart(1) if (!$pool->get_autostart());
  # Probe only the standard directory pool, leaving custom storage alone.
  $self->_check_pool_write($pool) if ($check_write);
  return 1;
}

# _is_cloudmin_default_pool(self, pool)
# Recognizes the standard directory pool used for the write check.
sub _is_cloudmin_default_pool {
  my ($self, $pool) = @_;
  my $xml = eval { $pool->get_xml_description(0) } || '';
  return $xml =~ /<pool\b[^>]*\btype\s*=\s*['"]dir['"]/i &&
    $xml =~ m{<target\b[^>]*>.*?<path\b[^>]*>\s*
      /var/lib/libvirt/images\s*</path>}isx ? 1 : 0;
}

# _check_pool_write(self, pool)
# Creates and removes a sparse test volume to verify real write access.
sub _check_pool_write {
  my ($self, $pool) = @_;
  my $name = '.cloudmin-storage-check-'.$$.'-'.time().'.raw';
  my $xml = "<volume><name>$name</name>".
    "<capacity unit='bytes'>1048576</capacity>".
    "<allocation unit='bytes'>0</allocation>".
    "<target><format type='raw'/></target></volume>";
  my $volume;
  my $ok = eval {
    $volume = $pool->create_volume($xml);
    $volume->delete(0);
    $volume = undef;
    1;
  };
  # Retry cleanup if a volume was created, retaining the original error.
  if (!$ok) {
    my $error = $@ || 'Libvirt returned no test volume';
    eval { $volume->delete(0) } if ($volume);
    die "Default storage pool write test failed: $error";
  }
  return 1;
}

# _ensure_default_network(self) Starts or defines the default NAT network.
# Preserve an existing definition and require persistent NAT with DHCP.
sub _ensure_default_network {
  my ($self) = @_;
  require Sys::Virt;
  require XML::LibXML;
  my $connection = Sys::Virt->new(uri => 'qemu:///system');
  my ($network) = grep { $_->get_name() eq 'default' }
    $connection->list_all_networks(0);
  # Use the standard subnet only when no default network is defined.
  my $xml = $network ? $network->get_xml_description(0) : <<'XML';
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.122.2' end='192.168.122.254'/></dhcp>
  </ip>
</network>
XML
  my $doc = XML::LibXML->load_xml(string => $xml, no_network => 1);
  $doc->findvalue('/network/forward/@mode') eq 'nat' &&
    $doc->findnodes('/network/ip/dhcp/range')
    or die "The default libvirt network must provide NAT and DHCP\n";
  if (!$network || !$network->is_active()) {
    # Refuse overlapping host routes before activating the proposed subnet.
    require JSON::PP;
    open(my $routes, '-|', 'ip', '-j', '-4', 'route', 'show', 'table', 'all')
      or die "Cannot inspect host routes: $!\n";
    my $json = do { local $/; <$routes> };
    close($routes) or die "Cannot inspect host routes\n";
    my $bridge = $doc->findvalue('/network/bridge/@name');
    for my $ip ($doc->findnodes('/network/ip[not(@family) or @family="ipv4"]')) {
      my $prefix = $ip->getAttribute('prefix');
      # Definitions may express the prefix as a dotted netmask instead.
      if (!length($prefix)) {
        my $mask = $ip->getAttribute('netmask');
        require Socket;
        my $packed = Socket::inet_aton($mask);
        defined($packed) or die "Invalid default network netmask\n";
        my $bits = unpack('B32', $packed);
        $bits =~ /\A1*0*\z/ or die "Invalid default network netmask\n";
        $prefix = ($bits =~ tr/1/1/);
      }
      for my $route (@{JSON::PP::decode_json($json)}) {
        # The default route overlaps every subnet and is not a conflict.
        next if ($route->{dst} || '') eq 'default';
        # The network's own bridge routes are expected to overlap.
        next if $bridge && ($route->{dev} || '') eq $bridge;
        # Any other shared address could redirect existing host traffic.
        if (_overlap($ip->getAttribute('address')."/$prefix", $route->{dst})) {
          die "Default network overlaps host route $route->{dst}; configure a non-overlapping libvirt default NAT network first\n";
        }
      }
    }
    # Create or activate only after every proposed subnet passes.
    $network ||= $connection->define_network($xml);
    $network->create();
  }
  # The network must also remain available after a reboot.
  $network->is_persistent() or die "The default network must be persistent\n";
  $network->set_autostart(1) unless $network->get_autostart();
  return 1;
}

# _overlap(left, right) Tests IPv4 CIDRs or bare host addresses for overlap.
sub _overlap {
  my ($left, $right) = @_;
  require Socket;
  my @ranges;
  # Convert both routes to inclusive integer ranges; bare addresses are /32.
  for my $cidr ($left, $right) {
    defined($cidr) && $cidr =~ m{\A([0-9.]+)(?:/(\d+))?\z}
      or die "Invalid IPv4 route\n";
    my ($addr, $prefix) = ($1, defined($2) ? $2 : 32);
    my $packed = Socket::inet_aton($addr);
    defined($packed) && $prefix <= 32 or die "Invalid IPv4 route $cidr\n";
    # Round the address down to its subnet boundary before finding the end.
    my $size = 2 ** (32 - $prefix);
    my $start = int(unpack('N', $packed) / $size) * $size;
    push @ranges, [$start, $start + $size - 1];
  }
  return $ranges[0][0] <= $ranges[1][1] && $ranges[1][0] <= $ranges[0][1];
}

# _check_firmware(self) Requires packaged EFI firmware for the host machine type.
sub _check_firmware {
  my ($self) = @_;
  require Sys::Virt;
  require XML::LibXML;
  require POSIX;
  # Probe the machine type used by Cloudmin on each supported architecture.
  my $architecture = (POSIX::uname())[4];
  my $machine = $architecture eq 'aarch64' ? 'virt' : 'q35';
  # Libvirt probes QEMU for capabilities, which requires a writable connection.
  my $connection = Sys::Virt->new(uri => 'qemu:///system');
  my $xml = $connection->get_domain_capabilities(undef, $architecture, $machine, 'kvm', 0);
  my $doc = XML::LibXML->load_xml(string => $xml, no_network => 1);
  $doc->findnodes('/domainCapabilities/os/enum[@name="firmware"]/value[text()="efi"]')
    or die "EFI firmware is unavailable for $architecture; install your distribution's EFI firmware package\n";
  return 1;
}

1;

=pod

=head1 Cloudmin::Config::Plugin::KVM

Enable KVM, native libvirt services, NAT, local storage and EFI firmware

=head1 SYNOPSIS

cloudmin-config-system --include KVM

=head1 LICENSE AND COPYRIGHT

Licensed under the GPLv3. Copyright 2017-2026 Cloudmin, LLC.

Authors: Ilia Ross <ilia@webmin.dev>, Joe Cooper <joe@webmin.com>,
and Jamie Cameron <jamie@webmin.com>.

=cut
