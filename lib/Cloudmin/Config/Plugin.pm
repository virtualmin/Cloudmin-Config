package Cloudmin::Config::Plugin;
use strict;
use warnings;
use 5.010_001;
use POSIX;
use Cwd ();
use Cloudmin::Config;
use Time::HiRes qw( sleep );
use feature 'state';
use Term::ANSIColor qw(:constants colored);
use utf8;
use open ':std', ':encoding(UTF-8)';

our $trust_unknown_referers = 1;
our $error_must_die         = 1;

my $log = Log::Log4perl->get_logger("cloudmin-config-system");

sub new {
  my ( $class, %args ) = @_;

  my $self = {
    name    => $args{name},
    depends => $args{depends},
    total   => $args{total},
    bundle  => $args{bundle}
  };
  bless $self, $class;

  return $self;
}

# Plugin short name, used in config definitions
sub name {
  my ( $self, $name ) = @_;
  if ($name) { $self->{name} = $name }
  return $self->{name};
}

# depends(self, [names]) Gets or sets the array reference of prerequisite names.
# Without a new reference, retain the current dependencies.
sub depends {
  my ( $self, $name ) = @_;
  if ($name) { $self->{depends} = $name }
  return $self->{depends};
}

# total(self, [count]) Gets or sets the plugin count used in progress output.
# An omitted or zero count leaves the current value unchanged.
sub total {
  my ( $self, $total ) = @_;
  if ($total) { $self->{total} = $total }
  return $self->{total};
}

# bundle(self, [name]) Gets or sets the selected bundle name.
# An omitted or empty name leaves the selection unchanged.
sub bundle {
  my ( $self, $bundle ) = @_;
  if ($bundle) { $self->{bundle} = $bundle }
  return $self->{bundle};
}

# spin(self, [message]) Displays numbered configuration progress.
sub spin {
  state $count = 1;
  my ($self, $message) = @_;
  $message ||= 'Configuring '.$self->name();
  $log->info($message);
  # Logs and redirected output stay readable without terminal controls.
  if (!-t STDOUT) {
    print "$message ...\n";
    return;
  }
  spinner('new');
  # A new message within the same plugin updates its current progress step.
  if (defined $self->{progress_step}) { print "\r\e[K"; }
  else { $self->{progress_step} = $count++; }
  print '['.YELLOW.$self->{progress_step}.RESET.'/'.GREEN.$self->total().RESET.'] '.$message;
  print "\e[K\e[77G";
  spinner('auto_start');
}

# done(self, result, [error]) Shows the result and keeps failed checks fatal.
sub done {
  my ($self, $result, $error) = @_;
  spinner('auto_done');
  # A successful result completes the current progress step.
  if ($result == 1) {
    $log->info('Succeeded');
    if (-t STDOUT) { spinner('ok'); }
    else { print "  Done\n"; }
  }
  # Warnings allow configuration to continue and remain visible in the log.
  elsif ($result == 2) {
    my $warning = $error || 'Completed with a warning; see the log';
    $warning =~ s/\s+$//;
    $log->warn($self->name().": $warning");
    spinner('meh') if -t STDOUT;
    print "  Warning: $warning\n";
  }
  else {
    # All other results stop the run with the supplied or pending error.
    $error ||= $@ || $self->name().' configuration failed';
    $log->error($error);
    spinner('nok') if -t STDOUT;
    die "$error\n";
  }
}

# root(self) Finds the installed Webmin tree from its server configuration.
sub root {
  my $self = shift;

  $ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
  $ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
  $ENV{'MINISERV_CONFIG'} = $ENV{'WEBMIN_CONFIG'} . "/miniserv.conf";
  open( my $CONF, "<", "$ENV{'WEBMIN_CONFIG'}/miniserv.conf" ) || die RED,
    "Failed to open miniserv.conf", RESET;
  my $root;
  while (<$CONF>) {
    if (/^root=(.*)/) {
      $root = $1;
    }
  }
  close($CONF);
  # Require the actual installed core instead of guessing a fallback path.
  defined($root) && -f "$root/WebminCore.pm"
    or die "Webmin installation root is missing or invalid\n";

  return $root;
}

# logsystem(self, command) Logs shell output and returns the raw wait status.
sub logsystem {
  my $self = shift;
  my $cmd  = shift;

  my $res = `$cmd 2>&1` // "[]";
  # Logging may run commands too, so preserve the original status first.
  my $status = $?;
  $log->info("Code: $status Result: $res");
  return $status;
}

# use_webmin(self) Imports Webmin APIs into the calling plugin, once per package.
sub use_webmin {
  my ($self) = @_;
  state %ready;
  # Webmin checks this process-wide flag, not the calling package variable.
  $main::error_must_die = 1;
  # The package enters an eval string; accept only a Perl package name.
  my $pkg = caller;
  die "Invalid caller package\n" unless $pkg =~ /\A[A-Za-z_]\w*(?:::\w+)*\z/;
  # Imports and configuration globals are initialized once per caller.
  return 1 if $ready{$pkg};
  # Webmin resolves module paths from its working directory and script name.
  my $root = $self->root();
  my $cwd = Cwd::getcwd();
  chdir($root) or die "Cannot enter $root: $!\n";
  $0 = "$root/server-manager/config-system.pl";
  for my $dir ($root, "$root/vendor_perl") {
    push @INC, $dir unless grep { $_ eq $dir } @INC;
  }
  # Import into the plugin package so its unqualified Webmin calls work.
  my $ok = eval "package $pkg; our \$trust_unknown_referers = 1; ".
    'our $error_must_die = 1; require WebminCore; WebminCore->import(); '.
    'init_config(); 1;';
  # Restore the caller's directory before propagating initialization errors.
  my $error = $@;
  chdir($cwd) or die "Cannot return to $cwd: $!\n";
  die "Cannot initialize Webmin: $error" unless $ok;
  $ready{$pkg} = 1;
  return 1;
}

# run_command(self, command) Stops configuration when an external command fails.
sub run_command {
  my ($self, $command) = @_;
  $self->logsystem($command) == 0 or die "Command failed: $command (see log)\n";
  return 1;
}

# systemd_state(self, unit) Reads fresh unit state through Webmin's systemd API.
sub systemd_state {
  my ($self, $unit) = @_;
  $self->use_webmin();
  foreign_require('systemd', 'systemd-lib.pl');
  # Older Webmin releases cannot provide the required live unit state.
  defined &systemd::get_unit_state
    or die "Update Webmin: the systemd get_unit_state API is required\n";
  my ($state, $error) = systemd::get_unit_state($unit);
  die "Cannot inspect $unit: $error\n" if $error;
  return $state;
}

# systemd_action(self, action, unit) Executes a native unit action and checks it.
sub systemd_action {
  my ($self, $action, $unit) = @_;
  $action =~ /\A(?:start|stop|restart|enable|disable)\z/
    or die "Invalid systemd action\n";
  $self->use_webmin();
  foreign_require('systemd', 'systemd-lib.pl');
  # Dispatch only the allowed actions and retain Webmin's failure details.
  no strict 'refs';
  my ($ok, $error) = &{"systemd::${action}_unit"}($unit);
  die "Failed to $action $unit: $error\n" unless $ok;
  return 1;
}

# require_unit(self, unit, [active], [enabled]) Requires an installed unit.
# True optional flags also require active state and startup at boot.
sub require_unit {
  my ($self, $unit, $active, $enabled) = @_;
  my $state = $self->systemd_state($unit);
  $state->{LoadState} eq 'loaded' or die "Required systemd unit is unavailable: $unit ($state->{LoadState})\n";
  !$active || $state->{ActiveState} eq 'active' or die "$unit is not active\n";
  !$enabled || $state->{UnitFileState} eq 'enabled' or die "$unit is not enabled at boot\n";
  return 1;
}

# write_config(self, path, content) Replaces an installer-owned file atomically.
sub write_config {
  my ($self, $path, $content) = @_;
  require File::Temp;
  require File::Basename;
  # A temporary file beside the destination keeps the final rename atomic.
  my ($fh, $tmp) = File::Temp::tempfile('.cloudmin-XXXXXX',
    DIR => File::Basename::dirname($path), UNLINK => 1);
  print {$fh} $content or die "Cannot write $tmp: $!\n";
  close($fh) or die "Cannot close $tmp: $!\n";
  chmod(0644, $tmp) or die "Cannot set permissions on $tmp: $!\n";
  rename($tmp, $path) or die "Cannot replace $path: $!\n";
  return 1;
}

# spinner(command) Controls the terminal animation and result badges.
sub spinner {
  my ($cmd) = @_;
  state $slastsize = 3;
  state $pos       = 1;
  state $schild;
  state $whitecolor;

  # Avoid control sequences and child processes when output is redirected.
  return if !-t STDOUT && !$schild;
  return if $cmd eq 'auto_done' && !$schild;

  # Do we have shades of white?
  if (!$whitecolor) {
    my $colors = `tput colors 2>&1`;
    $whitecolor = 'white';
    $whitecolor = 'bright_white' if ($colors && $colors > 8);
  }

  # Is new spinner
  if ($cmd eq 'new') {
    if ($schild) {
      kill 'KILL', $schild;
      POSIX::waitpid($schild, 0);
    }
    $schild = undef;
    $slastsize = 3;
    $pos = 1;
    return;
  }

  my $sseq = [qw(▒▒▒ █▒▒ ██▒ ███ ▒██ ▒▒█ ▒▒▒)];
  my $sbksp = chr(0x08);
  my $start = sub {
    print "\x1b[?25l";
    $slastsize = 3;
    print colored("$sseq->[0]", 'cyan');
  };
  my $done = sub { print "\x1b[?25h"; };
  my $ok   = sub { print "\e[77G\e[K"; say colored(" ✔ ", "$whitecolor on_green"); };
  my $meh  = sub { print "\e[77G\e[K"; say colored(" ⚠ ", "$whitecolor on_yellow"); };
  my $nok  = sub { print "\e[77G\e[K"; say colored(" ✘ ", "$whitecolor on_red"); };

  my $next = sub {
    print $sbksp x $slastsize;
    print colored("$sseq->[$pos]", 'cyan');
    $pos       = ++$pos % scalar @{$sseq};
    $slastsize = length($sseq->[$pos]);
  };

  # Fork and run spinner asynchronously, until signal received.
  my $auto_start = sub {
    my $ppid = $$;
    system('stty -echo 1>/dev/null 2>&1');
    my $pid  = fork();
    die("Failed to fork progress indicator.\n") unless defined $pid;

    if ($pid) {    # Parent
      $schild = $pid;
      return;
    }
    else {         # Kid stuff
      &$start();
      my $exists;
      while (1) {
        sleep 0.2;
        &$next();

        # Check to be sure parent is still running, if not, die
        $exists = kill 0, $ppid;
        unless ($exists) {
          &$done();
          exit 0;
        }
        $exists = "";
      }
      exit 0;    # Should never get here?
    }
  };

  my $auto_done = sub {
    kill 'KILL', $schild if $schild;
    system('stty echo 1>/dev/null 2>&1');
    POSIX::waitpid($schild, 0) if $schild;
    $schild = undef;
    &$done();
  };

  &$auto_start() if ($cmd eq 'auto_start');
  &$auto_done()  if ($cmd eq 'auto_done');
  &$ok()         if ($cmd eq 'ok');
  &$meh()        if ($cmd eq 'meh');
  &$nok()        if ($cmd eq 'nok');
}

# Restore the cursor and stop the progress child if a plugin dies mid-check.
END { spinner('auto_done'); }

1;
