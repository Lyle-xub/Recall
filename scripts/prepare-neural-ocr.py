#!/usr/bin/env python3
"""Build the offline PP-OCRv6 worker. Python/CMake are build tools, not app dependencies."""
import hashlib, json, os, pathlib, shutil, subprocess, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT/'native-runtimes/macos-arm64/neural-ocr'
CACHE = ROOT/'.test-data/ocr-v6-assets'
SOURCES = json.loads((ROOT/'scripts/neural-ocr/sources.json').read_text())

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def obtain(item):
    path = CACHE/item['name']
    if not path.exists() or sha(path) != item['sha256']:
        part = path.with_suffix('.download')
        with urllib.request.urlopen(item['url'],timeout=120) as response,part.open('wb') as output: shutil.copyfileobj(response,output)
        if sha(part) != item['sha256']: raise ValueError('Dependency hash mismatch: '+item['name'])
        part.replace(path)
    return path

def prepare():
    CACHE.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True)
    marker = hashlib.sha256((ROOT/'scripts/neural-ocr/main.mm').read_bytes()+(ROOT/'scripts/neural-ocr/sources.json').read_bytes()+pathlib.Path(__file__).read_bytes()).hexdigest()
    if (OUT/'.verified').exists() and (OUT/'.verified').read_text() == marker and (OUT/'recall-ocr').exists() and (OUT/'libonnxruntime.1.dylib').exists():
        if all(sha(OUT/name) == next(x['sha256'] for x in SOURCES if x['name']==source) for name,source in [('det.onnx','det-small.onnx'),('rec.onnx','rec-small.onnx')]): return
    sources = {x['name']:obtain(x) for x in SOURCES}
    ort = CACHE/'onnxruntime-osx-arm64-1.30.0';cv = CACHE/'opencv-4.12.0';prefix = CACHE/'opencv-install'
    for archive,target in [(sources['ort.tgz'],ort),(sources['opencv.tar.gz'],cv)]:
        if not target.exists():
            with tarfile.open(archive) as file: file.extractall(CACHE,filter='data')
    if not (prefix/'lib/libopencv_imgproc.a').exists():
        build = CACHE/'opencv-build'
        options = ['-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0','-DCMAKE_OSX_ARCHITECTURES=arm64',
                   '-DBUILD_LIST=core,imgproc','-DBUILD_SHARED_LIBS=OFF','-DBUILD_TESTS=OFF','-DBUILD_PERF_TESTS=OFF','-DBUILD_EXAMPLES=OFF',
                   '-DBUILD_opencv_apps=OFF','-DBUILD_JAVA=OFF','-DBUILD_opencv_python3=OFF','-DWITH_IPP=OFF','-DWITH_OPENCL=OFF',
                   '-DWITH_LAPACK=OFF','-DWITH_ITT=OFF','-DWITH_FFMPEG=OFF','-DWITH_AVFOUNDATION=OFF','-DBUILD_ZLIB=ON',
                   '-DCMAKE_INSTALL_PREFIX='+str(prefix)]
        subprocess.run(['cmake','-S',str(cv),'-B',str(build),*options],check=True)
        subprocess.run(['cmake','--build',str(build),'-j','4'],check=True);subprocess.run(['cmake','--install',str(build)],check=True)
    shutil.copy2(sources['det-small.onnx'],OUT/'det.onnx');shutil.copy2(sources['rec-small.onnx'],OUT/'rec.onnx')
    shutil.copy2(ort/'lib/libonnxruntime.1.30.0.dylib',OUT/'libonnxruntime.1.30.0.dylib')
    for name in ['libonnxruntime.dylib','libonnxruntime.1.dylib']:
        link = OUT/name
        if link.exists() or link.is_symlink(): link.unlink()
        link.symlink_to('libonnxruntime.1.30.0.dylib')
    subprocess.run(['clang++','-std=c++17','-O3','-fobjc-arc','-mmacosx-version-min=15.0',str(ROOT/'scripts/neural-ocr/main.mm'),
                    '-I'+str(ort/'include'),'-I'+str(prefix/'include/opencv4'),'-L'+str(OUT),'-lonnxruntime',
                    str(prefix/'lib/libopencv_imgproc.a'),str(prefix/'lib/libopencv_core.a'),str(prefix/'lib/opencv4/3rdparty/libtegra_hal.a'),
                    '-framework','Foundation','-framework','CoreGraphics','-framework','ImageIO','-framework','Accelerate','-lz',
                    '-Wl,-rpath,@executable_path','-o',str(OUT/'recall-ocr')],check=True)
    for file in [OUT/'recall-ocr',OUT/'libonnxruntime.1.30.0.dylib']:
        dependencies = '\n'.join(subprocess.check_output(['otool','-L',str(file)],text=True).splitlines()[1:])
        if '/opt/homebrew/' in dependencies or str(CACHE) in dependencies: raise ValueError('Nonportable native dependency')
    licenses = OUT/'licenses';licenses.mkdir(exist_ok=True)
    for source,name in [(ort/'LICENSE','ONNXRuntime-LICENSE'),(ort/'ThirdPartyNotices.txt','ONNXRuntime-ThirdPartyNotices.txt'),(cv/'LICENSE','OpenCV-LICENSE'),(ROOT/'shared/licenses/Qwen3-Apache-2.0.txt','PP-OCRv6-Apache-2.0.txt')]:
        if not source.exists(): raise FileNotFoundError(source)
        shutil.copy2(source,licenses/name)
    (licenses/'NOTICE.md').write_text('Recall local OCR uses PP-OCRv6 Small (PaddlePaddle/PaddleOCR), ONNX models converted by RapidAI/RapidOCR v3.9.2, and pre/post-processing adapted from PaddleOCR/RapidOCR (Apache-2.0). Inference uses Microsoft ONNX Runtime (MIT) and OpenCV 4.12 (Apache-2.0). OpenCV includes NVIDIA Carotene/Tegra HAL; its BSD notice is included.\n')
    (licenses/'Carotene-LICENSE').write_text((cv/'hal/carotene/src/common.cpp').read_text().split('*/',1)[0]+'*/\n')
    shutil.copy2(ROOT/'scripts/neural-ocr/sources.json',OUT/'sources.json')
    (OUT/'.verified').write_text(marker)
if __name__ == '__main__': prepare()
