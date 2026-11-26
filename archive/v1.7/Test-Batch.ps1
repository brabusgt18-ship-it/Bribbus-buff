$ErrorActionPreference='Stop'
$p=Join-Path $PSScriptRoot 'BrabusDebloater.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if($e){throw 'Parser'}
foreach($name in @('BackupHash','WriteEnvelope','ReadEnvelope','NewPayload','ValidateRecords','LoadJournal','SaveJournal','ReadJournal','SnapshotRecords','ApplyValue','RestoreRecords','Event','ReadValue','WriteValue','Same','Display','VerificationLabel','NetworkDefinitions','WithNetworkJournal','GetNetworkBackup','InvokeApplyBatch','InvokeRestoreBatch','SetActionFlags')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(!$fn){throw "Missing $name"};. ([scriptblock]::Create($fn.Extent.Text))
}
$backupDir=Join-Path $env:TEMP ('BrabusBatchTest-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $backupDir
$journal=Join-Path $backupDir 'active.json';$mirror=Join-Path $backupDir 'mirror.json';$legacyJournal=Join-Path $backupDir 'legacy.json';$log=Join-Path $backupDir 'changes.jsonl';$script:activeBatch=$null
$key='Software\BrabusBatchTest-'+[guid]::NewGuid().ToString('N')
$script:mockValues=@{'*InterruptModeration'='1';'*LsoV2IPv4'='0';'*LsoV2IPv6'='0'}
function NetworkRead($path,$name){[pscustomobject]@{Exists=$true;Kind='String';Value=$script:mockValues[$name]}}
function NetworkWrite($path,$name,$state){$script:mockValues[$name]=[string]$state.Value}
try{
 $rows=@(foreach($n in @('A','B','C')){[pscustomobject]@{Name=$n;Path=$key;Key=$n;Category='Test';Status='DISPONIBILE';TargetState=[pscustomobject]@{Exists=$true;Kind='DWord';Value=1}}})
 $path='NET|'+[guid]::NewGuid()
 $net=@(foreach($n in @('*InterruptModeration','*LsoV2IPv4','*LsoV2IPv6')){[pscustomobject]@{Name=$n;Path=$path;Key=$n;Category='Network';Status='DISPONIBILE';TargetState=[pscustomobject]@{Exists=$true;Kind='String';Value=$(if($n -eq '*InterruptModeration'){'0'}else{'1'})}}})
 $all=@($rows)+@($net)
 $result=InvokeApplyBatch $all
 if($result.OK -ne 6 -or $result.Failed -ne 0){throw ('Batch failed: '+($result|ConvertTo-Json -Compress))}
 if(@(ReadJournal).Count -ne 3 -or @(GetNetworkBackup).Count -ne 3){throw 'Journal counts wrong'}
 foreach($r in $all){
  if(!(Same (ReadValue $r.Path $r.Key) $r.TargetState)){throw 'Live reread mismatch'}
  $records=if($r.Path -like 'NET|*'){@(GetNetworkBackup)}else{@(ReadJournal)}
  $r.Status='GIA CONFIGURATO';$r|Add-Member NoteProperty VerifiedStatus (VerificationLabel $r $records)
  SetActionFlags $r $records $true
  if(!$r.CanSelect -or !$r.CanRestore -or $r.CanApply){throw 'Restore flags wrong'}
 }
 $subset=@($rows[0],$rows[2],$net[0],$net[2])
 $result=InvokeRestoreBatch $subset
 if($result.OK -ne 4 -or $result.Failed){throw ('Selective restore failed: '+($result|ConvertTo-Json -Compress))}
 if((ReadValue $key 'A').Exists -or (ReadValue $key 'C').Exists -or (ReadValue $key 'B').Value -ne 1){throw 'Registry restore changed unrelated item'}
 if($script:mockValues['*InterruptModeration'] -ne '1' -or $script:mockValues['*LsoV2IPv6'] -ne '0' -or $script:mockValues['*LsoV2IPv4'] -ne '1'){throw 'Network restore changed unrelated item'}
 if(@(ReadJournal).Count -ne 1 -or @(GetNetworkBackup).Count -ne 1){throw 'Selective restore journal mismatch'}
 $result=InvokeRestoreBatch @($rows[1],$net[1]);if($result.OK -ne 2 -or $result.Failed -or @(ReadJournal).Count -or @(GetNetworkBackup).Count){throw 'Remaining restore failed'}
 'PASS: six simultaneous requests (three actual isolated registry writes, three mock driver writes), four selective restores, remaining two preserved and restored'
}finally{Remove-Item -LiteralPath ("HKCU:\"+$key) -ErrorAction SilentlyContinue -Force;Remove-Item -LiteralPath $backupDir -Recurse -Force}
