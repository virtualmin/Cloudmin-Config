package Cloudmin::Config::KVM;
use strict;
use warnings;
use 5.010_001;

# A list of plugins for configuring a LAMP stack

sub new {
  my ( $class, %args ) = @_;
  my $self = {};

  return bless $self, $class;
}

sub plugins {
  return [
    "Cloudmin", "Webmin", "Bind", "CGroups",
    "Fail2banFirewalld", "Firewalld", "Etckeeper",
    "Net", "Xen"
  ];
}

1;
