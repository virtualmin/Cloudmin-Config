package Cloudmin::Config::Plugin::CGroups;
use strict;
use warnings;
no warnings qw(once);
use parent 'Cloudmin::Config::Plugin';

our $config_directory;
our (%gconfig, %miniserv);
our $trust_unknown_referers = 1;

my $log = Log::Log4perl->get_logger("cloudmin-config-system");

sub new {
  my ($class, %args) = @_;

  # inherit from Plugin
  my $self = $class->SUPER::new(name => 'CGroups', %args);

  return $self;
}

# actions method performs whatever configuration is needed for this
# plugin. XXX Needs to make a backup so changes can be reverted.
sub actions {
  my $self = shift;

  use Cwd;
  my $cwd  = getcwd();
  my $root = $self->root();
  chdir($root);
  $0 = "$root/server-manager/config-system.pl";
  push(@INC, $root);
  eval 'use WebminCore';    ## no critic
  init_config();

  $self->spin();
  eval {
      systemctl start cgconfig
      systemctl enable cgconfig
  };
  if ($@) {
    $self->done(0);
  }
}

1;

=pod

=head1 Cloudmin::Config::Plugin::CGroups

Enable cgconfig services for managing cgroups

=head1 SYNOPSIS

cloudmin config-system --include CGroups

=head1 LICENSE AND COPYRIGHT

Licensed under the GPLv3. Copyright 2017-2025, Joe Cooper <joe@virtualmin.com>

=cut

