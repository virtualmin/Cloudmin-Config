package Cloudmin::Config::Plugin::Platform;
use strict;
use warnings;
use parent 'Cloudmin::Config::Plugin';
use POSIX qw(uname);

# new(class, [options]) Creates the host checks that run before setup.
sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(name => 'Platform', %args);
}

# supported(id, version, architecture) Checks the supported host versions.
sub supported {
  my ($id, $version, $architecture) = @_;
  return 0 unless $architecture =~ /\A(?:x86_64|aarch64)\z/;
  return ($id =~ /\A(?:rocky|almalinux)\z/ && $version =~ /\A10(?:\.\d+)*\z/) ||
    ($id eq 'debian' && $version =~ /\A13(?:\.\d+)*\z/) ||
    ($id eq 'ubuntu' && $version eq '26.04');
}

# actions(self) Rejects unsupported hosts before changing services or files.
sub actions {
  my ($self) = @_;
  $self->spin('Checking the host platform');
  # Read only the OS identifiers needed for package compatibility checks.
  open(my $fh, '<', '/etc/os-release') or die "Cannot read /etc/os-release: $!\n";
  my %os;
  while (<$fh>) {
    $os{$1} = $2 if /\A(ID|VERSION_ID)=["']?([^"'\s]+)["']?\s*$/;
  }
  close($fh);
  # Package support alone is insufficient without systemd and KVM access.
  my @uname = uname();
  supported($os{ID} || '', $os{VERSION_ID} || '', $uname[4])
    or die "Supported hosts: Rocky Linux 10, AlmaLinux 10, Debian 13 and Ubuntu 26.04, x86_64 or aarch64\n";
  -d '/run/systemd/system' or die "Cloudmin requires a systemd host\n";
  -c '/dev/kvm' or die "KVM is unavailable; enable hardware or nested virtualization\n";
  $self->done(1);
}

1;
