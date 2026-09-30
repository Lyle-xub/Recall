param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Probe([hashtable]$case) {
    $case.capture = $false
    $case.sampleRendering = $false
    Write-RecallValidationCommand -Directory $Directory -Command $case
    $deadline = (Get-Date).AddSeconds(50)
    do {
        Start-Sleep -Milliseconds 100
        $result = $null
        try { $result = Get-Content (Join-Path $Directory 'completed.json') -Raw | ConvertFrom-Json } catch {}
        if ((Get-Date) -gt $deadline) { throw "Timed out: $($case.name)" }
    } until ($result.name -eq $case.name)
    if (!$result.ok) { throw $result.error }
    return Get-Content (Join-Path $Directory ($case.name + '/metrics.json')) -Raw | ConvertFrom-Json
}
$initial = Probe @{ name='startup-initial-rack'; page='home'; rhine=$true; dark=$false; day='2026-09-26'; settleMs=3000 }
for ($attempt=0; $attempt -lt 30; $attempt++) {
    $ready = Probe @{ name="startup-ready-$attempt"; captureOnly=$true; settleMs=1000 }
    if (!$ready.state.rhine.ticking -and !$ready.state.rhine.motionProfile.imagePumpRunning -and
        $ready.state.imageCache.inFlight -eq 0) { break }
}
if ($ready.state.rhine.ticking -or $ready.state.rhine.motionProfile.imagePumpRunning -or
    $ready.state.imageCache.inFlight -ne 0) { throw 'The initial rack did not finish warming up.' }
if (!$ready.state.rhine.loadedImages) { throw 'The initial rack has no loaded pictures.' }
$queries = $ready.state.rhine.startup.queryCount
$builds = $ready.state.rhine.startup.builds
$images = $ready.state.rhine.loadedImages
$samples = @()
foreach ($attempt in 1..5) {
    $reopen = Probe @{ name="startup-reopen-$attempt"; captureOnly=$true; action='hide-show'; settleMs=50 }
    if (!$reopen.state.shown -or !$reopen.state.rhine.active) { throw 'Reopen did not activate the rack.' }
    if ($reopen.state.motion.toolbarAnimating -or
        @($reopen.state.buttons | Where-Object { $_.opacity -ne 1 }).Count -ne 0) {
        throw 'Reopen left the toolbar waiting on an entrance animation.'
    }
    if ($reopen.state.rhine.startup.queryCount -ne $queries -or $reopen.state.rhine.startup.builds -ne $builds) {
        throw 'An unchanged reopen queried or rebuilt the archive.'
    }
    if ($reopen.state.rhine.loadedImages -lt $images) { throw 'Reopen discarded decoded pictures.' }
    $samples += [double]$reopen.state.uiThread.lastShowMs
}
$report = [ordered]@{
    coldFirstRackMs = $initial.state.rhine.startup.coldFirstRackMs
    firstImageAfterBuildMs = $initial.state.rhine.startup.firstImageMs
    reopenCallMs = $samples
    medianReopenCallMs = ($samples | Sort-Object)[2]
    additionalQueries = $reopen.state.rhine.startup.queryCount - $queries
    additionalBuilds = $reopen.state.rhine.startup.builds - $builds
    retainedImages = $reopen.state.rhine.loadedImages
    foreground = $reopen.state.native.foreground
    note = 'Show() call duration, not process cold start, GPU presentation, or a visual zero-latency guarantee. Command polling is excluded.'
}
$report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Directory 'rhine-startup-report.json') -Encoding utf8
$report | ConvertTo-Json -Depth 6
Write-Host 'PASS: five warm reopens retain the rack and images without additional queries or builds.'
