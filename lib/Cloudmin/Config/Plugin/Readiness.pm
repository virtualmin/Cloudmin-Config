package Cloudmin::Config::Plugin::Readiness;
use strict;
use warnings;
use parent 'Cloudmin::Config::Plugin';
use File::Temp qw(tempdir);
use Cloudmin::Config::Libvirt;

# new(class, [options]) Runs the final checks after every required setup step.
sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(name => 'Readiness', depends => [qw(KVM Webmin Fail2ban)], %args);
}

# check_workers(self) Runs key generation and inspection on disposable inputs.
sub check_workers {
  my ($self) = @_;
  my $root = $self->root();
  require "$root/server-manager/lib/Cloudmin/Worker.pm";
  my $worker = Cloudmin::Worker->new();
  my $key = $worker->run('keypair', {});
  $key->{public_key} =~ /^ssh-rsa / or die "SSH key generation returned no valid public key\n";
  # Worker cleanup removes the generated private key.
  my $dir = tempdir('cloudmin-readiness-XXXXXX', TMPDIR => 1, CLEANUP => 1);
  open(my $disk, '>', "$dir/probe.raw") or die "Cannot create test disk: $!\n";
  print {$disk} "\0" x 65536 or die "Cannot write test disk: $!\n";
  close($disk) or die "Cannot close test disk: $!\n";
  # Boot the isolated appliance too: /dev/kvm and qemu-img alone do not prove
  # nested virtualization or the distribution's libguestfs tools work.
  $self->spin('Booting isolated KVM appliance');
  my $info = eval { $worker->run('inspect', { format => 'raw', appliance => 1 },
    files => { image => "$dir/probe.raw" }); };
  if (!$info) {
    # Keep the original error: the known UTM failure may not be the cause.
    # Suggest an alternative host only when the environment matches.
    my $error = $@ || "Inspection worker returned no result\n";
    die "KVM image appliance failed to boot; Cloudmin setup cannot complete.\n".
      "Check KVM access, libguestfs, and the running kernel and its modules.\n".
      "This failure has occurred with Ubuntu kernel 7.0.0-34 under ARM64 Apple/UTM nested virtualization.\n".
      "If this matches your host, try Rocky Linux 10 or Debian 13, or retry after kernel or hypervisor updates.\n".
      "Worker error: $error";
  }
  $info->{'virtual-size'} == 65536 or die "Isolated disk worker returned an invalid size\n";
  $info->{appliance} or die "Isolated image inspection appliance is unavailable\n";
  return 1;
}

# actions(self) Requires a working management stack before installation succeeds.
sub actions {
  my ($self) = @_;
  $self->use_webmin();
  $self->spin('Checking Cloudmin readiness');
  # Check installed modules and worker dependencies before launching probes.
  for my $module (qw(server-manager xterm nftables proc mount useradmin systemd)) {
    foreign_check($module) or die "Required Webmin module is missing: $module\n";
  }
  for my $package (qw(Sys::Virt Sys::Guestfs XML::LibXML YAML::XS DBI DBD::SQLite Net::WebSocket::Server)) {
    eval "require $package; 1" or die "Cannot load required Perl module $package: $@";
  }
  for my $command (qw(qemu-img xorriso ssh ssh-keygen bsdtar systemd-run nft fail2ban-client)) {
    has_command($command) or die "Required command is missing: $command\n";
  }
  # Management and ban services must be running and enabled at boot.
  for my $service (qw(webmin fail2ban)) {
    $self->require_unit("$service.service", 1, 1);
  }
  # Idle daemons can exit; sockets must listen and services must start at boot.
  my $plan = Cloudmin::Config::Libvirt::installed_plan();
  for my $unit (@{$plan->{sockets}}) { $self->require_unit($unit, 1, 1); }
  for my $unit (@{$plan->{services}}) { $self->require_unit($unit, 0, 1); }
  # Inspect the same Webmin profile table that Nftables creates.
  foreign_require('nftables', 'nftables-lib.pl');
  my $table = nftables::profile_base_table_name('cloudmin');
  $self->run_command("nft list table inet $table");
  $self->run_command('fail2ban-client status sshd');
  $self->run_command('fail2ban-client status webmin-auth');
  $self->check_workers();
  $self->done(1);
}

1;
