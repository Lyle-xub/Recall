param([Parameter(Mandatory)][string]$Directory, [string]$Prefix='optimization-final')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Write-RecallValidationCommand.ps1')
$checks=0
function Check($condition,[string]$message) { if(!$condition){throw $message}; $script:checks++ }
function Run($case) {
 Write-RecallValidationCommand -Directory $Directory -Command $case
 $deadline=(Get-Date).AddSeconds(55)
 do {
  Start-Sleep -Milliseconds 160
  $result=$null
  try { $result=Get-Content (Join-Path $Directory 'completed.json') -Raw | ConvertFrom-Json } catch {}
  if((Get-Date)-gt $deadline){throw "Timed out: $($case.name)"}
 } until($result.name-eq $case.name)
 if(!$result.ok){throw $result.error}
 $m=Get-Content (Join-Path $Directory ($case.name+'/metrics.json')) -Raw | ConvertFrom-Json
 if($m.glassError){throw $m.glassError}
 if($case.action-ne 'hide') { Check $m.state.native.foreground "Capture is not foreground: $($case.name)" }
 Write-Host $case.name
 return $m
}
foreach($theme in @('light','dark')) {
 $dark=$theme-eq 'dark'
 $ask=Run @{name="$Prefix-ask-$theme";page='ask';rhine=$false;dark=$dark;query='';action='ask-new';settleMs=1800;windowWidth=1280;windowHeight=800}
 Check ($ask.state.ask.width-ge 1000 -and $ask.state.ask.composerWidth-gt 850) 'Ask page or composer collapsed'
 Check ($ask.state.ask.empty -and $ask.state.ask.messages-eq 0) 'Ask empty state retained a prior conversation'
 $answer=Run @{name="$Prefix-answer-$theme";captureOnly=$true;action='ask-sample';settleMs=700}
 Check ($answer.state.ask.messages-eq 2 -and !$answer.state.ask.asking) 'Synthetic answer layout was not populated'
 $gallery=Run @{name="$Prefix-gallery-$theme";page='search';rhine=$false;dark=$dark;query='Archive seam';settleMs=1000}
 Check ($gallery.state.mode-eq 'search') 'Packed image did not reach gallery'
}
foreach($case in @(@('plain720',0),@('pixel90',270),@('pixel180',180),@('pixel270',90),@('pixel90squeezed',270))) {
 $name=$case[0]; $expected=$case[1]
 $m=Run @{name="$Prefix-video-$name";page='detail';selected="parity-video-$name";query='';rhine=$false;dark=$false;action='play-video';settleMs=3200}
 Check ($m.state.media.playing -and !$m.state.media.playbackError) "Video failed: $name"
 Check ($m.state.media.orientationMatch.Confident -and $m.state.media.rotationDegrees-eq $expected) "Video pixels did not align: $name"
 $videoAspect=$m.state.media.surface.imageWidth/[double]$m.state.media.surface.imageHeight
 Check ([Math]::Abs($videoAspect-1.6)-lt .025) "Video aspect was not restored: $name ($videoAspect)"
}
$manual=Run @{name="$Prefix-video-manual";captureOnly=$true;action='rotate-video';settleMs=400}
Check ($manual.state.media.manualRotationDegrees-eq 90) 'Manual rotation lost its offset'
$manualEarly=Run @{name="$Prefix-video-manual-early";page='detail';selected='parity-video-pixel90';rhine=$false;dark=$false;action='play-and-rotate';settleMs=3000}
Check ($manualEarly.state.media.manualRotationDegrees-eq 90 -and $manualEarly.state.media.rotationDegrees-eq 90 -and !$manualEarly.state.media.orientationMatch.Confident) 'An automatic match overrode an early manual rotation'
$hidden=Run @{name="$Prefix-video-hidden";captureOnly=$true;action='hide';settleMs=600}
Check (!$hidden.state.shown -and !$hidden.state.native.windowVisible -and !$hidden.state.backdrop.attached -and !$hidden.state.media.hasPlayer) 'Video retained its backdrop/player after dismissal'
$null=Run @{name="$Prefix-reopen";captureOnly=$true;action='show';settleMs=600}
foreach($theme in @('light','dark')) {
 $rhine=Run @{name="$Prefix-rhine-$theme";page='home';rhine=$true;dark=($theme-eq 'dark');query='';day='2026-09-26';settleMs=1800}
 Check ($rhine.state.rhine.active -and $rhine.state.rhine.loadedImages-gt 0) 'Rhine wall failed to load'
 Check (!$rhine.state.rhine.footer.overlaps) 'Rhine footer controls overlap'
 $small=Run @{name="$Prefix-rhine-small-$theme";captureOnly=$true;windowWidth=800;windowHeight=600;settleMs=3000}
 Check (!$small.state.rhine.footer.overlaps) 'Compact Rhine footer controls overlap'
 $null=Run @{name="$Prefix-rhine-size-restore-$theme";captureOnly=$true;windowWidth=1280;windowHeight=800;settleMs=700}
}
$timeline=Run @{name="$Prefix-rhine-timeline";page='home';rhine=$true;dark=$false;query='';day='2026-09-26';timeline=$true;selected='parity-0-4';settleMs=1200}
Check (!$timeline.state.rhine.footer.dateVisible) 'Rhine footer overlaps the open timeline'
$result=@{passed=$true;checks=$checks;prefix=$Prefix;capturedAt=(Get-Date).ToString('o');note='Synthetic library; video comparisons and codec tests do not record desktop or audio. Pixel checks are recorded separately.'}
$result | ConvertTo-Json | Set-Content (Join-Path $Directory 'optimization-result.json')
Write-Host "PASS: $checks optimization acceptance checks."
