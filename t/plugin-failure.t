use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config;
use Cloudmin::Config::Plugin;
use Cloudmin::Config::Plugin::Etckeeper;

our @ran;
{
  package Cloudmin::Config::Plugin::Clobber;
  use parent 'Cloudmin::Config::Plugin';
  # actions(self) Models a failed plugin that uses Perl's default variable.
  sub actions {
    push @main::ran, 'Clobber';
    $_ = 'unrelated value';
    die "fixture failed\n";
  }
  package Cloudmin::Config::Plugin::AfterFailure;
  use parent 'Cloudmin::Config::Plugin';
  # actions(self) Records any action incorrectly run after the failure.
  sub actions { push @main::ran, 'AfterFailure' }
}

# Run the real dispatcher with in-memory plugins and a temporary log.
local $INC{'Cloudmin/Config/Plugin/Clobber.pm'} = __FILE__;
local $INC{'Cloudmin/Config/Plugin/AfterFailure.pm'} = __FILE__;
my ($fh, $path) = tempfile(UNLINK => 1);
close($fh) or die $!;
my $config = Cloudmin::Config->new(
  include => ['Clobber', 'AfterFailure'], log => $path,
);
eval { $config->run(); };
like($@, qr/^Clobber: fixture failed/, 'failure identifies the plugin');
is_deeply(\@ran, ['Clobber'], 'failure stops later plugins');
open($fh, '<', $path) or die $!;
my $log = do { local $/; <$fh> };
close($fh);
like($log, qr/\[ERROR\] - Clobber: fixture failed/, 'log identifies the plugin');
# A failed optional plugin must warn through the real dispatcher and continue.
{
  no warnings qw(redefine once);
  local @ran;
  local *Cloudmin::Config::Plugin::Etckeeper::depends = sub { [] };
  local *Cloudmin::Config::Plugin::Etckeeper::use_webmin = sub { };
  local *Cloudmin::Config::Plugin::Etckeeper::has_command = sub { '/usr/bin/etckeeper' };
  local $Cloudmin::Config::Plugin::Etckeeper::gconfig{os_type} = 'redhat-linux';
  local *Cloudmin::Config::Plugin::Etckeeper::run_command = sub {
    die "History initialization failed\n";
  };
  my $output = '';
  open(my $capture, '>:encoding(UTF-8)', \$output) or die $!;
  my $ok;
  {
    local *STDOUT = $capture;
    $ok = eval {
      Cloudmin::Config->new(include => ['Etckeeper', 'AfterFailure'],
        log => $path)->run();
    };
  }
  ok($ok, 'optional failure does not fail configuration') or diag $@;
  is_deeply(\@ran, ['AfterFailure'], 'next plugin runs after the warning');
  like($output, qr/Warning: History initialization failed/, 'terminal shows the cause');
  open($fh, '<', $path) or die $!;
  $log = do { local $/; <$fh> };
  close($fh);
  like($log, qr/\[WARN\] - Etckeeper: History initialization failed/,
    'log records the warning and plugin name');
}
done_testing();
