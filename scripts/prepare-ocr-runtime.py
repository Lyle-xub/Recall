#!/usr/bin/env python3
"""Build the offline OCR fallback for macOS 15+, without Homebrew dylib dependencies."""
import hashlib, io, json, os, pathlib, shutil, subprocess, tarfile, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT/'native-runtimes/macos-arm64/ocr'
BUILD = ROOT/'native-runtimes/ocr-build'
PREFIX = BUILD/'prefix'
SOURCES = json.loads((ROOT/'scripts/ocr-sources.json').read_text())
MODELS = json.loads((ROOT/'scripts/ocr-models.json').read_text())

def download(item):
    data = urllib.request.urlopen(item['url'], timeout=120).read()
    if hashlib.sha256(data).hexdigest() != item['sha256']:
        raise ValueError('OCR dependency checksum mismatch: '+item['name'])
    return data

def prepare():
    OUT.mkdir(parents=True,exist_ok=True)
    model_dir = OUT/'tessdata';model_dir.mkdir(exist_ok=True)
    for item in MODELS:
        path = model_dir/(item['name']+'.traineddata')
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
            path.write_bytes(download(item))
    if (OUT/'tesseract').exists() and (OUT/'.verified').exists(): return
    BUILD.mkdir(parents=True,exist_ok=True)
    sdk = subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
    common = ['-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0','-DCMAKE_OSX_ARCHITECTURES=arm64',
              '-DBUILD_SHARED_LIBS=OFF','-DCMAKE_INSTALL_LIBDIR=lib','-DCMAKE_INSTALL_PREFIX='+str(PREFIX),
              '-DCMAKE_PREFIX_PATH='+str(PREFIX),'-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local',
              '-DZLIB_LIBRARY='+sdk+'/usr/lib/libz.tbd','-DZLIB_INCLUDE_DIR='+sdk+'/usr/include']
    options = {
        'libpng':['-DPNG_SHARED=OFF','-DPNG_STATIC=ON','-DPNG_FRAMEWORK=OFF','-DPNG_TESTS=OFF','-DPNG_TOOLS=OFF'],
        'leptonica':['-DBUILD_PROG=OFF','-DENABLE_GIF=OFF','-DENABLE_JPEG=OFF','-DENABLE_TIFF=OFF','-DENABLE_WEBP=OFF','-DENABLE_OPENJPEG=OFF',
                     '-DPNG_LIBRARY='+str(PREFIX/'lib/libpng16.a'),'-DPNG_PNG_INCLUDE_DIR='+str(PREFIX/'include')],
        'tesseract':['-DBUILD_TRAINING_TOOLS=OFF','-DBUILD_TESTS=OFF','-DGRAPHICS_DISABLED=ON','-DOPENMP_BUILD=OFF',
                     '-DDISABLE_CURL=ON','-DDISABLE_ARCHIVE=ON','-DDISABLE_TIFF=ON','-DENABLE_NATIVE=OFF','-DDISABLED_LEGACY_ENGINE=ON',
                     '-DLeptonica_DIR='+str(PREFIX/'lib/cmake/leptonica')]
    }
    env = dict(os.environ,PKG_CONFIG_LIBDIR=str(PREFIX/'lib/pkgconfig'))
    licenses = OUT/'licenses';licenses.mkdir(exist_ok=True)
    for name in ['libpng','leptonica','tesseract']:
        item = next(x for x in SOURCES if x['name']==name)
        folder = BUILD/name;folder.mkdir(exist_ok=True)
        if not list(folder.iterdir()):
            with tarfile.open(fileobj=io.BytesIO(download(item)),mode='r:*') as archive: archive.extractall(folder,filter='data')
        source = next(x for x in folder.iterdir() if x.is_dir())
        target = BUILD/('build-'+name)
        subprocess.run(['cmake','-S',str(source),'-B',str(target),*common,*options[name]],env=env,check=True)
        subprocess.run(['cmake','--build',str(target),'-j','4'],env=env,check=True)
        subprocess.run(['cmake','--install',str(target)],env=env,check=True)
        for file in source.iterdir():
            if file.is_file() and ('license' in file.name.lower() or file.name.lower().startswith('copying')):
                shutil.copy2(file,licenses/(name+'-'+file.name))
    executable = PREFIX/'bin/tesseract'
    dependencies = '\n'.join(subprocess.check_output(['otool','-L',str(executable)],text=True).splitlines()[1:])
    if '/opt/homebrew' in dependencies or str(BUILD) in dependencies:
        raise ValueError('OCR binary has nonportable dynamic dependencies')
    shutil.copy2(executable,OUT/'tesseract')
    shutil.copy2(ROOT/'shared/licenses/Tesseract-Apache-2.0.txt',licenses/'tessdata_best-Apache-2.0.txt')
    (OUT/'.verified').write_text(json.dumps({'sources':SOURCES,'models':MODELS,'minimumMacOS':'15.0'},indent=2))

if __name__=='__main__': prepare()
