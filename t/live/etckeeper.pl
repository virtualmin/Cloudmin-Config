#!/usr/bin/perl
# Test stock Etckeeper hooks with temporary history and the installed timer.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Temp qw(tempdir);
use Test::More;
use Log::Log4perl qw(:easy);
use Cloudmin::Config::Plugin::Etckeeper;

$^O eq 'linux' && $< == 0
  or die "Run this test as root on a disposable Linux VM\n";
Log::Log4perl->easy_init($ERROR);
my $plugin = Cloudmin::Config::Plugin::Etckeeper->new();
$plugin->use_webmin();
our %gconfig;
my $rpm = $gconfig{os_type} eq 'redhat-linux';
my $dir = tempdir('/tmp/cloudmin-etckeeper-history-XXXXXX', CLEANUP => 1);
local $ENV{ETCKEEPER_DIR} = $dir;

# Keep every Git operation and Etckeeper hook inside the disposable directory.
open(my $fh, '>', "$dir/example.conf") or die $!;
print {$fh} "fixture=yes\n";
close($fh) or die $!;
chmod(0600, "$dir/example.conf") or die $!;
my $before = $plugin->systemd_state('etckeeper.timer');
is($before->{LoadState}, 'loaded', 'the distribution supplies a daily timer');

# Debian's package initializes history before the configuration plugin runs.
if (!$rpm) {
  $plugin->run_command('etckeeper init');
}
ok(eval { $plugin->actions(); 1 }, 'initial setup succeeds with stock hooks')
  or die $@;
ok(-d "$dir/.git", 'history is initialized with the stock Git backend');
ok(-f "$dir/.etckeeper", 'Etckeeper records file permissions');

# An existing commit and uncommitted edits must survive a second setup run.
system('git', '-C', $dir, '-c', 'user.name=Cloudmin test',
       '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Initial fixture')
  == 0 or die "Cannot commit fixture\n";
my $head = `git -C '$dir' rev-parse HEAD`;
$? == 0 or die "Cannot read fixture revision\n";
open($fh, '>>', "$dir/example.conf") or die $!;
print {$fh} "keep=this edit\n";
close($fh) or die $!;
ok(eval { $plugin->actions(); 1 }, 'repeated setup succeeds') or die $@;
is(`git -C '$dir' rev-parse HEAD`, $head, 'existing commits are preserved');
open($fh, '<', "$dir/example.conf") or die $!;
is(do { local $/; <$fh> }, "fixture=yes\nkeep=this edit\n", 'local edits survive');
close($fh);
is((stat("$dir/example.conf"))[2] & 07777, 0600, 'file permissions survive');

# RPM setup enables the timer; DEB setup preserves the package-managed state.
my $after = $plugin->systemd_state('etckeeper.timer');
is($after->{ActiveState}, $rpm ? 'active' : $before->{ActiveState},
   'daily scheduling has the expected state');
is($after->{UnitFileState}, $rpm ? 'enabled' : $before->{UnitFileState},
   'startup setting has the expected state');
# A broken temporary repository must warn without stopping configuration.
SKIP: {
  skip 'Debian packages initialize history outside this plugin', 3 if !$rpm;
  my $broken = tempdir('/tmp/cloudmin-etckeeper-broken-XXXXXX', CLEANUP => 1);
  local $ENV{ETCKEEPER_DIR} = $broken;
  open(my $bad, '>', "$broken/.git") or die $!;
  print {$bad} "invalid git directory fixture\n";
  close($bad) or die $!;
  my ($output, $ok) = ('');
  {
    open(my $capture, '>', \$output) or die $!;
    local *STDOUT = $capture;
    $ok = eval { $plugin->actions(); 1 };
  }
  ok($ok, 'real initialization failure is nonfatal') or diag $@;
  like($output, qr/Warning: Command failed: etckeeper init/,
    'failed initialization reports a warning');
  ok(-f "$broken/.git", 'failed setup leaves the existing repository untouched');
}
done_testing();
