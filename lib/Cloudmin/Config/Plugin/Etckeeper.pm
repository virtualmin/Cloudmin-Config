package Cloudmin::Config::Plugin::Etckeeper;
use strict;
use warnings;
use parent 'Cloudmin::Config::Plugin';

our %gconfig;

# new(class, [options]) Sets up configuration history after host checks.
sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(name => 'Etckeeper', depends => ['Platform'], %args);
}

# actions(self) Completes Etckeeper setup not handled by the OS package.
sub actions {
  my ($self) = @_;
  $self->use_webmin();
  $self->spin();
  # Configuration history is useful, but its failure must not block setup.
  my $ok = eval {
    has_command('etckeeper') or die "Etckeeper is not installed\n";
    # RPM packages need initialization and daily commits enabled explicitly.
    if ($gconfig{'os_type'} eq 'redhat-linux') {
      $self->run_command('etckeeper init');
      $self->systemd_action('enable', 'etckeeper.timer');
      $self->systemd_action('start', 'etckeeper.timer');
      $self->require_unit('etckeeper.timer', 1, 1);
    }
    # Debian and Ubuntu packages initialize history and schedule commits.
    # Keep their setup and any administrator choices unchanged.
    1;
  };
  # Skip the remaining Etckeeper steps, report the cause and continue setup.
  if (!$ok) {
    my $error = $@ || 'Etckeeper setup failed';
    return $self->done(2, $error);
  }
  $self->done(1);
}

1;
