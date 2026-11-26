$ErrorActionPreference='Stop'
$p=Join-Path $PSScriptRoot 'BrabusDebloater.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if($e){throw 'Parser'}
foreach($name in @('BackupHash','WriteEnvelope','ReadEnvelope','NewPayload','ValidateRecords','LoadJournal','SaveJournal','ReadJournal','SnapshotRecords','ApplyValue','RestoreRecords','Event','ReadValue','WriteValue','Same','Display','VerificationLabel','NetworkDefinitions','WithNetworkJournal','GetNetworkBackup')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(!$fn){throw "Missing $name"};. ([scriptblock]::Create($fn.Extent.Text))
}
$backupDir=Join-Path $env:TEMP ('BrabusVerifyTest-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $backupDir
$journal=Join-Path $backupDir 'active.json';$mirror=Join-Path $backupDir 'mirror.json';$legacyJournal=Join-Path $backupDir 'legacy.json';$log=Join-Path $backupDir 'changes.jsonl';$script:activeBatch=$null
$key='Software\BrabusVerificationTest-'+[guid]::NewGuid().ToString('N')
$script:mockValue='1'
function NetworkRead($path,$name){[pscustomobject]@{Exists=$true;Kind='String';Value=$script:mockValue}}
function NetworkWrite($path,$name,$state){$script:mockValue=[string]$state.Value}
try{
 $r=[pscustomobject]@{Name='Temporary test';Path=$key;Key='Test';Category='Test';Status='DISPONIBILE';TargetState=[pscustomobject]@{Exists=$true;Kind='DWord';Value=1}}
 ApplyValue $r
 if((VerificationLabel $r @(ReadJournal)) -ne 'CONFIGURATO / VERIFICATO'){throw 'Readback label failed'}
 WriteValue $key 'Test' ([pscustomobject]@{Exists=$true;Kind='DWord';Value=2})
 if((VerificationLabel $r @(ReadJournal)) -ne 'NON VERIFICATO'){throw 'External drift label failed'}
 WriteValue $key 'Test' $r.TargetState;RestoreRecords @(ReadJournal|ForEach-Object Id)
 if((ReadValue $key 'Test').Exists){throw 'Registry restore failed'}
 if((VerificationLabel $r @(ReadJournal)) -ne 'DISPONIBILE'){throw 'Restored label failed'}
 $n=[pscustomobject]@{Name='Mock adapter';Path=('NET|'+[guid]::NewGuid());Key='*InterruptModeration';Category='Network';Status='DISPONIBILE';TargetState=[pscustomobject]@{Exists=$true;Kind='String';Value='0'}}
 WithNetworkJournal {ApplyValue $n}
 if((VerificationLabel $n @(GetNetworkBackup) $true (Get-Date).AddDays(-1)) -ne 'SALVATO / RIAVVIO PC'){throw 'Premature active status'}
 if((VerificationLabel $n @(GetNetworkBackup) $true (Get-Date).AddDays(1)) -ne 'VERIFICATO DOPO RIAVVIO'){throw 'Post reboot readback failed'}
 $script:mockValue='1'
 if((VerificationLabel $n @(GetNetworkBackup)) -ne 'ORIGINALE / BACKUP'){throw 'Original-value backup label failed'}
 $script:mockValue='2'
 if((VerificationLabel $n @(GetNetworkBackup)) -ne 'NON VERIFICATO'){throw 'Driver drift label failed'}
 $script:mockValue='0';$ids=@(GetNetworkBackup|ForEach-Object Id);WithNetworkJournal {RestoreRecords $ids}
 if($script:mockValue -ne '1'){throw 'Mock restore failed'}
 'PASS: real isolated registry write/readback/drift/restore; mock driver pending/reboot/drift/restore'
}finally{Remove-Item -LiteralPath ("HKCU:\"+$key) -ErrorAction SilentlyContinue -Force;Remove-Item -LiteralPath $backupDir -Recurse -Force}
