param([Parameter(Mandatory)][string]$Directory, [string]$Round='glass')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
if (!(Test-Path (Join-Path $Directory 'environment.json'))) { throw 'Start Recall --visual-parity in the interactive desktop first.' }
$cases=@()
foreach($dark in @($false,$true)) {
 $theme=if($dark){'dark'}else{'light'}
 foreach($desktop in @($false,$true)) {
  $kind=if($desktop){'background'}else{'material'}
  $cases+=@{name="$Round-$kind-$theme";material=$true;desktop=$desktop;stripedBackdrop=$desktop;dark=$dark;settleMs=2000}
 }
 $cases+=@{name="$Round-fallback-$theme";material=$true;desktop=$true;stripedBackdrop=$true;dark=$dark;fallback=$true;settleMs=1500}
 $cases+=@{name="$Round-host-failure-$theme";material=$true;desktop=$true;stripedBackdrop=$true;dark=$dark;hostFailure=$true;settleMs=1500}
 $cases+=@{name="$Round-recovered-$theme";material=$true;desktop=$true;stripedBackdrop=$true;dark=$dark;settleMs=1500}
 $cases+=@{name="$Round-classic-$theme";page='home';rhine=$false;dark=$dark;stripedBackdrop=$true;settleMs=1500}
}
foreach($case in $cases) {
 $case.desktopScene=$false
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(45)
 do {
  Start-Sleep -Milliseconds 250
  $result=$null
  try {$result=Get-Content (Join-Path $Directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
  if((Get-Date) -gt $deadline){throw "Capture timed out: $($case.name)"}
 }until($result.name -eq $case.name)
 if(!$result.ok){throw $result.error}
 $metrics=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw|ConvertFrom-Json
 if($metrics.glassError){throw $metrics.glassError}
 if($metrics.state.backdrop.usingFallback -ne [bool]($case.fallback -or $case.hostFailure)){throw "Unexpected backdrop fallback: $($case.name)"}
 if($metrics.state.glass.effectsAvailable -eq [bool]$case.fallback){throw "Unexpected foreground effect state: $($case.name)"}
 if($case.hostFailure -and !$metrics.state.backdrop.hostError){throw 'Host failure injection was not exercised.'}
 if(!$case.hostFailure -and $metrics.state.backdrop.hostError){throw 'Host backdrop did not recover.'}
 Write-Output $case.name
}
