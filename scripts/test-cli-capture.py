#!/usr/bin/env python3
"""Verify packaged CLI capture in a private Linux Xvfb desktop, using synthetic data."""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', default=os.environ.get('RECALL_CLI_BINARY'))
    parser.add_argument('--dotnet', default=os.environ.get('DOTNET_HOST_PATH', 'dotnet'))
    parser.add_argument('--fixture-python', default='/usr/bin/python3')
    parser.add_argument('--output', type=Path, help='Optional JSON evidence file')
    parser.add_argument('--keep-library', action='store_true', help='Retain the synthetic test library')
    args = parser.parse_args()
    if not args.cli:
        parser.error('Supply --cli or RECALL_CLI_BINARY pointing to the packaged CLI.')
    if sys.platform != 'linux':
        parser.error('This test requires Linux and launches its own Xvfb display; it never records the current desktop.')
    for command in ('Xvfb', 'ffmpeg', 'ffprobe', 'tesseract'):
        if not shutil.which(command):
            parser.error(f'Required test dependency is missing: {command}')

    temporary = Path(tempfile.mkdtemp(prefix='recall-capture-acceptance-'))
    library = temporary / 'library'
    executable = str(Path(args.cli).resolve())
    prefix = ([args.dotnet, executable] if executable.endswith('.dll') else [executable])
    prefix += ['--data-dir', str(library), '--json']
    env = dict(os.environ)
    env.pop('WAYLAND_DISPLAY', None)
    # A caller's engine overrides must not turn this into a simulated capture test.
    env['RECALL_FFMPEG'] = shutil.which('ffmpeg')
    env['RECALL_FFPROBE'] = shutil.which('ffprobe')
    env['RECALL_TESSERACT'] = shutil.which('tesseract')
    fixture = None
    display = None
    evidence = None
    service_stopped = False
    started = time.monotonic()

    def run(*words, timeout=90):
        result = subprocess.run(prefix + list(words), env=env, text=True,
                                capture_output=True, timeout=timeout)
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(f'{words}: invalid JSON, exit {result.returncode}: {result.stderr}') from error
        if result.returncode or not value.get('ok'):
            raise RuntimeError(f'{words}: {value}')
        return value['result']

    def wait_for(description, check, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if display.poll() is not None or fixture.poll() is not None:
                raise RuntimeError('The isolated display or synthetic fixture exited early.')
            value = check()
            if value:
                return value
            time.sleep(.5)
        raise RuntimeError(f'Timed out waiting for {description}')

    def stop_process(process):
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    try:
        # Xvfb chooses a free display. No input is sent to the user's desktop.
        read_fd, write_fd = os.pipe()
        try:
            with (temporary / 'xvfb.log').open('w') as log:
                display = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-screen', '0',
                                            '1280x800x24', '-nolisten', 'tcp'],
                                           pass_fds=(write_fd,), stdout=log, stderr=log)
            os.close(write_fd)
            write_fd = -1
            if not select.select([read_fd], [], [], 15)[0]:
                raise RuntimeError('Xvfb did not publish a display within 15 seconds.')
            number = os.read(read_fd, 32).decode().strip()
            if not number.isdigit():
                raise RuntimeError('Xvfb did not return a valid private display number.')
            env['DISPLAY'] = ':' + number
        finally:
            os.close(read_fd)
            if write_fd != -1:
                os.close(write_fd)
        ready = temporary / 'fixture-ready'
        with (temporary / 'fixture.log').open('w') as log:
            fixture = subprocess.Popen([args.fixture_python,
                                        str(Path(__file__).with_name('cli-capture-fixture.py')),
                                        '--ready-file', str(ready)], env=env, stdout=log, stderr=log)
        wait_for('synthetic scene', lambda: ready.exists(), seconds=15)
        run('library', 'init', '--format', 'windows')
        run('config', 'set', 'retention-days', '0')
        run('config', 'set', 'capture-interval', '1')
        # This is a private display containing only the generated fixture.
        run('config', 'set', 'excluded-apps', '[]')
        run('recording', 'start')
        wait_for('active recording', lambda: run('recording', 'status').get('active'))
        found = wait_for('captured Aurora text', lambda: run('search', 'Aurora'))
        wait_for('more than one real captured frame', lambda: len(run('records', 'list')) >= 2)
        stopped = run('recording', 'stop')
        assert not stopped['active'], stopped
        frames = run('records', 'list')
        time.sleep(2)
        assert len(run('records', 'list')) == len(frames), 'Frames were added after stop completed'
        sessions = run('sessions', 'list')
        assert sessions and all(s.get('endedAt') for s in sessions), 'Capture left an open session'
        optimized = run('storage', 'optimize')
        assert len(run('records', 'list')) == len(frames), 'Optimization changed record count'
        assert run('search', 'Aurora'), 'Optimization lost recognized text'
        exported = run('records', 'export', '--output', str(temporary / 'export'))
        assert exported['count'] == len(frames), 'Export omitted captured records'
        assert (temporary / 'export' / 'frames.json').exists(), 'Export metadata is missing'
        stats = run('storage', 'stats')
        assert stats['totalBytes'] > 0
        assert run('storage', 'check')['integrity'] == 'ok'
        run('service', 'stop')
        wait_for('service shutdown', lambda: not run('recording', 'status').get('available'), seconds=15)
        service_stopped = True
        evidence = {'realCapture': True, 'backend': 'Xvfb + FFmpeg x11grab',
                    'syntheticOnly': True, 'frames': len(frames), 'searchMatches': len(found),
                    'bytes': stats['totalBytes'], 'optimization': optimized,
                    'elapsedSeconds': round(time.monotonic() - started, 2)}
        if args.keep_library:
            evidence['temporaryLibrary'] = str(library)
    finally:
        if library.exists() and not service_stopped:
            for command in (('recording', 'stop'), ('service', 'stop')):
                try:
                    run(*command, timeout=15)
                except Exception as failure:
                    print(f'Cleanup {command}: {failure}', file=sys.stderr)
        stop_process(fixture)
        stop_process(display)
        if not args.keep_library:
            shutil.rmtree(temporary)
        else:
            print(f'Synthetic evidence: {temporary}', file=sys.stderr)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence))


if __name__ == '__main__':
    main()
