$ErrorActionPreference='Stop'
$f=Join-Path $PSScriptRoot 'BrabusDebloater.ps1'
$t=$null;$err=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$err)
if($err){throw 'Parser'}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BrabusPower {
 [DllImport("powrprof.dll")] public static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
}
"@
foreach($name in @('PowerCommand','CurrentScheme','PowerRead','PowerWrite','PowerCatalog','ExpansionCatalog','Make','MakeString','BackupHash','WriteEnvelope','ReadEnvelope','NewPayload','ValidateRecords','LoadJournal','SaveJournal','ReadJournal','RestoreRecords','RestoreAll','Event','ReadValue','WriteValue','Same','Display')){
 $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(!$fn){throw "Missing $name"}
 . ([scriptblock]::Create($fn.Extent.Text))
}
$old=CurrentScheme;$rows=@(PowerCatalog)+@(ExpansionCatalog|Where-Object {$_.Path.StartsWith("POWER|")})
if(!$rows.Count){Write-Output 'SKIP: desktop power settings unavailable';exit 0}
$clone=[guid]::NewGuid().ToString()
$root=Join-Path $env:TEMP ('BrabusPowerBackup-'+[guid]::NewGuid().ToString('N'))
$backupDir=$root;$null=New-Item -ItemType Directory $root
$journal=Join-Path $root 'active.json';$mirror=Join-Path $root 'mirror.json';$legacyJournal=Join-Path $root 'legacy.json';$log=Join-Path $root 'log.jsonl'
$created=$false
try{
 $null=PowerCommand @('/duplicatescheme',$old,$clone);$created=$true
 $records=@();$batch=[guid]::NewGuid().ToString('N')
 foreach($r in $rows){
  $path=$r.Path.Replace($old,$clone);$before=ReadValue $path $r.Key
  $target=[pscustomobject]@{Exists=$true;Kind='DWord';Value=$r.TargetState.Value}
  $records+=[pscustomobject]@{Name=$r.Name;Path=$path;Key=$r.Key;Old=$before;Target=$target;Id=[guid]::NewGuid().ToString('N');BatchId=$batch;Time=(Get-Date).ToString('o')}
  SaveJournal $records
  WriteValue $path $r.Key $target
  if(!(Same (ReadValue $path $r.Key) $target)){throw 'Power write verification failed'}
 }
 RestoreAll
 foreach($r in $records){if(!(Same (ReadValue $r.Path $r.Key) $r.Old)){throw 'Power restore mismatch'}}
 if(@(ReadJournal).Count -or (CurrentScheme) -ne $old){throw 'Unexpected active plan or backup remaining'}
 Write-Output "PASS v2 dual-copy rollback on $($records.Count) power settings; active plan unchanged"
}finally{
 if($created -and (CurrentScheme) -ne $clone){$null=PowerCommand @('/delete',$clone)}
 Remove-Item -LiteralPath $root -Recurse -Force
}
