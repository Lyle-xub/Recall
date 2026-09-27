param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$Cli)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = Join-Path $projectRoot 'release/windows-integration'
if (Test-Path $output) { throw "Use a fresh validation directory: $output" }
python "$PSScriptRoot/prepare-windows-rhine-fixtures.py" "$projectRoot/docs/macos-visual-reference/fixtures" $output
if ($LASTEXITCODE -ne 0) { throw 'Synthetic fixture preparation failed.' }
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
$process = Start-Process -FilePath $Executable -ArgumentList @('--visual-parity', "`"$output`"", '--validation-fake-capture') -PassThru
$checks = 0
function Check([bool]$condition, [string]$label) {
    if (!$condition) { throw $label }
    $script:checks++
}
function Action([string]$action) {
    $name = 'ipc-' + [Guid]::NewGuid().ToString('N')
    Write-RecallValidationCommand -Directory $output -Command @{name=$name;action=$action;captureOnly=$true;capture=$false;sampleRendering=$false;settleMs=600}
    $deadline = (Get-Date).AddSeconds(40)
    do {
        if ($process.HasExited) { throw 'Validation app exited during a native action.' }
        Start-Sleep -Milliseconds 100
        $done = $null
        try { $done = Get-Content (Join-Path $output 'completed.json') -Raw | ConvertFrom-Json } catch {}
        if ((Get-Date) -gt $deadline) { throw "Native action timed out: $action" }
    } until ($done.name -eq $name)
    if (!$done.ok) { throw $done.error }
}
function Recording([string]$command, [bool]$success = $true) {
    $json = & $Cli --data-dir (Join-Path $output 'library') recording $command --json
    $exitCode = $LASTEXITCODE
    $response = $json | ConvertFrom-Json
    if ($success -and ($exitCode -ne 0 -or !$response.ok)) { throw "CLI $command failed: $json" }
    if (!$success -and ($exitCode -eq 0 -or $response.ok)) { throw "CLI $command falsely reported success: $json" }
    return $response
}
try {
    $deadline = (Get-Date).AddSeconds(90)
    while (!(Test-Path (Join-Path $output 'environment.json'))) {
        if ($process.HasExited) { throw "Validation startup failed. Read $output/startup.log" }
        if ((Get-Date) -gt $deadline) { throw 'Validation window did not become ready.' }
        Start-Sleep -Milliseconds 200
    }
    & "$PSScriptRoot/test-windows-recording-resume.ps1" -Directory $output
    & "$PSScriptRoot/test-windows-navigation.ps1" -Directory $output
    & "$PSScriptRoot/test-windows-dismiss.ps1" -Directory $output

    Action 'show'
    $paused = (Recording 'start').result
    Check ($paused.owner -eq 'desktop' -and $paused.requested -and !$paused.active -and $paused.automaticallyPaused) 'CLI and the shown desktop must share one automatically paused recording request.'
    $null = Recording 'stop'
    Action 'hide'
    Action 'recording-fail-next'
    $failed = Recording 'start' $false
    Check ($failed.error.code -eq 'capture_failed') 'A native runtime start failure must be a CLI capture_failed error.'
    $fault = (Recording 'status').result
    Check ($fault.requested -and !$fault.active -and $fault.captureFaulted -and !$fault.automaticallyPaused -and $fault.error) 'Failed capture must retain intent and expose its fault through the desktop IPC owner.'
    $retry = (Recording 'start').result
    Check ($retry.active -and !$retry.captureFaulted) 'Explicit CLI retry must recover the same native runtime.'
    $stopped = (Recording 'stop').result
    Check (!$stopped.active -and !$stopped.requested -and !$stopped.captureFaulted) 'Explicit CLI stop must stop the same native runtime.'
    @{passed=$true;ipcChecks=$checks;backend='fake';nativeCaptureVerified=$false} | ConvertTo-Json | Set-Content (Join-Path $output 'merged-integration.json')
    Write-Host "PASS: $checks real CLI/native desktop IPC checks plus recording, navigation and dismissal regressions."
}
finally {
    if (!$process.HasExited) {
        Write-RecallValidationCommand -Directory $output -Command @{name='integration-quit';action='quit'}
        if (!$process.WaitForExit(15000)) {
            $process.Kill(); $process.WaitForExit()
            throw 'Native shutdown timed out; ownership/diagnostic drain was not verified.'
        }
        if ($process.ExitCode -ne 0) { throw "Native validation exited with code $($process.ExitCode)." }
        if (Test-Path (Join-Path $output 'library/.recall-control/owner.json')) { throw 'Native shutdown retained its CLI owner receipt.' }
    }
}
