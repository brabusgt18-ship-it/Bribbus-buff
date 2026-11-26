$ErrorActionPreference='Stop'
$f=Join-Path $PSScriptRoot 'BrabusDebloater.ps1'
$t=$null;$err=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$err)
if($err){throw 'Parser'}
foreach($name in @('BackupHash','WriteEnvelope','ReadEnvelope','NewPayload','ValidateRecords','LoadJournal','SaveJournal','MigrateLegacy','ReadJournal','SnapshotRecords','ApplyValue','RestoreRecords','RestoreAll','BackupStatus','Event','ReadValue','WriteValue','Same','Display','Make')){
 $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(!$fn){throw "Missing $name"}
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($test,$msg){if(!$test){throw $msg}}
$root=Join-Path $env:TEMP ('BrabusBackupTest-'+[guid]::NewGuid().ToString('N'))
$backupDir=$root;$null=New-Item -ItemType Directory $root
$legacyJournal=Join-Path $root 'legacy.json';$journal=Join-Path $root 'active.json';$mirror=Join-Path $root 'mirror.json';$log=Join-Path $root 'log.jsonl'
$path='Software\BrabusPC-Test-'+[guid]::NewGuid().ToString('N')
$script:activeBatch=$null
try{
 $a=Make 'Café – impostazione' 'Test' $path 'A' 1 'Safe' 'test'
 $b=Make 'Seconda' 'Test' $path 'B' 2 'Safe' 'test'
 $c=Make 'Terza' 'Test' $path 'C' 3 'Safe' 'test'
 $script:activeBatch=SnapshotRecords @($a,$b)
 Assert (@($script:activeBatch.Records).Count -eq 2) 'Snapshot count'
 Assert (@(ReadJournal).Count -eq 0) 'Snapshot must not be applied'
 ApplyValue $a
 Assert (@(ReadJournal).Count -eq 1) 'Write-ahead record'
 # Simulated interruption between two selected changes: only applied/pending key is journaled.
 Assert (!(ReadValue $path 'B').Exists) 'Unapplied key touched'
 $script:activeBatch=$null
 RestoreAll
 Assert (!(ReadValue $path 'A').Exists) 'Partial batch restore'
 Write-Output 'PASS snapshot before apply, Unicode checksum, interrupted batch restore'
 $script:activeBatch=SnapshotRecords @($a,$b)
 try{ApplyValue $a;ApplyValue $b}finally{$script:activeBatch=$null}
 $records=@(ReadJournal)
 Assert ($records.Count -eq 2 -and $records[0].BatchId -eq $records[1].BatchId) 'Batch association'
 RestoreRecords @($records[0].Id)
 Assert (!(ReadValue $path 'A').Exists -and (ReadValue $path 'B').Value -eq 2) 'Selective rollback'
 Assert (@(ReadJournal).Count -eq 1) 'Selective journal'
 Write-Output 'PASS selective restore preserves other settings'
 [IO.File]::WriteAllText($journal,'corrupt')
 Assert (@(ReadJournal).Count -eq 1 -and $script:backupWarning) 'Fallback failed'
 ApplyValue $c
 Assert (@(ReadJournal).Count -eq 2) 'Mirror repair'
 $null=ReadEnvelope $journal;$null=ReadEnvelope $mirror
 Write-Output 'PASS primary corruption fallback and repair'
 WriteValue $path 'B' ([pscustomobject]@{Exists=$true;Kind='DWord';Value=99})
 $blocked=$false
 try{RestoreAll}catch{$blocked=$true}
 Assert ($blocked -and (ReadValue $path 'B').Value -eq 99 -and @(ReadJournal).Count -eq 1) 'Conflict handling'
 Write-Output 'PASS external change preserved and unresolved backup retained'
 # Both corrupt must block all new mutations.
 $saved=[IO.File]::ReadAllBytes($journal)
 $savedMirror=[IO.File]::ReadAllBytes($mirror)
 [IO.File]::WriteAllText($journal,'broken');[IO.File]::WriteAllText($mirror,'broken')
 $blocked=$false
 try{ApplyValue $a}catch{$blocked=$true}
 Assert ($blocked -and !(ReadValue $path 'A').Exists) 'Corrupt backup must block writes'
 [IO.File]::WriteAllBytes($journal,$saved);[IO.File]::WriteAllBytes($mirror,$savedMirror)
 WriteValue $path 'B' ([pscustomobject]@{Exists=$true;Kind='DWord';Value=2})
 RestoreAll
 Assert (@(ReadJournal).Count -eq 0) 'Final restore'
 Write-Output 'PASS both copies corrupt: writes blocked; final recovery'
 # Isolate migration in a new subdirectory.
 $backupDir=Join-Path $root 'migration';$null=New-Item -ItemType Directory $backupDir
 $journal=Join-Path $backupDir 'active.json';$mirror=Join-Path $backupDir 'mirror.json'
 $legacyJournal=Join-Path $root 'legacy.json'
 $old=ReadValue $path 'A';$target=$a.TargetState
 ConvertTo-Json -InputObject @([pscustomobject]@{Name=$a.Name;Path=$path;Key='A';Old=$old;Target=$target}) -Depth 8|Set-Content -LiteralPath $legacyJournal -Encoding UTF8
 WriteValue $path 'A' $target
 MigrateLegacy
 Assert (@(ReadJournal).Count -eq 1 -and !(Test-Path $legacyJournal)) 'Legacy migration'
 Assert (@(Get-ChildItem $backupDir -Filter 'legacy-*.json').Count -eq 2) 'Legacy archives'
 RestoreAll
 Assert (!(ReadValue $path 'A').Exists) 'Migrated restore'
 Write-Output 'PASS legacy migration and restore'
}finally{
 [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($path,$false)
 Remove-Item -LiteralPath $root -Recurse -Force
}
