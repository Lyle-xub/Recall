#!/usr/bin/env python3
"""Prepare pinned native inference engines. No model or user data is uploaded."""
import concurrent.futures, hashlib, io, json, pathlib, shutil, subprocess, tarfile, urllib.request, zipfile, sys, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
DEST=ROOT/'native-runtimes'
ASSETS=[
 ('macos-arm64','llama','https://github.com/ggml-org/llama.cpp/releases/download/b11160/llama-b11160-bin-macos-arm64.tar.gz','5679b3e952772a9f9a39f9d42d7f0eb3d4c424103fe56f5516507583a0c6e3fa'),
 ('windows-x64','llama','https://github.com/ggml-org/llama.cpp/releases/download/b11160/llama-b11160-bin-win-cpu-x64.zip','b144d125972c57eb30062524269b31bf981dfb81d36fad6a1494e18814a06acc'),
 ('windows-x64','whisper','https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.3/whisper-bin-x64.zip','d824b1e37599f882b396e73f1ee0bfd5d0529f700314c48311dcbd00b803321d')]
def prepare(item):
 platform,engine,url,digest=item; out=DEST/platform/engine
 if (out/'.verified').exists():return
 print('Downloading',platform,engine,flush=True)
 data=urllib.request.urlopen(url,timeout=120).read()
 if hashlib.sha256(data).hexdigest()!=digest:raise ValueError('Runtime SHA-256 mismatch')
 out.mkdir(parents=True,exist_ok=True)
 # Vendor binaries reside in one folder; keep only executable/library/resource files.
 def save(name,content,mode=0o755):
  leaf=pathlib.PurePosixPath(name).name
  if not leaf:return
  target=out/leaf;target.write_bytes(content);target.chmod(mode)
 if url.endswith('.zip'):
  with zipfile.ZipFile(io.BytesIO(data)) as archive:
   for f in archive.infolist():
    if not f.is_dir():save(f.filename,archive.read(f))
 else:
  with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:
   for f in archive.getmembers():
    if f.isfile():save(f.name,archive.extractfile(f).read(),f.mode)
   for f in archive.getmembers():
    if f.issym():
     target=out/pathlib.PurePosixPath(f.name).name
     if not target.exists():target.symlink_to(pathlib.PurePosixPath(f.linkname).name)
 (out/'.verified').write_text(digest)
 print('Prepared',platform,engine,flush=True)
def prepare_whisper_mac():
 out=DEST/'macos-arm64'/'whisper';out.mkdir(parents=True,exist_ok=True)
 if (out/'whisper-cli').exists():return
 url='https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.3.tar.gz'
 data=urllib.request.urlopen(url,timeout=120).read()
 if hashlib.sha256(data).hexdigest()!='870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a':raise ValueError('Whisper source hash mismatch')
 with tempfile.TemporaryDirectory(prefix='rewind-whisper-') as folder:
  base=pathlib.Path(folder)
  with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:archive.extractall(base,filter='data')
  source=base/'whisper.cpp-1.8.3';build=base/'build'
  subprocess.run(['cmake','-S',str(source),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DGGML_NATIVE=OFF','-DGGML_METAL_EMBED_LIBRARY=ON','-DWHISPER_BUILD_TESTS=OFF','-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0'],check=True)
  subprocess.run(['cmake','--build',str(build),'--target','whisper-cli','--config','Release','-j','4'],check=True)
  shutil.copy2(build/'bin'/'whisper-cli',out/'whisper-cli')
if __name__=='__main__':
 platform='macos-arm64' if sys.platform=='darwin' else 'windows-x64'
 selected=ASSETS if '--all' in sys.argv else [a for a in ASSETS if a[0]==platform]
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(prepare,selected))
 if platform=='macos-arm64':prepare_whisper_mac()
