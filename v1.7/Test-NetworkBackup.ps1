$ErrorActionPreference='Stop'
$p=Join-Path $PSScriptRoot 'BrabusDebloater.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if($e){throw 'Parser error'}
foreach($name in @('BackupHash','WriteEnvelope','ReadEnvelope','NewPayload','ValidateRecords','LoadJournal','SaveJournal','ReadJournal','SnapshotRecords','ApplyValue','RestoreRecords','RestoreAll','Event','ReadValue','WriteValue','Same','Display','NetworkDefinitions','WithNetworkJournal','GetNetworkBackup')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(!$fn){throw "Missing $name"};. ([scriptblock]::Create($fn.Extent.Text))
}
$backupDir=Join-Path $env:TEMP ('BrabusNetTest-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $backupDir
$journal=Join-Path $backupDir 'active.json';$mirror=Join-Path $backupDir 'mirror.json';$legacyJournal=Join-Path $backupDir 'legacy.json';$log=Join-Path $backupDir 'changes.jsonl';$script:activeBatch=$null
$script:mockValue='1'
function NetworkRead($path,$name){[pscustomobject]@{Exists=$true;Kind='String';Value=$script:mockValue}}
function NetworkWrite($path,$name,$state){$script:mockValue=[string]$state.Value}
try{
 $item=[pscustomobject]@{Name='Mock adapter';Path=('NET|'+[guid]::NewGuid());Key='*InterruptModeration';TargetState=[pscustomobject]@{Exists=$true;Kind='String';Value='0'}}
 SaveJournal @()
 WithNetworkJournal {ApplyValue $item}
 if($script:mockValue -ne '0' -or @(GetNetworkBackup).Count -ne 1 -or @(ReadJournal).Count -ne 0){throw 'Network journal isolation failed'}
 $ids=@(GetNetworkBackup|ForEach-Object Id)
 WithNetworkJournal {RestoreRecords $ids}
 if($script:mockValue -ne '1' -or @(GetNetworkBackup).Count -ne 0){throw 'Network restore failed'}
 if(!(Test-Path (Join-Path $backupDir 'network-active.json')) -or !(Test-Path (Join-Path $backupDir 'network-mirror.json'))){throw 'Missing mirrored network journal'}
 'PASS: network simulated apply, mirrored journal isolation and rollback'
}finally{Remove-Item -LiteralPath $backupDir -Recurse -Force}
