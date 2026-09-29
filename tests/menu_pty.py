"""Regression test for macOS SIGTTIN submenu hangs. No display changes."""
import os
from pathlib import Path
import pty
import select
import signal
import time

binary = Path(__file__).resolve().parents[1] / 'build' / 'hidpi'
pid, terminal = pty.fork()
if pid == 0:
    os.execv(str(binary), [str(binary)])

pending = b''


def expect(text, timeout=20):
    global pending
    deadline = time.monotonic() + timeout
    while text.encode() not in pending:
        if time.monotonic() > deadline:
            raise AssertionError((text, pending.decode(errors='replace')))
        if select.select([terminal], [], [], 0.1)[0]:
            pending += os.read(terminal, 65536)
    before, pending = pending.split(text.encode(), 1)
    return before.decode(errors='replace')


def send(text):
    os.write(terminal, text.encode())


finished = False
try:
    expect('Action [1–3, q to quit]:')
    send('3\n')
    expect('Action [1–13, q to go back]:')
    send('12\n')
    assert 'Usage: hidpi' in expect('Action [1–13, q to go back]:')
    send('3\n')
    expect('Action [1–3, q to quit]:')
    send('q\n')
    expect('Action [1–13, q to go back]:')
    send('2\n')
    expect('Action [1–3, q to quit]:')
    send('\x03')
    expect('Action [1–13, q to go back]:')
    send('q\n')
    expect('Action [1–3, q to quit]:')
    send('q\n')
    _, status = os.waitpid(pid, 0)
    finished = True
    assert os.waitstatus_to_exitcode(status) == 0
    print('PASS: controlling-terminal submenu input, back navigation, Ctrl-C')
finally:
    if not finished:
        try:
            os.killpg(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except ProcessLookupError:
            pass
    os.close(terminal)
