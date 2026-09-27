param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Run($case) {
 $case.capture=$false; $case.sampleRendering=$false
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(40)
 do {
  Start-Sleep -Milliseconds 150
  $done=$null
  try {$done=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 }until($done.name-eq $case.name)
 if(!$done.ok){throw $done.error}
 $metrics=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
 if($metrics.glassError){throw $metrics.glassError}
 Write-Host $case.name
 return $metrics.state.timeline
}
$start=Run @{name='cohesion-range-start';page='home';rhine=$false;dark=$false;timeline=$true;settleMs=1200}
if($start.spanSeconds-ne 1800 -or $start.rangeText-ne '30 min'){throw 'Selected timeline range label is stale'}
[double]$expected=1800
foreach($i in 1..8) {
 $expected=[Math]::Min(86400.0,$expected*2)
 $r=Run @{name="cohesion-range-out-$i";captureOnly=$true;action='timeline-zoom-out';settleMs=100}
 if($r.spanSeconds-ne $expected -or $r.zoomOutEnabled-ne ($expected-lt 86400)){throw 'Zoom-out span or boundary is wrong'}
}
if($r.rangeText-ne '24 hr'){throw 'Maximum range label is stale'}
foreach($i in 1..12) {
 $expected=[Math]::Max(60.0,$expected*.5)
 $r=Run @{name="cohesion-range-in-$i";captureOnly=$true;action='timeline-zoom-in';settleMs=100}
 if($r.spanSeconds-ne $expected -or $r.zoomInEnabled-ne ($expected-gt 60)){throw 'Zoom-in span or boundary is wrong'}
}
if($r.rangeText-ne '1 min'){throw 'Minimum range label is stale'}
Write-Host 'PASS: 21 range cases; actual span, synchronous endpoint labels and zoom boundaries.'
