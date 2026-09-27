param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$Cli)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = Join-Path $projectRoot 'release/windows-cli-archive'
if (Test-Path $output) { throw "Use a fresh validation directory: $output" }
New-Item -ItemType Directory $output | Out-Null
$library = Join-Path $output 'library'
$oldNativeApp = $env:RECALL_WINDOWS_APP
$env:RECALL_WINDOWS_APP = (Resolve-Path $Executable).Path
$checks = 0
$process = $null
$passed = $false
$failure = $null
function Check([bool]$condition, [string]$label) {
    if (!$condition) { throw $label }
    $script:checks++
}
function Recall([string[]]$Words) {
    $json = & $Cli --data-dir $library --json @Words
    if ($LASTEXITCODE -ne 0) { throw "CLI failed: $($Words -join ' '): $json" }
    $response = $json | ConvertFrom-Json
    if (!$response.ok) { throw "CLI returned an error: $json" }
    return $response.result
}
try {
    $null = Recall @('library', 'init', '--format', 'windows')
    $null = Recall @('config', 'set', 'capture-interval', '1')
    $start = Recall @('recording', 'start')
    Check ($start.active -and $start.owner -eq 'desktop') 'CLI must automatically start the native Windows owner and record with its engine.'
    $receipt = Get-Content (Join-Path $library '.recall-control/owner.json') -Raw | ConvertFrom-Json
    Check ($receipt.backend -eq 'windows') 'Native recording cannot silently fall back to portable screenshots.'
    $process = Get-Process -Id $receipt.pid
    Start-Sleep -Milliseconds 3500
    $stop = Recall @('recording', 'stop')
    Check (!$stop.active -and !$stop.requested) 'CLI stop must finalize the same native recording.'
    $session = @(Recall @('sessions', 'list')) | Sort-Object startedAt -Descending | Select-Object -First 1
    Check ($session.unifiedVisualArchive -and $session.visualArchiveReady -and $session.endedAt) 'CLI session metadata must report a finalized unified archive.'
    Check ($session.videoCodec -in @('hevc', 'h264')) 'CLI must report the actual supported codec.'
    $deadline = (Get-Date).AddSeconds(65)
    do {
        $frames = @(Recall @('records', 'list', '--limit', '100'))
        $card = $frames | Where-Object { $_.sessionId -eq $session.id -and $_.imagePath.EndsWith('.recallvideo') } | Select-Object -First 1
        if ($card) { break }
        if ($process.HasExited) { throw 'Native owner exited while indexing.' }
        Start-Sleep -Milliseconds 300
    } until ((Get-Date) -ge $deadline)
    Check ($null -ne $card) 'Native capture must finish OCR and expose a video-backed card through the CLI.'
    $manifest = Get-Content (Join-Path $library $card.imagePath) -Raw | ConvertFrom-Json
    Check ($manifest.Video -eq $session.videoPath -and $manifest.Ticks -eq $card.visualTicks) 'CLI card reference must match its exact submitted sample.'
    Check (!(Test-Path (Join-Path $library "frames/$($card.id).ocr.png"))) 'The card no longer retains a redundant OCR source after validation.'
    $index = Recall @('index', 'run', '--id', $card.id)
    Check ($index.state -eq 'completed' -and $index.completed -eq 1) 'CLI OCR retry must materialize the native video frame.'
    $export = Join-Path $output 'export'
    $null = Recall @('records', 'export', '--output', $export, '--limit', '100')
    Check ((Test-Path (Join-Path $export $card.imagePath)) -and (Test-Path (Join-Path $export $manifest.Video))) 'CLI export must include the visual reference and its recording dependency.'
    $video = Join-Path $library $session.videoPath
    $before = (Get-FileHash $video -Algorithm SHA256).Hash
    $null = Recall @('storage', 'optimize')
    Start-Sleep -Milliseconds 500
    $deadline = (Get-Date).AddSeconds(60)
    do {
        $tasks = Recall @('tasks', 'status')
        if (!$tasks.desktop.optimizing) { break }
        Start-Sleep -Milliseconds 300
    } until ((Get-Date) -ge $deadline)
    Check (!$tasks.desktop.optimizing -and !$tasks.desktop.error) 'Native maintenance must finish successfully through CLI ownership.'
    Check ((Get-FileHash $video -Algorithm SHA256).Hash -eq $before) 'Maintenance must not reencode the only video pixels backing a card.'
    $inventory = Recall @('storage', 'stats')
    Check ($inventory.buckets.video -ge (Get-Item $video).Length) 'Storage stats account for the shared recording once as physical video bytes.'
    $null = Recall @('service', 'stop')
    Check ($process.WaitForExit(30000)) 'A CLI-launched native owner must shut down gracefully.'
    Check (!(Test-Path (Join-Path $library '.recall-control/owner.json'))) 'Graceful shutdown releases the library owner receipt.'
    Check ((Recall @('storage', 'check')).integrity -eq 'ok') 'CLI can reopen the finalized library after native shutdown.'
    $passed = $true
}
catch { $failure = $_.ToString(); throw }
finally {
    try {
        if (!$process -and (Test-Path (Join-Path $library '.recall-control/owner.json'))) {
            $receipt = Get-Content (Join-Path $library '.recall-control/owner.json') -Raw | ConvertFrom-Json
            $process = Get-Process -Id $receipt.pid -ErrorAction SilentlyContinue
        }
        if ($process -and !$process.HasExited) {
            $null = Recall @('service', 'stop')
            if (!$process.WaitForExit(30000)) {
                $process.Kill(); $process.WaitForExit()
                throw 'Native service did not drain and exit; forced cleanup is a test failure.'
            }
        }
    }
    finally {
        $env:RECALL_WINDOWS_APP = $oldNativeApp
        @{passed=$passed;checks=$checks;backend='native';actualScreenCapture=$true;error=$failure} | ConvertTo-Json | Set-Content (Join-Path $output 'acceptance.json')
    }
}
Write-Host "PASS: $checks real CLI/native unified archive checks."
