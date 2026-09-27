param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Run($case) {
  Write-RecallValidationCommand -Directory $Directory -Command $case
  $deadline=(Get-Date).AddSeconds(50)
  do {
    Start-Sleep -Milliseconds 150
    $result=$null
    try {$result=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
    if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
  }until($result.name -eq $case.name)
  if(!$result.ok){throw $result.error}
  $m=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
  if($m.glassError -or $m.state.backdrop.usingFallback){throw "Material failed: $($case.name)"}
  Write-Host $case.name
  return $m
}
$null=Run @{name='motion-warmup';page='home';rhine=$false;dark=$false;query='';reducedMotion=$false;settleMs=6000;capture=$false;sampleRendering=$false}
$null=Run @{name='motion-start';page='home';rhine=$false;dark=$false;query='';reducedMotion=$false;desktopScene=$true;stripedBackdrop=$false;settleMs=2500}
$open=Run @{name='motion-search-open';captureOnly=$true;action='expand-search';settleMs=0;frames=12}
if(!$open.state.motion.expanded -or $open.state.motion.toolbarAnimating -or [Math]::Abs($open.state.motion.searchWidth-$open.state.motion.targetWidth)-gt 1){throw 'Search expansion did not settle'}
$closed=Run @{name='motion-search-close';captureOnly=$true;action='collapse-search';settleMs=0;frames=12}
if($closed.state.motion.expanded -or $closed.state.motion.toolbarAnimating){throw 'Search collapse did not settle'}
for($i=0;$i-lt 8;$i++){
  $null=Run @{name="motion-retarget-$i";captureOnly=$true;action=$(if($i%2-eq 0){'expand-search'}else{'collapse-search'});settleMs=0;capture=$false}
}
$settled=Run @{name='motion-retarget-settled';captureOnly=$true;settleMs=1500}
if($settled.state.motion.toolbarAnimating -or [Math]::Abs($settled.state.motion.searchWidth-$settled.state.motion.targetWidth)-gt 1){throw 'Interrupted spring did not reach its final target'}
$null=Run @{name='motion-archive-start';page='home';rhine=$true;dark=$false;query='';day='2026-09-26';desktopScene=$false;settleMs=3000}
$card=Run @{name='motion-card-open';captureOnly=$true;action='open-first';settleMs=0;frames=20}
if($card.state.rhine.extraction -lt .98 -or !$card.state.rhine.expandedActionsVisible){throw 'Card stalled or its actions did not appear'}
$card=Run @{name='motion-card-close';captureOnly=$true;action='collapse';settleMs=0;frames=20}
if($card.state.rhine.extracted -or $card.state.rhine.expandedActionsVisible){throw 'Card did not return to archive'}
$null=Run @{name='motion-reduced-home';page='home';rhine=$false;dark=$false;query='';reducedMotion=$true;settleMs=300}
$reduced=Run @{name='motion-reduced-search';captureOnly=$true;action='expand-search';settleMs=0;frames=1}
if($reduced.state.motion.enabled -or $reduced.state.motion.toolbarAnimating -or [Math]::Abs($reduced.state.motion.searchWidth-$reduced.state.motion.targetWidth)-gt 1){throw 'Reduced motion was not respected'}
$null=Run @{name='motion-restore';page='home';rhine=$true;dark=$false;query='';day='2026-09-26';reducedMotion=$false;settleMs=3000}
$idle=Run @{name='motion-idle';captureOnly=$true;settleMs=2000;measureSeconds=10;capture=$false;sampleRendering=$false}
if($idle.state.rhine.ticking -or $idle.state.motion.toolbarAnimating){throw 'Animation clock remained active at rest'}
Write-Host ("Idle: {0:N2}% of one core" -f $idle.cpuPercentOfOneCore)
