param([switch]$SkipSmoke)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $IsWindows -and $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Release packaging requires Windows (manifest and PRI generation use Windows SDK tools).' }
& "$PSScriptRoot/prepare-windows.ps1"
python "$PSScriptRoot/prepare-native-runtimes.py"
if ($LASTEXITCODE -ne 0) { throw 'Native inference engine preparation failed.' }
dotnet run --project "$projectRoot/Windows/Rewind.Tests/Rewind.Tests.csproj" -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core regression checks failed.' }
$output = "$projectRoot/release/recall-windows-x64"
dotnet publish "$projectRoot/Windows/Recall.WinUI/Recall.WinUI.csproj" -c Release -r win-x64 --self-contained true -p:Platform=x64 -o $output
if ($LASTEXITCODE -ne 0) { throw 'WinUI release build failed.' }
foreach ($required in @('Recall.exe','resources.pri','Assets/Recall.ico','Assets/Opening.wav','runtimes/neural-ocr/det.onnx','runtimes/neural-ocr/rec.onnx','runtimes/llama/llama-server.exe','runtimes/whisper/whisper-cli.exe','tessdata/eng.traineddata','tessdata/chi_sim.traineddata')) {
    if (-not (Test-Path (Join-Path $output $required))) { throw "Missing release asset: $required" }
}
$licenseDestination = Join-Path $output 'licenses/NuGet'
New-Item -ItemType Directory -Force -Path $licenseDestination | Out-Null
$packageCache = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget/packages' }
foreach ($package in @('microsoft.ml.onnxruntime','opencvsharp4','opencvsharp4.runtime.win','microsoft.windowsappsdk','microsoft.windowsappsdk.winui','microsoft.windowsappsdk.runtime','microsoft.graphics.win2d','tesseract','naudio','screenrecorderlib')) {
    Get-ChildItem (Join-Path $packageCache $package) -Recurse -File | Where-Object { $_.Name -match 'license|notice|copying' } | ForEach-Object { Copy-Item $_.FullName (Join-Path $licenseDestination "$package-$($_.Directory.Name)-$($_.Name)") -Force }
}
if (-not $SkipSmoke) { & "$PSScriptRoot/test-windows-smoke.ps1" -Executable "$output/Recall.exe" }
Compress-Archive -Force -Path "$output/*" -DestinationPath "$projectRoot/release/Recall-Windows-x64.zip"
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $candidate = "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe"; if (Test-Path $candidate) { $iscc = $candidate } }
if ($iscc) { & $iscc "$projectRoot/Windows/Installer/Recall.iss"; if ($LASTEXITCODE -ne 0) { throw 'Installer build failed.' } }
else { Write-Warning 'Inno Setup 6 was not found. The portable ZIP is ready; install Inno Setup to also create Setup.exe.' }
Get-FileHash "$projectRoot/release/Recall-Windows-x64.zip" -Algorithm SHA256 | Format-List
