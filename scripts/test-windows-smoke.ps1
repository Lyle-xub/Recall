param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = Join-Path $projectRoot 'release/windows-smoke'
New-Item -ItemType Directory -Force $output | Out-Null
$process = Start-Process -FilePath $Executable -ArgumentList @('--smoke-test', "`"$output`"") -PassThru
if (-not $process.WaitForExit(180000)) { $process.Kill(); throw 'Windows native smoke test timed out.' }
if ($process.ExitCode -ne 0) { throw "Windows native smoke test failed. Read $output/smoke.json" }
$result = Get-Content (Join-Path $output 'smoke.json') -Raw | ConvertFrom-Json
if (-not $result.passed) { throw 'Windows native smoke checks failed.' }
Write-Host 'Windows native startup, layouts, OCR, search, tile archive and capture checks passed.'
