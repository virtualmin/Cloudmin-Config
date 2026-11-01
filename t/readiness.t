use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cloudmin::Config::Plugin::Readiness;

{
  package TestReadiness;
  use parent -norequire, 'Cloudmin::Config::Plugin::Readiness';
  # root(self) Selects the in-memory worker fixture instead of installed Webmin.
  sub root { return $FindBin::Bin; }
  # spin(self, [message]) Captures progress without installation logs.
  sub spin { push @{$_[0]->{messages}}, $_[1]; }
}
{
  package Cloudmin::Worker;
  our ($failure, $request, $probe_size, $calls);
  # new(class) Models a worker without starting systemd or QEMU.
  sub new { return bless {}, $_[0]; }
  # run(self, task, request, [options]) Supplies boot results and errors.
  sub run {
    my ($self, $task, $data, %options) = @_;
    # The preceding key check must pass before the appliance is attempted.
    return { public_key => 'ssh-rsa fixture' } if $task eq 'keypair';
    # Reject unmodeled worker tasks instead of silently accepting them.
    die "Unexpected task: $task\n" if $task ne 'inspect';
    $calls++;
    $request = $data;
    $probe_size = -s $options{files}{image};
    # Simulate a boot failure after recording the inspection request.
    die $failure if $failure;
    return { 'virtual-size' => $probe_size, appliance => 1 };
  }
}

# Load the fixture through the same absolute require used for installed workers.
local $INC{"$FindBin::Bin/server-manager/lib/Cloudmin/Worker.pm"} = __FILE__;
my $ready = TestReadiness->new();
local $Cloudmin::Worker::calls = 0;
ok($ready->check_workers(), 'successful appliance boot passes readiness');
is_deeply($Cloudmin::Worker::request, { format => 'raw', appliance => 1 },
  'readiness requests a real appliance boot with no workaround options');
is($Cloudmin::Worker::probe_size, 65536, 'readiness uses a small disposable disk');
is($ready->{messages}[-1], 'Booting isolated KVM appliance', 'progress omits the timeout detail');

# Preserve different failures without claiming that every host has the UTM bug.
for my $error ("Image worker timed out\n", "Cannot open /dev/kvm\n") {
  local $Cloudmin::Worker::failure = $error;
  my $before = $Cloudmin::Worker::calls;
  ok(!eval { $ready->check_workers(); 1 }, 'failed appliance blocks installation');
  my $message = $@;
  like($message, qr/Cloudmin setup cannot complete/, 'failure cannot be mistaken for success');
  like($message, qr/\Q$error\E/, 'original worker error is retained');
  like($message, qr/If this matches your host.*Rocky Linux 10 or Debian 13/s,
    'alternative host advice is conditional');
  is($Cloudmin::Worker::calls, $before + 1, 'failed boot is not retried with a workaround');
}

# A corrected environment can pass on the next run; failure is not remembered.
ok($ready->check_workers(), 'a later successful boot passes without an override');
done_testing();
