function Write-RecallValidationCommand {
 param([string]$Directory, [object]$Command)
 $control=Join-Path $Directory 'control.json'
 $temporary=Join-Path $Directory ('command-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try {
  [IO.File]::WriteAllText($temporary,($Command|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  for($attempt=0;$attempt -lt 30;$attempt++) {
   try {
    if([IO.File]::Exists($control)){[IO.File]::Replace($temporary,$control,[NullString]::Value)}
    else{[IO.File]::Move($temporary,$control)}
    return
   }catch [IO.IOException] {
    if($attempt -eq 29){throw}
    # The app may briefly hold a read handle. Replace the complete file only
    # after it closes, so commands cannot be partially read or lost.
    Start-Sleep -Milliseconds 50
   }
  }
 }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
