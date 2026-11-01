package Cloudmin::Config::Plugin::Fail2ban;
use strict;
use warnings;
use parent 'Cloudmin::Config::Plugin';

# new(class, [options]) Requires the host firewall before enabling bans.
sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(name => 'Fail2ban', depends => ['Nftables'], %args);
}

# actions(self) Enables SSH and Webmin jails using journald and nftables.
sub actions {
  my ($self) = @_;
  $self->use_webmin();
  $self->spin();
  # Use the actual listening ports in bans, including custom SSH ports.
  my %miniserv;
  get_miniserv_config(\%miniserv);
  my $webmin_port = $miniserv{port} || 10000;
  $webmin_port =~ /\A\d+\z/ or die "Invalid Webmin port\n";
  open(my $sshd, '-|', '/usr/sbin/sshd', '-T') or die "Cannot inspect SSH configuration: $!\n";
  my @ports;
  while (<$sshd>) { push @ports, $1 if /^port (\d+)$/; }
  close($sshd) && @ports or die "Cannot determine the SSH listening ports\n";
  my $ssh_ports = join(',', @ports);
  # Keep host protection in a separate jail file owned by this installer.
  $self->write_config('/etc/fail2ban/jail.d/cloudmin.conf', <<EOF);
# Cloudmin host protection. Guest services are managed inside each guest.
[DEFAULT]
backend = systemd
banaction = nftables[type=multiport]
banaction_allports = nftables[type=allports]

[sshd]
enabled = true
port = $ssh_ports

[webmin-auth]
enabled = true
port = $webmin_port
journalmatch = _SYSTEMD_UNIT=webmin.service
EOF
  # Validate all jail files before replacing the running daemon.
  $self->run_command('fail2ban-client -t');
  $self->systemd_action('enable', 'fail2ban.service');
  $self->systemd_action('restart', 'fail2ban.service');
  # The systemd service can return before the control socket is listening.
  my $ready;
  for (1 .. 30) {
    # A successful ping permits the per-jail checks to proceed.
    if ($self->logsystem('fail2ban-client ping') == 0) { $ready = 1; last; }
    sleep(1);
  }
  # A running process alone does not prove both required jails loaded.
  die "Fail2ban did not become ready\n" unless $ready;
  $self->run_command('fail2ban-client status sshd');
  $self->run_command('fail2ban-client status webmin-auth');
  $self->done(1);
}

1;
