package Cloudmin::Config::Plugin::Cloudmin;
use strict;
use warnings;
no warnings qw(once);
no warnings 'uninitialized';
use parent 'Cloudmin::Config::Plugin';

our $config_directory;
our (%gconfig, %miniserv);
our $trust_unknown_referers = 1;

sub new {
  my ($class, %args) = @_;

  # inherit from Plugin
  my $self
    = $class->SUPER::new(name => 'Cloudmin', depends => ['Usermin'], %args);

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
    # my %cconfig = foreign_config("server-manager");
    # save_module_config(\%cconfig, "server-manager");
    $self->done(1);    # OK!
  };
  if ($@) {
    $self->done(0);
  }
}

1;
