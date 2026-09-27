param([Parameter(Mandatory)][string]$Directory, [switch]$CaptureExcluded)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Run($case) {
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(50)
 do {
  Start-Sleep -Milliseconds 150
  $done=$null
  try {$done=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 } until($done.name-eq $case.name)
 if(!$done.ok){throw $done.error}
 Write-Host $case.name
 return (Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json).state
}
$affinity=if($CaptureExcluded){17}else{0}
foreach($rhine in @($false,$true)) {
 foreach($page in @('settings','search','detail','ask','usage')) {
  $prefix="nav-$affinity-$rhine-$page"
  $before=Run @{name="$prefix-before";page=$page;rhine=$rhine;dark=$false;query='';selected='parity-0-4';settleMs=1200;capture=$false;sampleRendering=$false}
  if(!$before.shown -or !$before.backdrop.full -or $before.native.captureAffinity-ne $affinity){throw 'Page setup or capture affinity differs from requested case'}
  $after=Run @{name="$prefix-back";captureOnly=$true;action='back';settleMs=1500;capture=$false;sampleRendering=$false}
  if($after.mode-ne 'home' -or !$after.shown -or !$after.native.windowVisible -or !$after.backdrop.attached -or !$after.backdrop.targetConnected -or $after.backdrop.full-ne $rhine -or $after.media){throw 'Back left a page, media surface, or incorrect backdrop mode'}
  $hidden=Run @{name="$prefix-hidden";captureOnly=$true;action='hide';settleMs=600;capture=$false;sampleRendering=$false}
  if($hidden.shown -or $hidden.native.windowVisible -or $hidden.native.hostBackdropEnabled -or $hidden.native.hostBackdropResult-ne 0 -or $hidden.backdrop.attached -or $hidden.backdrop.targetConnected -or $hidden.rhine.ticking){throw 'Dismissal retained window, backdrop, or animation'}
 }
}
Write-Host "PASS: 10 return paths and 10 dismissals, capture affinity $affinity. Native Back/Escape input needs separate UI acceptance."
