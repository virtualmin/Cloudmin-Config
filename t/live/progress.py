#!/usr/bin/env python3
"""Check configuration progress through the real CLI, directly and through tee."""
import errno
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import tempfile
import time


def terminal(command, env):
    """Run a command on a private terminal and capture its status and output."""
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                               env=env, start_new_session=True)
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            if not select.select([master], [], [], 0.2)[0]:
                continue
            try:
                data = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            output.extend(data)
        else:
            raise TimeoutError('Configuration progress did not finish')
        return process.wait(timeout=2), bytes(output)
    finally:
        # Kill the fixture and any spinner child if an assertion or timeout fails.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        os.close(master)


root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='cloudmin-progress-') as directory:
    work = Path(directory)
    plugins = work / 'Cloudmin/Config/Plugin'
    plugins.mkdir(parents=True)
    # Use harmless plugins so the real CLI and dispatcher need no host changes.
    (plugins / 'ProgressFixture.pm').write_text(r'''
package Cloudmin::Config::Plugin::ProgressFixture;
use parent 'Cloudmin::Config::Plugin';
sub new { my ($class, %args) = @_; $class->SUPER::new(name => 'ProgressFixture', %args) }
sub actions {
  my ($self) = @_;
  $self->spin('First step');
  $self->spin('Updated first step');
  select undef, undef, undef, 0.5;
  die "Unexpected fixture failure\n" if $ENV{PROGRESS_RESULT} eq 'die';
  $self->done(0, 'Required step failed') if $ENV{PROGRESS_RESULT} eq 'failure';
  $self->done(2, 'Optional step failed');
}
1;
''')
    (plugins / 'NextFixture.pm').write_text(r'''
package Cloudmin::Config::Plugin::NextFixture;
use parent 'Cloudmin::Config::Plugin';
sub new { my ($class, %args) = @_; $class->SUPER::new(name => 'NextFixture', %args) }
sub actions {
  my ($self) = @_;
  $self->spin('Second step');
  $self->done(1);
}
1;
''')
    command = ['perl', '-I' + str(work), '-I' + str(root / 'lib'),
               str(root / 'bin/cloudmin-config-system'),
               '--include', 'ProgressFixture', 'NextFixture',
               '--log', str(work / 'configuration.log')]
    for piped in (False, True):
        for result in ('warning', 'failure', 'die'):
            # pipefail retains the CLI status when tee forwards its output.
            invocation = (['bash', '-o', 'pipefail', '-c', '"$@" | tee /dev/null',
                           'progress'] + command) if piped else command
            status, output = terminal(invocation, dict(os.environ, TERM='xterm',
                                                       PROGRESS_RESULT=result))
            text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output.decode(errors='replace'))
            steps = re.findall(r'\[(\d+/\d+)\]', text)
            assert b'\x1b[?25l' in output and b'\x1b[?25h' in output, text
            assert '  Done' not in text, text
            if result == 'warning':
                # Updates retain their step number, and warnings allow later work.
                assert status == 0 and steps == ['1/2', '1/2', '2/2'], (status, text)
                assert '⚠' in text and 'Warning: Optional step failed' in text, text
                assert '✔' in text and text.index('⚠') < text.index('Second step'), text
                for color in (42, 43):
                    assert re.search(rb'\x1b\[[0-9;]*' + str(color).encode() +
                                     rb'(?:;[0-9]+)*m', output), output
            else:
                # Both explicit failures and unexpected exceptions stop later work.
                assert status != 0 and steps == ['1/2', '1/2'], (status, text)
                assert 'Second step' not in text, text
                if result == 'failure':
                    assert '✘' in text and 'Required step failed' in text, text
                else:
                    assert 'Unexpected fixture failure' in text, text
            print('PASS:', 'tee' if piped else 'terminal', result)
