#!/usr/bin/env python3
"""Build a self-contained Recall CLI for the current host; no user data is read."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', default=os.environ.get('DOTNET_HOST_PATH', 'dotnet'))
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
    args = parser.parse_args()
    system = {'Darwin': 'osx', 'Windows': 'win', 'Linux': 'linux'}[platform.system()]
    if system == 'osx':
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
        if int(sdk.split('.')[0]) < 26:
            parser.error('The shared Mac sources require the macOS 26+ SDK; select Xcode 26+ with xcode-select.')
    arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64'}[platform.machine()]
    rid = f'{system}-{arch}'
    name = f'Recall-CLI-{rid}'
    release = ROOT / 'release'
    release.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='recall-cli-build-') as temporary:
        output = Path(temporary) / name
        subprocess.run([args.dotnet, 'publish', str(ROOT / 'CLI/Recall.Cli.csproj'), '-c', args.configuration,
                        '-r', rid, '--self-contained', 'true', '-p:PublishSingleFile=false', '-o', str(output)], check=True)
        if system == 'osx':
            configuration = args.configuration.lower()
            subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'macOS'), '-c', configuration, '--product', 'Recall'], check=True)
            binary_directory = subprocess.check_output(['swift', 'build', '--package-path', str(ROOT / 'macOS'), '-c', configuration, '--show-bin-path'], text=True).strip()
            shutil.copy2(Path(binary_directory) / 'Recall', output / 'recall-macos-core')
            for binary in ('recall', 'recall-macos-core'):
                subprocess.run(['codesign', '--force', '--sign', '-', str(output / binary)], check=True)
        shutil.copy2(ROOT / 'docs/cli.md', output / 'CLI.md')
        files = sorted(p for p in output.rglob('*') if p.is_file())
        (output / 'MANIFEST.sha256').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(output).as_posix()}\n' for p in files))
        # tar preserves executable bits on Unix. Windows receives a standard ZIP.
        archive = Path(shutil.make_archive(str(release / name), 'zip' if system == 'win' else 'gztar', temporary, name))
        archive.with_name(archive.name + '.sha256').write_text(f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n')
        destination = release / name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(output, destination)
        print(f'CLI: {destination / ("recall.exe" if system == "win" else "recall")}')
        print(f'Archive: {archive}')


if __name__ == '__main__':
    main()
