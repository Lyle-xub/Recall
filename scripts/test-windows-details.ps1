param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Run($case) {
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(45)
 do {
  Start-Sleep -Milliseconds 150
  $result=$null
  try {$result=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 }until($result.name-eq $case.name)
 if(!$result.ok){throw $result.error}
 $m=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
 if($m.glassError){throw $m.glassError}
 Write-Host $case.name
 return $m
}
foreach($dark in @($false,$true)) {
 foreach($tab in @('Recording','Permissions','Models','Storage','Shortcuts')) {
  $null=Run @{name="detail-settings-$tab-$dark";page='settings';tab=$tab;dark=$dark;rhine=$true;query='';settleMs=1200}
 }
}
$normal=Run @{name='detail-video-normal';page='detail';selected='parity-0-0';action='play-video';dark=$false;settleMs=3000}
if(!$normal.state.media.playing -or $normal.state.media.playbackError -or $normal.state.media.rotationDegrees-ne 0){throw 'Normal video failed'}
foreach($step in 1..4) {
 $rotated=Run @{name="detail-video-manual-$step";captureOnly=$true;action='rotate-video';settleMs=400}
 if($rotated.state.media.rotationDegrees-ne (($step%4)*90)){throw 'Manual rotation failed'}
}
$null=Run @{name='detail-video-replay';page='detail';selected='parity-0-0';action='play-video';settleMs=2400}
$hidden=Run @{name='detail-video-hidden';captureOnly=$true;action='hide';settleMs=800}
if($hidden.state.shown -or $hidden.state.native.windowVisible -or $hidden.state.backdrop.attached -or $hidden.state.media.hasPlayer){throw 'Video/backdrop retained after hide'}
$null=Run @{name='detail-video-reopen';captureOnly=$true;action='show';settleMs=1400}
$rotated=Run @{name='detail-video-auto-corrected';page='detail';selected='parity-0-1';action='play-video';settleMs=3000}
if(!$rotated.state.media.playing -or $rotated.state.media.playbackError -or $rotated.state.media.orientationCorrectionDegrees-ne 270){throw 'Quarter-turn metadata did not align with recorded still'}
$failed=Run @{name='detail-video-failed';page='detail';selected='parity-0-2';action='play-video';settleMs=2800}
if(!$failed.state.media.playbackError -or $failed.state.media.hasPlayer -or $failed.state.media.hasVideoElement){throw 'Broken video did not release its surface and show fallback'}
$recovered=Run @{name='detail-video-recovered';page='detail';selected='parity-0-0';action='play-video';settleMs=2600}
if(!$recovered.state.media.playing -or $recovered.state.media.playbackError){throw 'Playback did not recover after bad media'}
$homeState=Run @{name='detail-video-left';page='home';rhine=$true;dark=$false;query='';day='2026-09-26';settleMs=1500}
if($homeState.state.media){throw 'Detail view retained after navigation'}
