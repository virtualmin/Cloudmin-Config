#!/usr/bin/env python3
"""Check repeated progress updates in a private terminal on Linux."""
import errno
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import time

library = Path(__file__).resolve().parents[2] / 'lib'
fixture = r'''
use Cloudmin::Config::Plugin;
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($FATAL);
my $first = Cloudmin::Config::Plugin->new(name => 'First', total => 2);
$first->spin('First step');
$first->spin('Updated first step');
$first->done(2, 'Optional step failed');
my $second = Cloudmin::Config::Plugin->new(name => 'Second', total => 2);
$second->spin('Second step');
$second->done(1);
'''
# A private PTY exercises the real spinner without changing the host terminal.
master, slave = pty.openpty()
process = subprocess.Popen(['perl', '-I' + str(library), '-e', fixture],
                           stdin=slave, stdout=slave, stderr=slave,
                           env={**os.environ, 'TERM': 'xterm'})
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
    assert process.wait(timeout=2) == 0, output.decode(errors='replace')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
# Updating a step must retain its number; only the next plugin advances it.
text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output.decode(errors='replace'))
steps = re.findall(r'\[(\d+/\d+)\]', text)
assert steps == ['1/2', '1/2', '2/2'], (steps, text)
# Warnings use the existing colored badge and allow the next step to succeed.
assert '⚠' in text and 'Warning: Optional step failed' in text, text
assert '✔' in text and text.index('⚠') < text.index('Second step'), text
assert b'\x1b[43m' in output or re.search(rb'\x1b\[[0-9;]*43(?:;[0-9]+)*m', output), output
print('Progress and warning badges work; the next step completes')
