param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
function Run($case) {
 if(!$case.ContainsKey('capture')){$case.capture=$false}
 if(!$case.ContainsKey('sampleRendering')){$case.sampleRendering=$false}
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(40)
 do {
  Start-Sleep -Milliseconds 150
  $result=$null
  try {$result=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 }until($result.name-eq $case.name)
 if(!$result.ok){throw $result.error}
 Write-Host $case.name
 return (Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json)
}
foreach($mode in @('classic','rhine')) {
 foreach($reduced in @($false,$true)) {
  $prefix="dismiss-$mode-$reduced"
  $null=Run @{name="$prefix-open";page='home';rhine=($mode-eq 'rhine');dark=$false;query='';reducedMotion=$reduced;desktopScene=$true;settleMs=2000}
  $hidden=Run @{name="$prefix-hidden";captureOnly=$true;action='hide';settleMs=700}
  if($hidden.state.shown -or $hidden.state.native.windowVisible -or $hidden.state.native.hostBackdropEnabled -or $hidden.state.native.hostBackdropResult -ne 0 -or $hidden.state.backdrop.visible -or $hidden.state.backdrop.attached -or $hidden.state.backdrop.targetConnected){throw 'Hidden window retained its backdrop, compositor target or HWND'}
  $shown=Run @{name="$prefix-reopen";captureOnly=$true;action='show';settleMs=1500}
  if(!$shown.state.shown -or !$shown.state.native.windowVisible -or !$shown.state.backdrop.attached){throw 'Backdrop did not recover on reopen'}
  $race=Run @{name="$prefix-interrupted";captureOnly=$true;action='hide-show';settleMs=1000}
  if(!$race.state.shown -or !$race.state.native.windowVisible -or !$race.state.backdrop.attached){throw 'An old close operation hid a reopened window'}
 }
}
$null=Run @{name='dismiss-restore';page='home';rhine=$false;dark=$false;query='';reducedMotion=$false;desktopScene=$false;settleMs=1500}
Write-Host 'PASS: 17 dismissal, reopen and interrupted-close cases completed; 12 lifecycle assertions.'
