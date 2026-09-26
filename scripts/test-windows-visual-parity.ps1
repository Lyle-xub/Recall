param([Parameter(Mandatory=$true)][string]$Directory, [string]$Round='round1')
$ErrorActionPreference='Stop'
if (!(Test-Path (Join-Path $Directory 'environment.json'))) { throw 'Start Recall with --visual-parity and this directory in the interactive desktop first.' }
$cases=@()
foreach($rhine in @($false,$true)) {
 foreach($dark in @($false,$true)) {
  $mode=if($rhine){'rhine'}else{'classic'};$theme=if($dark){'dark'}else{'light'}
  foreach($state in @('home','results','search')) {
   $case=@{name="$Round-$mode-$theme-$state";rhine=$rhine;dark=$dark;page=$(if($state -eq 'home'){'home'}else{'search'});query=$(if($state -eq 'search'){'Aurora'}else{''});day='2026-09-26';frames=1}
   if($state -eq 'search'){$case.app='Research'}
   $cases+=$case
  }
  if($rhine){$cases+=@{name="$Round-rhine-$theme-expanded";rhine=$true;dark=$dark;page='home';query='';day='2026-09-26';selected='parity-0-0';frames=1}}
 }
}
foreach($tab in @('Recording','Storage')) {$cases+=@{name="$Round-settings-$($tab.ToLower())";page='settings';rhine=$true;dark=$false;tab=$tab;frames=1}}
$cases+=@{name="$Round-rhine-timeline";page='home';rhine=$true;dark=$false;day='2026-09-26';timeline=$true;frames=1}
foreach($case in $cases) {
 [IO.File]::WriteAllText(($directory+'\control.json'),($case|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
 $deadline=(Get-Date).AddSeconds(40)
 do {
  Start-Sleep -Milliseconds 300
  $result=$null
  try {if(Test-Path ($directory+'\completed.json')){$result=Get-Content ($directory+'\completed.json') -Raw|ConvertFrom-Json}}catch{}
  if((Get-Date) -gt $deadline){throw ('Capture timed out: '+$case.name)}
 }until($result.name -eq $case.name)
 if(!$result.ok){throw $result.error}
 Write-Output $case.name
}
