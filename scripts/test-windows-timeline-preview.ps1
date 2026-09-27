param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
$script:checks=0
function Run($case) {
 $case.sampleRendering=$false
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(40)
 do {
  Start-Sleep -Milliseconds 100
  $done=$null
  try {$done=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 }until($done.name-eq $case.name)
 if(!$done.ok){throw $done.error}
 $m=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
 if($m.glassError){throw $m.glassError}
 if(!$m.state.native.foreground){throw 'Visual evidence requires the synthetic validation window in foreground'}
 Write-Host $case.name
 return $m
}
function ImageReady($m,[string]$id) {
 $p=$m.state.preview
 if(!$p.hasImage -or $p.loading -or $p.error -or $p.displayedId-ne $id){throw "Image did not settle to $id"}
 if($p.headerBounds.Y-lt 88 -or $p.headerBounds.Bottom-ge $p.frameBounds.Top){throw 'Preview toolbar overlaps search or image'}
 if($p.frameBounds.Bottom-gt 560){throw 'Preview overlaps the timeline'}
 if([math]::Abs($p.imageBounds.Width/$p.imageBounds.Height-$p.imageAspect)-gt .012){throw 'Image frame is not fitted to the image aspect'}
 $script:checks++
}
foreach($theme in @('light','dark')) {
 $m=Run @{name="timeline-final-$theme";page='home';rhine=$false;dark=($theme-eq 'dark');query='';timeline=$true;selected='parity-0-4';desktopScene=$true;settleMs=1500}
 ImageReady $m 'parity-0-4'
 foreach($shape in @('portrait','wide')) {
  $m=Run @{name="timeline-final-$theme-$shape";captureOnly=$true;action='frame';frameId="parity-$shape";settleMs=900}
  ImageReady $m "parity-$shape"
 }
 $ids=6..17|ForEach-Object {"parity-0-$_"}
 $m=Run @{name="timeline-final-$theme-burst";captureOnly=$true;settleMs=0;frameIds=$ids;frames=$ids.Count;frameIntervalMs=0;captureIntervalMs=32}
 if($m.previewStates.Count-ne $ids.Count -or @($m.previewStates|Where-Object {!$_.hasImage}).Count){throw 'A switching frame lost its decoded image'}
 $script:checks++
 $m=Run @{name="timeline-final-$theme-settled";captureOnly=$true;settleMs=1200}
 ImageReady $m 'parity-0-17'
 $m=Run @{name="timeline-final-$theme-failure";captureOnly=$true;action='frame';frameId='parity-broken-image';settleMs=1000}
 if(!$m.state.preview.hasImage -or !$m.state.preview.error -or $m.state.preview.displayedId-ne 'parity-0-17'){throw 'Invalid image did not keep previous pixels and report failure'}
 $script:checks++
 $m=Run @{name="timeline-final-$theme-recovered";captureOnly=$true;action='frame';frameId='parity-0-4';settleMs=900}
 ImageReady $m 'parity-0-4'
}
$null=Run @{name='timeline-final-interaction-ready';page='home';rhine=$false;dark=$false;query='';timeline=$true;selected='parity-0-4';desktopScene=$false;settleMs=1000}
@{passed=$true;checks=$script:checks;burstFrames=24;nativeGpuFpsMeasured=$false}|ConvertTo-Json|Set-Content (Join-Path $Directory 'timeline-preview-result.json')
Write-Host "PASS: $script:checks preview checks, light/dark, portrait/wide, 24 switching captures and failure recovery."
