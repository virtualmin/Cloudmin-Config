#!/usr/bin/perl
# Run inside `unshare --net` on a disposable host with stock Fail2ban installed.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Temp qw(tempdir);
use Test::More;
use Cloudmin::Config::Plugin::Fail2ban;
# Bans must stay inside a private network namespace on a disposable VM.
$> == 0 && $^O eq 'linux' or die "Run this test as root on a disposable Linux VM\n";
readlink('/proc/self/ns/net') ne readlink('/proc/1/ns/net')
  or die "Run this test with unshare --net\n";
# Copy the packaged configuration and give the fixture its own database.
our $dir = tempdir('/tmp/cloudmin-fail2ban-XXXXXX', CLEANUP => 1);
system('cp', '-a', '/etc/fail2ban', "$dir/config") == 0 or die "Cannot copy fixture configuration\n";
open(my $local, '>', "$dir/config/fail2ban.local") or die $!;
print {$local} "[Definition]\ndbfile = $dir/fail2ban.sqlite3\n";
close($local) or die $!;
{
  package FixtureFail2ban;
  use parent -norequire, 'Cloudmin::Config::Plugin::Fail2ban';
  # write_config(self, path, content) Redirects only the installer-owned jail file.
  sub write_config {
    my ($self, $path, $content) = @_;
    $path eq '/etc/fail2ban/jail.d/cloudmin.conf' or die "Unexpected write $path";
    return $self->SUPER::write_config("$main::dir/config/jail.d/cloudmin.conf", $content);
  }
  # client(self, arguments...) Addresses only the fixture's process and socket.
  sub client {
    my ($self, @args) = @_;
    return system('fail2ban-client', '-c', "$main::dir/config", '-s', "$main::dir/socket",
      '-p', "$main::dir/pid", '--logtarget', "$main::dir/log", @args);
  }
  # systemd_action(self, action, unit) Manages only the private fixture daemon.
  sub systemd_action {
    my ($self, $action, $unit) = @_;
    $unit eq 'fail2ban.service' or die "Unexpected unit $unit";
    # The fixture has no boot integration to enable.
    return 1 if $action eq 'enable';
    # The installer's restart launches only this isolated daemon.
    return $self->client('start') == 0 || die "Fixture start failed\n"
      if $action eq 'restart';
    die "Unexpected fixture action $action";
  }
  # run_command(self, command) Sends checks only to the private daemon.
  sub run_command {
    my ($self, $command) = @_;
    $command =~ s/^fail2ban-client // or die "Unexpected command $command";
    $self->client(split(/ /, $command)) == 0 or die "Fixture command failed: $command\n";
    return 1;
  }
  # logsystem(self, command) Redirects the readiness ping into the fixture.
  sub logsystem {
    my ($self, $command) = @_;
    $command eq 'fail2ban-client ping' or die "Unexpected probe";
    return $self->client('ping');
  }
}
my $p = FixtureFail2ban->new();
# Stop the private daemon even if an assertion or command fails.
END { $p->client('stop') if $p && -e "$dir/pid"; }
# Exercise generated jails and a real ban, then stop the fixture explicitly.
ok(eval { $p->actions(); 1 }, 'stock Fail2ban accepts and starts the generated jails') or diag $@;
is($p->client('set', 'sshd', 'banip', '192.0.2.99'), 0, 'SSH jail creates an nftables ban');
is(system('nft', 'list', 'table', 'inet', 'f2b-table'), 0, 'ban is present in the isolated namespace');
is($p->client('stop'), 0, 'fixture daemon stops');
done_testing();
