package Cloudmin::Config::KVM;
use strict;
use warnings;
use 5.010_001;

# new(class, [options]) Creates the KVM bundle; options are unused.

sub new {
  my ( $class, %args ) = @_;
  my $self = {};

  return bless $self, $class;
}

# plugins(self) Lists the required plugins; dependencies determine run order.
sub plugins {
  return [qw(Platform Etckeeper KVM Webmin Nftables Fail2ban Readiness)];
}

1;
