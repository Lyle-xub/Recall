#!/usr/bin/env python3
"""Exercise a packaged CLI through real POSIX terminals without opening a library."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True)
    args = parser.parse_args()
    binary = str(Path(args.cli).resolve())
    environment = dict(os.environ, TERM='xterm-256color', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
    environment.pop('NO_COLOR', None)
    environment.pop('FORCE_COLOR', None)
    checks = []

    def check(condition, description):
        if not condition:
            raise AssertionError(description)
        checks.append(description)

    def run(words, *, stream='stdout', width=80, extra=None, expected=0, with_columns=True, interrupt_ready=None):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, width, 0, 0))
        child_environment = dict(environment, COLUMNS=str(width), **(extra or {}))
        if not with_columns:
            child_environment.pop('COLUMNS', None)
        child = subprocess.Popen([binary, *words], stdin=subprocess.DEVNULL,
            stdout=slave if stream == 'stdout' else subprocess.PIPE,
            stderr=slave if stream == 'stderr' else subprocess.PIPE,
            env=child_environment, start_new_session=True)
        os.close(slave)
        chunks = []
        try:
            deadline = time.monotonic() + 30
            interrupted = False
            while time.monotonic() < deadline:
                if interrupt_ready is not None and interrupt_ready.exists() and not interrupted:
                    child.send_signal(signal.SIGINT)
                    interrupted = True
                ready, _, _ = select.select([master], [], [], .1)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as failure:
                        if failure.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    chunks.append(chunk)
                elif child.poll() is not None:
                    break
            else:
                raise AssertionError('CLI did not finish within 30 seconds')
            out, err = child.communicate(timeout=5)
            check(child.returncode == expected, f'exit {expected}: {stream} {words}')
            return b''.join(chunks).decode('utf-8').replace('\r\n', '\n'), (out or err or b'').decode('utf-8')
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            os.close(master)

    for width in [60, 80, 120]:
        raw, other = run(['--version', '--json', '--color', 'always'], width=width)
        payload = json.loads(raw)
        check(payload['ok'] and payload['result']['version'] and '\x1b' not in raw and not other,
              f'JSON is valid and escape-free in a {width}-column TTY')
        text, _ = run(['help', 'search', '--lang', 'en', '--ascii', '--color', 'never'], width=width)
        check(text.isascii() and '\x1b' not in text and '--offset' in text,
              f'ASCII plain help preserves option tokens at {width} columns')
    colored, _ = run(['help', '--lang', 'en'])
    check(re.search(r'\x1b\[[0-9;]*m', colored) is not None, 'Auto color is enabled on stdout TTY')
    plain, _ = run(['help', '--lang', 'en'], extra={'NO_COLOR': '1'})
    check('\x1b' not in plain, 'NO_COLOR suppresses all escape sequences')
    dumb, _ = run(['help', '--lang', 'en'], extra={'TERM': 'dumb'})
    check('\x1b' not in dumb, 'TERM=dumb suppresses all escape sequences')
    measured, _ = run(['help', '--lang', 'en', '--color', 'never'], width=60, with_columns=False)
    check('\x1b' not in measured and 'recall' in measured,
          'Reading the actual terminal width does not emit control sequences')
    error, other = run(['--unknown-terminal-test-option', 'value', '--lang', 'en'], stream='stderr', expected=2)
    check(re.search(r'\x1b\[[0-9;]*m', error) is not None and not other,
          'Error color follows stderr TTY independently of redirected stdout')
    raw, other = run(['--unknown-terminal-test-option', 'value', '--json', '--color', 'always'], expected=2)
    check(json.loads(raw)['error']['code'] == 'usage' and '\x1b' not in raw and not other,
          'JSON usage errors remain escape-free in TTY')
    redirected = subprocess.run([binary, 'help', '--lang', 'en'], capture_output=True, text=True, env=environment, timeout=30)
    check(redirected.returncode == 0 and '\x1b' not in redirected.stdout and not redirected.stderr,
          'Redirected human output stays plain')
    with tempfile.TemporaryDirectory(prefix='recall-terminal-test-') as temporary:
        folder = Path(temporary)
        fixture = folder / 'fixture.png'
        fixture.touch()
        ready = folder / 'engine-ready'
        engine = folder / 'test-ocr-engine'
        engine.write_text('#!/usr/bin/env python3\nimport os, pathlib, time\n'
                          f'pathlib.Path({str(ready)!r}).write_text(str(os.getpid()))\n'
                          'time.sleep(30)\n')
        engine.chmod(0o700)
        raw, other = run(['--data-dir', str(folder / 'library'), 'ocr', 'image', str(fixture), '--json'],
                         extra={'RECALL_TESSERACT': str(engine)}, expected=130, interrupt_ready=ready)
        check(json.loads(raw)['error']['code'] == 'cancelled' and '\x1b' not in raw and not other,
              'SIGINT cancels a running engine with clean JSON and exit 130')
        engine_pid = int(ready.read_text())
        try:
            os.kill(engine_pid, 0)
        except ProcessLookupError:
            check(True, 'Cancellation also reaps the child OCR engine')
        else:
            raise AssertionError('OCR engine survived CLI cancellation')
    print(json.dumps({'passed': len(checks), 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
