use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config::Plugin::Webmin;

our (@calls, @warnings, %miniserv, $root, $inventory_error, $saved_config);
{
  package TestWebminPlugin;
  use parent 'Cloudmin::Config::Plugin::Webmin';
  # These overrides keep configuration tests away from the host system.
  sub use_webmin { }
  sub spin { }
  sub root { $main::root }
  sub systemd_action { push @main::calls, [@_[1, 2]] }
  sub done { push @main::calls, ['done', $_[1]] }
}
{
  package Cloudmin::Config::Plugin::Webmin;
  # Record configuration writes and retain them for the next invocation.
  sub foreign_require { }
  sub lock_file { }
  sub unlock_file { }
  sub write_file {
    $main::saved_config = { %{$_[1]} };
    push @main::calls, ['write', $_[0]];
  }
  sub get_miniserv_config { %{$_[0]} = %main::miniserv }
  sub put_miniserv_config {
    %main::miniserv = %{$_[0]};
    push @main::calls, ['miniserv'];
  }
}
{
  package webmin;
  # Simulate the inventory scan's library reload and unrelated warnings.
  sub build_installed_modules {
    warn "Subroutine example redefined at $main::root/status/status-lib.pl line 42.\n";
    warn "Module check failed\n";
    warn "Subroutine example redefined at $main::root/other.pl line 42.\n";
    warn "Subroutine example redefined at $main::root-extra/status/status-lib.pl line 42.\n";
    die "Inventory failed\n" if $main::inventory_error;
  }
  sub restart_miniserv { push @main::calls, ['restart'] }
}

# New installs add Cloudmin settings while retaining Webmin's own defaults.
for $root ('/usr/share/webmin', '/usr/libexec/webmin') {
  @calls = @warnings = ();
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  local $Cloudmin::Config::Plugin::Webmin::config_directory = '/unused';
  local %Cloudmin::Config::Plugin::Webmin::gconfig;
  %miniserv = (port => 12345, ssl => 1);
  TestWebminPlugin->new()->actions();
  is_deeply(\@warnings, [
    "Module check failed\n",
    "Subroutine example redefined at $root/other.pl line 42.\n",
    "Subroutine example redefined at $root-extra/status/status-lib.pl line 42.\n",
  ], "$root suppresses only module library redefinition warnings");
  is_deeply(\@calls, [['write', '/unused/config'], ['miniserv'], ['restart'], ['done', 1]],
    'first run writes additional settings and restarts for TOTP');
  is_deeply($saved_config, { nowebminup => 1, logfiles => 1,
    tempdir => '/var/tmp/.webmin', tempdirdelete => 1 }, 'only Cloudmin settings are added');
  is_deeply(\%miniserv, { port => 12345, ssl => 1, twofactor_provider => 'totp' },
    'server defaults are preserved without theme or cipher overrides');
  warn "After inventory\n";
  is($warnings[-1], "After inventory\n", 'warning handler is restored');

  # An already configured host needs neither writes nor a server restart.
  @calls = ();
  TestWebminPlugin->new()->actions();
  is_deeply(\@calls, [['done', 1]], 'rerun does not rewrite settings or restart Webmin');
}

# Existing theme, TLS, upload and two-factor choices survive configuration.
$root = '/usr/share/webmin';
for my $provider ('totp', 'yubikey', '') {
  @calls = @warnings = ();
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  local $Cloudmin::Config::Plugin::Webmin::config_directory = '/unused';
  my %config = (theme => 'custom-theme', mobile_theme => '', tempdir => '/custom/tmp');
  local %Cloudmin::Config::Plugin::Webmin::gconfig = %config;
  my %server = (port => 12345, ssl => 0, ssl_cipher_list => 'custom-ciphers',
    cipher_list_def => 0, preroot => 'custom-theme', twofactor_provider => $provider);
  %miniserv = %server;
  TestWebminPlugin->new()->actions();
  is_deeply($saved_config, { %config, nowebminup => 1, logfiles => 1 },
    'custom themes and upload storage are preserved');
  is_deeply(\%miniserv, \%server, 'existing server preferences and two-factor opt-out are preserved');
  is_deeply(\@calls, [['write', '/unused/config'], ['done', 1]],
    'CGI configuration changes do not restart the server');
}

# Inventory errors remain fatal and cannot enable TOTP or report success.
@calls = @warnings = ();
$inventory_error = 1;
%miniserv = (port => 12345);
local $SIG{__WARN__} = sub { push @warnings, @_ };
local %Cloudmin::Config::Plugin::Webmin::gconfig =
  (nowebminup => 1, logfiles => 1, tempdir => '/custom/tmp');
local $Cloudmin::Config::Plugin::Webmin::config_directory = '/unused';
eval { TestWebminPlugin->new()->actions() };
like($@, qr/Inventory failed/, 'inventory failure remains fatal');
is_deeply(\@calls, [], 'failed inventory does not alter server settings or report success');
warn "After failure\n";
is($warnings[-1], "After failure\n", 'warning handler is restored after failure');
done_testing();
