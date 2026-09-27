param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
$script:checks=0
$script:prefix='recording-resume-'+(Get-Date -Format 'HHmmss')
function Run([string]$name,[string]$action) {
 $case=@{name="$script:prefix-$name";captureOnly=$true;capture=$false;sampleRendering=$false;settleMs=800}
 if($action){$case.action=$action}
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(40)
 do {
  Start-Sleep -Milliseconds 100
  $done=$null
  try {$done=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $name"}
 }until($done.name-eq $case.name)
 if(!$done.ok){throw $done.error}
 $r=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
 if(!$r.state.recording.fake.enabled){throw 'Launch with --visual-parity and --validation-fake-capture. This test never records the desktop.'}
 return $r.state
}
function Check($state,[bool]$requested,[bool]$visible,[bool]$active,[bool]$faulted,[string]$label) {
 $r=$state.recording.state
 if($r.Requested-ne $requested -or $r.InterfaceVisible-ne $visible -or $r.Active-ne $active -or $r.CaptureFaulted-ne $faulted -or $r.Transitioning){throw "Unexpected recording state ($label): $($r|ConvertTo-Json -Compress)"}
 if([bool]$state.recording.fake.active-ne $active){throw "Capture backend disagrees ($label)"}
 if($state.native.trayStatus-ne "Recall · $label"){throw "Wrong actual tray text: $($state.native.trayStatus)"}
 $script:checks++
}
try {
 $null=Run 'show' 'show'
 $null=Run 'reset' 'recording-off'
 Check (Run 'requested-visible' 'recording-on') $true $true $false $false 'Paused while open'
 Check (Run 'hide-resumes' 'hide') $true $false $true $false 'Recording'
 Check (Run 'reopen-pauses' 'show') $true $true $false $false 'Paused while open'
 Check (Run 'quick-hide-show' 'hide-show') $true $true $false $false 'Paused while open'
 Check (Run 'hide-again' 'hide') $true $false $true $false 'Recording'
 Check (Run 'manual-stop' 'recording-off') $false $false $false $false 'Not recording'
 $null=Run 'stopped-show' 'show'
 Check (Run 'stopped-hide' 'hide') $false $false $false $false 'Not recording'
 $null=Run 'fault-show' 'show'
 $null=Run 'fault-intent' 'recording-on'
 $null=Run 'arm-failure' 'recording-fail-next'
 $fault=Run 'startup-failure' 'hide'
 Check $fault $true $false $false $true 'Recording interrupted'
 if($fault.native.recordingAction-ne 'Retry recording'){throw 'Tray does not offer retry'}
 $settings=Get-Content (Join-Path $Directory 'library/settings.json') -Raw|ConvertFrom-Json
 if(!$settings.RecordingRequested){throw 'Temporary failure persisted a manual recording stop'}
 $null=Run 'fault-reopen' 'show'
 Check (Run 'fault-hide-retries' 'hide') $true $false $true $false 'Recording'
 Check (Run 'capture-interruption' 'recording-interrupt') $true $false $false $true 'Recording interrupted'
 Check (Run 'explicit-retry' 'recording-on') $true $false $true $false 'Recording'
 Check (Run 'finish-stop' 'recording-off') $false $false $false $false 'Not recording'
 Write-Host "PASS: $script:checks recording/window/tray checks with fake capture; no desktop or audio recording."
 @{passed=$true;checks=$script:checks;prefix=$script:prefix;backend='fake';nativeCaptureVerified=$false}|ConvertTo-Json|Set-Content (Join-Path $Directory 'recording-resume-result.json')
}
finally {
 $null=Run 'cleanup-off' 'recording-off'
 $null=Run 'cleanup-show' 'show'
}
