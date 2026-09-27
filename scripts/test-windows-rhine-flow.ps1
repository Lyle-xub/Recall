param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Run($case) {
 if(!$case.ContainsKey('sampleRendering')){$case.sampleRendering=$false}
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(50)
 do {
  Start-Sleep -Milliseconds 150
  $result=$null
  try {$result=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 }until($result.name-eq $case.name)
 if(!$result.ok){throw $result.error}
 Write-Host $case.name
 $metrics=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
 if(!$metrics.state.shown){throw 'Validation window was hidden during the motion run'}
 if(!$metrics.state.native.foreground){throw 'Recall must stay foreground for motion acceptance; background timings are not representative'}
 return $metrics
}
$null=Run @{name='flow-final-home';page='home';rhine=$true;dark=$false;day='2026-09-26';query='';settleMs=5000;capture=$false}
foreach($warmup in 1..60) {
 $warm=Run @{name="flow-warmup-$warmup";captureOnly=$true;settleMs=2000;capture=$false;sampleRendering=$false}
 if(!$warm.state.rhine.motionProfile.imagePumpRunning -and !$warm.state.rhine.ticking){break}
}
if($warm.state.rhine.motionProfile.imagePumpRunning){throw 'Images did not finish warmup'}
$null=Run @{name='flow-after-wave';captureOnly=$true;motionSamples=24;settleMs=2000;capture=$false;sampleRendering=$false}
$null=Run @{name='flow-wave-settled';captureOnly=$true;settleMs=5000;capture=$false;sampleRendering=$false}
foreach($i in 1..3) {
 $open=Run @{name="flow-open-$i";captureOnly=$true;action='open-first';settleMs=1000;capture=$false}
 if(!$open.state.rhine.expandedActionsVisible -or $open.state.rhine.extraction -ne 1){throw 'Card did not finish opening'}
 $close=Run @{name="flow-close-$i";captureOnly=$true;action='collapse';settleMs=1000;capture=$false}
 if($close.state.rhine.extracted -or $close.state.rhine.expandedActionsVisible -or $close.state.rhine.extraction -ne 0 -or $close.state.rhine.motionProfile.lastTransitionMs -gt 950 -or $close.state.rhine.motionProfile.imageRequests -ne 0){throw 'Card return stalled or queued image work'}
 if($close.state.rhine.motionProfile.transitionMaxIntervalMs -gt 150 -or $close.state.rhine.motionProfile.transitionFrames -lt 12){throw 'Card return completed but had a visible scheduling stall'}
}
$null=Run @{name='flow-interrupt-open';captureOnly=$true;action='open-first';settleMs=120;capture=$false}
$close=Run @{name='flow-interrupt-return';captureOnly=$true;action='collapse';settleMs=1000;capture=$false}
if($close.state.rhine.extracted){throw 'Reversed transition did not return'}
$null=Run @{name='flow-reduced-home';page='home';rhine=$true;dark=$true;reducedMotion=$true;settleMs=3000;capture=$false}
$null=Run @{name='flow-reduced-open';captureOnly=$true;action='open-first';settleMs=200;capture=$false}
$close=Run @{name='flow-reduced-close';captureOnly=$true;action='collapse';settleMs=200;capture=$false}
if($close.state.rhine.extracted -or $close.state.rhine.ticking){throw 'Reduced motion did not settle'}
$null=Run @{name='flow-restored';page='home';rhine=$true;dark=$false;day='2026-09-26';query='';reducedMotion=$false;settleMs=5000;capture=$false}
$null=Run @{name='flow-after-wave-warm';captureOnly=$true;motionSamples=24;settleMs=3000;capture=$false;sampleRendering=$false}
$idle=Run @{name='flow-idle';captureOnly=$true;settleMs=1500;measureSeconds=8;capture=$false;sampleRendering=$false}
if($idle.state.rhine.ticking -or $idle.state.rhine.motionProfile.imagePumpRunning){throw 'Idle scene kept rendering or loading'}
Write-Host "PASS: Rhine transitions and idle checks. Idle CPU: $($idle.cpuPercentOfOneCore)% of one core."
