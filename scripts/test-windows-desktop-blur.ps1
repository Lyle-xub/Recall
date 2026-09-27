param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
$cases=Get-Content (Join-Path $PSScriptRoot 'windows-desktop-blur-cases.json') -Raw|ConvertFrom-Json
foreach($case in $cases) {
  Write-RecallValidationCommand -Directory $Directory -Command $case
  $deadline=(Get-Date).AddSeconds(45)
  do {
    Start-Sleep -Milliseconds 200
    $result=$null
    try {$result=Get-Content (Join-Path $directory 'completed.json') -Raw|ConvertFrom-Json}catch{}
    if((Get-Date) -gt $deadline){throw "Capture timed out: $($case.name)"}
  }until($result.name -eq $case.name)
  if(!$result.ok){throw $result.error}
  Write-Output $case.name
}
