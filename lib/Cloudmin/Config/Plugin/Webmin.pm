package Cloudmin::Config::Plugin::Webmin;
use strict;
use warnings;
no warnings qw(once);
use parent 'Cloudmin::Config::Plugin';
our $config_directory;
our %gconfig;

# new(class, [options]) Configures Webmin only on an accepted host.
sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(name => 'Webmin', depends => ['Platform'], %args);
}

# actions(self) Applies Cloudmin settings and refreshes the module inventory.
sub actions {
  my ($self) = @_;
  $self->use_webmin();
  $self->spin();
  foreign_require('webmin', 'webmin-lib.pl');
  # Use package updates and record configuration-file changes.
  my $changed = 0;
  for my $setting (qw(nowebminup logfiles)) {
    if (($gconfig{$setting} || 0) != 1) {
      $gconfig{$setting} = 1;
      $changed = 1;
    }
  }
  # VM image uploads must not fill a small memory-backed /tmp filesystem.
  if (!$gconfig{tempdir}) {
    $gconfig{tempdir} = '/var/tmp/.webmin';
    $gconfig{tempdirdelete} = 1;
    $changed = 1;
  }
  # CGI requests read these settings directly; no server restart is needed.
  if ($changed) {
    lock_file("$config_directory/config");
    write_file("$config_directory/config", \%gconfig);
    unlock_file("$config_directory/config");
  }
  {
    # Module checks may reload libraries already imported by other plugins.
    my $webmin_root = $self->root();
    my $warning_handler = $SIG{__WARN__};
    local $SIG{__WARN__} = sub {
      my $warning = join('', @_);
      return if $warning =~
        m{\ASubroutine \S+ redefined at \Q$webmin_root\E/[^/]+/[^/]+-lib\.pl line \d+\.\n?\z};
      local $SIG{__WARN__} = $warning_handler;
      warn @_;
    };
    webmin::build_installed_modules(1);
  }
  # Offer TOTP on new installs while preserving an existing provider or opt-out.
  my %miniserv;
  lock_file("$config_directory/miniserv.conf");
  get_miniserv_config(\%miniserv);
  my $setup_twofactor = !defined($miniserv{twofactor_provider});
  if ($setup_twofactor) {
    $miniserv{twofactor_provider} = 'totp';
    put_miniserv_config(\%miniserv);
  }
  unlock_file("$config_directory/miniserv.conf");
  webmin::restart_miniserv() if $setup_twofactor;
  $self->done(1);
}

1;
