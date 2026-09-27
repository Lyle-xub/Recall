param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
$checks=0
function Check($condition,$message){if(!$condition){throw $message};$script:checks++}
function Run($case){
 $completedPath=Join-Path $Directory 'completed.json'
 if(Test-Path -LiteralPath $completedPath){Remove-Item -LiteralPath $completedPath}
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(45)
 do {
  Start-Sleep -Milliseconds 150
  $done=$null
  try{$done=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 }until($done.name-eq $case.name)
 if(!$done.ok){throw $done.error}
 $m=Get-Content (Join-Path $Directory "$($case.name)/metrics.json") -Raw|ConvertFrom-Json
 Check (!$m.glassError) 'Glass material error'
 Write-Host $case.name
 return $m
}
foreach($tab in @('Recording','Permissions','Models','Storage','Shortcuts')){
 $m=Run @{name="settings-video-settings-$tab";page='settings';tab=$tab;rhine=$false;dark=$false;query='';settleMs=1100}
 Check ($m.state.mode-eq 'settings') "Settings page failed: $tab"
}
$null=Run @{name='settings-video-settings-dark';page='settings';tab='Recording';dark=$true;settleMs=1100}
$m=Run @{name='settings-video-detail-empty';page='detail';selected='parity-video-pixel90squeezed';dark=$false;rhine=$false;query='';settleMs=1500}
Check (!$m.state.media.transcriptVisible) 'Pending speech reserved a sidebar'
$working=Run @{name='settings-video-transcript-working';captureOnly=$true;action='transcript-working';settleMs=1600}
Check (!$working.state.media.transcriptVisible) 'Partial recognition exposed the sidebar'
$ready=Run @{name='settings-video-transcript-ready';captureOnly=$true;action='transcript-ready';settleMs=1600}
Check $ready.state.media.transcriptVisible 'Completed transcript did not open sidebar'
$empty=Run @{name='settings-video-transcript-empty';captureOnly=$true;action='transcript-empty';settleMs=1600}
Check (!$empty.state.media.transcriptVisible) 'Empty transcript kept sidebar space'
foreach($kind in @('zero','seek')){
 $null=Run @{name="settings-video-poster-$kind";page='detail';selected='parity-video-pixel90squeezed';dark=$false;settleMs=900}
 $burst=Run @{name="settings-video-first-frame-$kind";captureOnly=$true;action=$(if($kind-eq 'seek'){'play-video-seek'}else{'play-video'});settleMs=0;frames=20;captureIntervalMs=50}
 $visible=@($burst.mediaStates|Where-Object {$_.videoReady})
 Check ($visible.Count-gt 0) "No correctly oriented video frame appeared: $kind"
 foreach($state in $burst.mediaStates){
  if($state.videoReady){Check ($state.rotationDegrees-eq 270 -and $state.surface.ready -and $state.surface.settled) "Unaligned video frame was exposed: $kind"}
  else{Check $state.posterVisible "Poster disappeared before video was ready: $kind"}
 }
}
@{passed=$true;checks=$checks;scope='Targeted settings layouts, conditional transcript sidebar, zero/nonzero seek first-frame gate. Not the full regression suite.';capturedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $Directory 'settings-video-result.json')
Write-Host "PASS: $checks targeted settings/video checks."
