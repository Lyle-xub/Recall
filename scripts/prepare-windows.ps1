$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
function Get-VerifiedAsset($asset, [string]$destination) {
    if ((Test-Path $destination) -and ((Get-FileHash $destination -Algorithm SHA256).Hash -eq $asset.sha256)) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
    $temporary = "$destination.download"
    Invoke-WebRequest -Uri $asset.url -OutFile $temporary
    if ((Get-FileHash $temporary -Algorithm SHA256).Hash -ne $asset.sha256) { Remove-Item $temporary; throw "Model checksum mismatch: $($asset.name)" }
    Move-Item -Force $temporary $destination
}
# The same pinned original-resolution recognition models as macOS; no runtime downloads for OCR.
$models = Get-Content "$PSScriptRoot/ocr-models.json" -Raw | ConvertFrom-Json
foreach ($model in $models) { Get-VerifiedAsset $model "$projectRoot/Windows/Rewind/tessdata/$($model.name).traineddata" }
$neural = Get-Content "$PSScriptRoot/neural-ocr/sources.json" -Raw | ConvertFrom-Json
foreach ($model in $neural | Where-Object { $_.name -like '*-small.onnx' }) {
    $name = $model.name.Replace('-small', '')
    Get-VerifiedAsset $model "$projectRoot/native-runtimes/windows-x64/neural-ocr/$name"
}
$licenses = "$projectRoot/native-runtimes/windows-x64/neural-ocr/licenses"
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item "$projectRoot/shared/licenses/Qwen3-Apache-2.0.txt" "$licenses/PP-OCRv6-Apache-2.0.txt" -Force
'PP-OCRv6 models: PaddlePaddle/PaddleOCR. ONNX conversion: RapidAI/RapidOCR v3.9.2. Preprocessing and postprocessing adapted from PaddleOCR/RapidOCR (Apache-2.0). ONNX Runtime (MIT), OpenCV/OpenCvSharp (Apache-2.0); package licenses are included in the release.' | Set-Content "$licenses/NOTICE.txt"
Copy-Item "$PSScriptRoot/neural-ocr/sources.json" "$projectRoot/native-runtimes/windows-x64/neural-ocr/sources.json" -Force
Write-Host 'Verified offline OCR models prepared.'
