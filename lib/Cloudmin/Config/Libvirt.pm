package Cloudmin::Config::Libvirt;
use strict;
use warnings;

# service_plan(modular) Lists services and sockets for the chosen layout.
# A true argument selects modular daemons; false selects libvirtd. Missing
# units must fail setup rather than trigger a switch to the other layout.
sub service_plan {
  my ($modular) = @_;
  my @daemons = $modular ? qw(virtnetworkd virtstoraged virtqemud) : qw(libvirtd);
  my @services = map { "$_.service" } @daemons;
  # Both layouts need the shared logging and locking sockets.
  my @sockets = (qw(virtlogd.socket virtlockd.socket),
    map { ("$_.socket", "$_-ro.socket", "$_-admin.socket") } @daemons);
  return { layout => $modular ? 'modular' : 'monolithic',
    services => \@services, sockets => \@sockets };
}

# installed_plan() Selects modular libvirt when virtqemud is executable.
sub installed_plan {
  return service_plan(-x '/usr/sbin/virtqemud');
}

1;
