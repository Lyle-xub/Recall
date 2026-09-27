param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
# Run after opening/closing the application menu, submenu, range menu and date
# flyout with native input. Theme callbacks must not touch disconnected targets.
function Run($case) {
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(40)
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
foreach($round in 1..4) {
 $state=Run @{name="popup-lifecycle-theme-$round";page='home';rhine=$true;dark=($round%2-eq 1);reducedMotion=($round%2-eq 1);query='';capture=$false;sampleRendering=$false;settleMs=1400}
 if(!$state.shown -or $state.popupGlass.active-ne 0 -or $state.popupGlass.lastError -or !$state.backdrop.targetConnected){throw 'Theme transition retained popup resources or lost the window backdrop'}
 $state=Run @{name="popup-lifecycle-hide-$round";captureOnly=$true;action='hide';capture=$false;sampleRendering=$false;settleMs=400}
 if($state.shown -or $state.native.windowVisible -or $state.native.hostBackdropEnabled -or $state.backdrop.targetConnected -or $state.popupGlass.active-ne 0){throw 'Hide retained a backdrop connection'}
}
$null=Run @{name='popup-lifecycle-restore';page='home';rhine=$true;dark=$false;reducedMotion=$false;query='';capture=$false;sampleRendering=$false;settleMs=1200}
Write-Host 'PASS: 9 theme/visibility cases after native popup interactions.'
