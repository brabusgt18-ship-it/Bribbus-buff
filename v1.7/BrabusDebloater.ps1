param([switch]$Scan,[switch]$SelfTest,[switch]$Undo,[switch]$UiTest)
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'BrabusPC-Debloater-State'
$null=New-Item -ItemType Directory -Path $root -Force
$legacyJournal=Join-Path $root 'undo.json'
$backupDir=Join-Path $root 'backup-v2'
$null=New-Item -ItemType Directory -Path $backupDir -Force
$journal=Join-Path $backupDir 'active.json'
$mirror=Join-Path $backupDir 'active-mirror.json'
$log=Join-Path $root 'changes.jsonl'
$script:rows=@()
function Atomic($path,$obj){
 $tmp="$path.tmp"
 ConvertTo-Json -InputObject $obj -Depth 8|Set-Content -LiteralPath $tmp -Encoding UTF8
 if(Test-Path $path){$bak="$path.previous";[IO.File]::Replace($tmp,$path,$bak);Remove-Item -LiteralPath $bak -ErrorAction SilentlyContinue}else{[IO.File]::Move($tmp,$path)}
}
# Native AC power-setting readback, no locale-dependent output parsing.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BrabusPower {
 [DllImport("powrprof.dll")] public static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
}
"@
function PowerCommand([string[]]$argsList){
 $result=& powercfg.exe @argsList 2>&1
 if($LASTEXITCODE -ne 0){throw "powercfg: $result"}
 ($result -join [Environment]::NewLine)
}
function CurrentScheme{
 $m=[regex]::Match((PowerCommand @('/getactivescheme')),'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}')
 if(!$m.Success){throw 'Piano energetico non rilevato'}
 $m.Value
}
function PowerRead($path,$key){
 $parts=$path.Split('|')
 if($parts.Count -ne 3){throw 'Indirizzo energia non valido'}
 $scheme=[guid]$parts[1];$group=[guid]$parts[2];$setting=[guid]$key
 [uint32]$value=0
 $code=[BrabusPower]::PowerReadACValueIndex([IntPtr]::Zero,[ref]$scheme,[ref]$group,[ref]$setting,[ref]$value)
 if($code -ne 0){throw "Impostazione AC non disponibile ($code)"}
 [pscustomobject]@{Exists=$true;Kind='DWord';Value=[int]$value}
}
function PowerWrite($path,$key,$state){
 if(!$state.Exists -or $state.Kind -ne 'DWord'){throw 'Valore energia non valido'}
 $parts=$path.Split('|');$scheme=([guid]$parts[1]).ToString();$group=([guid]$parts[2]).ToString();$setting=([guid]$key).ToString()
 $null=PowerCommand @('/setacvalueindex',$scheme,$group,$setting,[string][int]$state.Value)
 if((CurrentScheme) -eq $scheme){$null=PowerCommand @('/setactive',$scheme)}
}
function PowerCatalog{
 $sys=Get-CimInstance Win32_ComputerSystem
 # Only desktop systems, AC indexes only. Never force power plans on laptops.
 if($sys.PCSystemType -ne 1 -or @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count){return}
 $plan=CurrentScheme
 $proc='54533251-82be-4824-96c1-47b60b740d00'
 $pci='501a4d13-42af-4429-9fd1-a8218c268e20'
 $disk='0012ee47-9041-4b5d-9b77-535fba8b1442'
 $items=@(
  @('CPU: limite massimo 100%',$proc,'bc5038f7-23e0-4960-96da-33abaf5935ec',100,'Rimuove un eventuale limite AC; maggiori consumi possibili'),
  @('CPU: minimo 5%',$proc,'893dee8e-2bef-41e0-89c6-b55d0929964c',5,'Consente idle; utile contro piani bloccati al 100%, non e FPS boost'),
  @('CPU: boost aggressivo',$proc,'be337238-0d82-4146-a960-4f3749d470c7',2,'Puo aumentare calore e consumi; misura temperature prima/dopo'),
  @('CPU: preferenza prestazioni EPP 25',$proc,'36687f9e-e3a5-4dbf-b1dc-15eb381c6863',25,'Solo CPPC/HWP compatibile; effetto hardware non garantito'),
  @('PCIe: risparmio link disattivato',$pci,'ee12f906-d277-404b-b6da-e5fa1a576df5',0,'Opzionale per confronto latenza; maggior consumo a riposo'),
  @('Dischi: nessuno standby AC',$disk,'6738e2c4-e8a5-4a42-b16a-e040e769756e',0,'Solo se HDD entra in standby durante attivita; maggior consumo')
 )
 foreach($item in $items){
  $path="POWER|$plan|$($item[1])"
  try{
   $before=PowerRead $path $item[2]
   $target=[pscustomobject]@{Exists=$true;Kind='DWord';Value=[int]$item[3]}
   [pscustomobject]@{Name=$item[0];Category='Power / CPU';Path=$path;Key=$item[2];TargetState=$target;Before=(Display $before);After=(Display $target);Status=$(if(Same $before $target){'GIA CONFIGURATO'}else{'DISPONIBILE'});Level='OptIn';Note=($item[4]+'; solo piano attivo al momento della scansione, AC');Selected=$false}
  }catch{}
 }
}
function MakeString($name,$category,$path,$key,$value,$note){
 $before=ReadValue $path $key
 $target=[pscustomobject]@{Exists=$true;Kind='String';Value=[string]$value}
 [pscustomobject]@{Name=$name;Category=$category;Path=$path;Key=$key;TargetState=$target;Before=(Display $before);After=(Display $target);Status=$(if(Same $before $target){'GIA CONFIGURATO'}else{'DISPONIBILE'});Level='OptIn';Note=$note;Selected=$false}
}
function MoreCatalog{
 $ex='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
 $cd='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
 $desktop='Control Panel\Desktop'
 $privacy='Software\Microsoft\Windows\CurrentVersion\SearchSettings'
 # Legacy preference keys are explicitly optional and may be ignored on some builds.
 Make 'Miniature al posto delle icone: off' 'Explorer' $ex 'IconsOnly' 1 'OptIn' 'Riduce generazione miniature; perde anteprime'
 Make 'Mostra tipo elemento nei suggerimenti' 'Explorer' $ex 'ShowInfoTip' 0 'OptIn' 'Nasconde descrizioni al passaggio del mouse'
 Make 'Apri cartelle in processo separato' 'Explorer' $ex 'SeparateProcess' 1 'OptIn' 'Isolamento Explorer; puo usare piu RAM, non ottimizzazione FPS'
 Make 'Mostra barra di stato Explorer' 'Explorer' $ex 'ShowStatusBar' 1 'OptIn' 'Preferenza visiva'
 Make 'Mostra unita senza supporti' 'Explorer' $ex 'HideDrivesWithNoMedia' 0 'OptIn' 'Mostra unita senza supporti'
 Make 'Colori file compressi/cifrati: off' 'Privacy' $ex 'ShowCompColor' 0 'OptIn' 'Non colora file NTFS compressi o cifrati'
 Make 'Ricerca: cronologia dispositivo' 'Privacy' $privacy 'IsDeviceSearchHistoryEnabled' 0 'OptIn' 'Disattiva salvataggio cronologia ricerca locale; non cancella dati'
 Make 'Ricerca: contenuti cloud account personale' 'Privacy' $privacy 'IsMSACloudSearchEnabled' 0 'OptIn' 'Non mostra contenuti cloud nella ricerca'
 Make 'Ricerca: contenuti cloud lavoro/scuola' 'Privacy' $privacy 'IsAADCloudSearchEnabled' 0 'OptIn' 'Non mostra contenuti cloud lavoro/scuola; non usare su PC gestito'
 Make 'Rotazione contenuti schermata di blocco' 'Debloat' $cd 'RotatingLockScreenEnabled' 0 'OptIn' 'Preferenza contenuti lock screen'
 Make 'Overlay contenuti schermata di blocco' 'Debloat' $cd 'RotatingLockScreenOverlayEnabled' 0 'OptIn' 'Preferenza suggerimenti lock screen'
 Make 'Mostra consigli account in Start' 'Debloat' $ex 'Start_AccountNotifications' 0 'OptIn' 'Preferenza dipendente dalla build'
 MakeString 'Animazioni finestre' 'Visual' 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'Disabilita animazioni min/max; nuovo accesso puo essere necessario'
 MakeString 'Ritardo apertura menu 150 ms' 'Visual' $desktop 'MenuShowDelay' '150' 'Preferenza UX, non cambia latenza input in gioco'
 MakeString 'Comportamento mouse: accelerazione off' 'Input' 'Control Panel\Mouse' 'MouseSpeed' '0' 'Solo puntatore Windows, giochi raw input possono ignorarlo'
 PowerCatalog
}

function ReadValue($path,$name){
 if($path.StartsWith("NET|")){return NetworkRead $path $name};if($path.StartsWith("POWER|")){return PowerRead $path $name}
 $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
 try{
  if($k -and $k.GetValueNames() -contains $name){return [pscustomobject]@{Exists=$true;Kind=[string]$k.GetValueKind($name);Value=$k.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}}
  [pscustomobject]@{Exists=$false;Kind='';Value=$null}
 }finally{if($k){$k.Dispose()}}
}
function WriteValue($path,$name,$state){
 if($path.StartsWith("NET|")){NetworkWrite $path $name $state;return};if($path.StartsWith("POWER|")){PowerWrite $path $name $state;return}
 if($state.Exists){
  $k=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
  try{$value=switch($state.Kind){DWord{[int]$state.Value} String{[string]$state.Value} ExpandString{[string]$state.Value} default{throw 'Tipo non supportato'}}
   $k.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]$state.Kind)
  }finally{$k.Dispose()}
 }else{
  $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$true)
  if($k){try{$k.DeleteValue($name,$false)}finally{$k.Dispose()}}
 }
}
function Same($a,$b){return ($a.Exists -eq $b.Exists -and (!$a.Exists -or ($a.Kind -eq $b.Kind -and [string]$a.Value -ceq [string]$b.Value)))}
function Display($v){if($v.Exists){[string]$v.Value}else{'Non impostato'}}
function Event($name,$before,$after,$status){
 $e=[ordered]@{Time=(Get-Date).ToString('o');Action=$name;Before=[string]$before;After=[string]$after;Status=$status}
 $e|ConvertTo-Json -Compress|Add-Content -LiteralPath $log -Encoding UTF8
}
# Backup v2: two independently readable copies and immutable session snapshots.
$script:activeBatch=$null
$script:backupWarning=''
function BackupHash([string]$text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
}
function WriteEnvelope($file,$payload){
 $json=ConvertTo-Json -InputObject $payload -Depth 16 -Compress
 $outer=ConvertTo-Json -InputObject @{Format='BrabusBackupV2';SHA256=(BackupHash $json);Payload=$json} -Compress
 $tmp="$file.$([guid]::NewGuid().ToString('N')).tmp"
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes($outer)
 try{
  $fs=[IO.FileStream]::new($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$fs.Write($bytes,0,$bytes.Length);$fs.Flush($true)}finally{$fs.Dispose()}
  if(Test-Path -LiteralPath $file){$bak="$tmp.previous";[IO.File]::Replace($tmp,$file,$bak);Remove-Item -LiteralPath $bak -ErrorAction SilentlyContinue}else{[IO.File]::Move($tmp,$file)}
 }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue}}
}
function ReadEnvelope($file){
 if(!(Test-Path -LiteralPath $file)){throw 'File backup assente'}
 if((Get-Item -LiteralPath $file).Length -gt 50MB){throw 'Backup troppo grande'}
 $e=[IO.File]::ReadAllText($file,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
 if($e.Format -ne 'BrabusBackupV2' -or $e.Payload -isnot [string] -or (BackupHash $e.Payload) -cne $e.SHA256){throw 'Checksum non valido'}
 $obj=$e.Payload|ConvertFrom-Json
 if($obj.Version -ne 2 -or $obj.Owner -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Backup di un altro utente o versione'}
 $obj
}
function NewPayload($records,$type){
 [ordered]@{Version=2;Owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Time=(Get-Date).ToString('o');Type=$type;Records=@($records)}
}
function ValidateRecords($records){
 $seen=@{}
 foreach($r in @($records)){
  if($null -eq $r -or !$r.Path -or !$r.Key -or !$r.Name -or !$r.BatchId -or !$r.Id){throw 'Record backup incompleto'}
  if($r.Path -notmatch '^(Software\\|System\\|Control Panel\\|POWER\||NET\|)' -or $r.Path -match '[\r\n]'){throw 'Percorso backup non supportato'}
  foreach($v in @($r.Old,$r.Target)){
   if($null -eq $v -or $v.Exists -isnot [bool]){throw 'Stato backup non valido'}
   if($v.Exists -and $v.Kind -notin @('DWord','String','ExpandString')){throw 'Tipo backup non supportato'}
   if($v.Exists -and $v.Kind -eq 'DWord'){ $null=[int]$v.Value }
  }
  if($r.Path.StartsWith('POWER|')){
   $parts=$r.Path.Split('|')
   if($parts.Count -ne 3){throw 'Record energia non valido'}
   $null=[guid]$parts[1];$null=[guid]$parts[2];$null=[guid]$r.Key
   if(!$r.Old.Exists -or !$r.Target.Exists -or $r.Old.Kind -ne 'DWord' -or $r.Target.Kind -ne 'DWord'){throw 'Stato energia non valido'}
  }
  if($r.Path.StartsWith('NET|')){
   $parts=$r.Path.Split('|');$defs=NetworkDefinitions
   if($parts.Count -ne 2 -or !$defs.ContainsKey($r.Key)){throw 'Record rete non autorizzato'}
   $null=[guid]$parts[1]
   foreach($v in @($r.Old,$r.Target)){if(!$v.Exists -or $v.Kind -ne 'String' -or [string]$v.Value -notmatch '^[0-9]{1,2}$'){throw 'Stato rete non valido'}}
  }
  $k="$($r.Path)|$($r.Key)"
  if($seen.ContainsKey($k)){throw 'Record duplicato nel backup'}
  $seen[$k]=$true
 }
}
function LoadJournal {
 $script:backupWarning=''
 $a=$null;$b=$null
 $pa=Test-Path -LiteralPath $journal;$pb=Test-Path -LiteralPath $mirror
 if(!$pa -and !$pb){
  if(Test-Path -LiteralPath $legacyJournal){throw 'Backup precedente non migrato: apri il centro backup'}
  if(Test-Path -LiteralPath $(if($initializedFlag){$initializedFlag}else{Join-Path $backupDir 'initialized.flag'})){throw 'Entrambe le copie backup mancanti: nessuna modifica consentita'}
  return
 }
 try{$a=ReadEnvelope $journal;if($a.Type -ne 'Journal'){throw 'Tipo errato'};ValidateRecords @($a.Records)}catch{$a=$null}
 try{$b=ReadEnvelope $mirror;if($b.Type -ne 'Journal'){throw 'Tipo errato'};ValidateRecords @($b.Records)}catch{$b=$null}
 if(!$a -and !$b){throw 'Entrambe le copie del backup non valide: nessuna scrittura consentita'}
 if(!$a){$script:backupWarning='Copia primaria danneggiata o assente: uso copia ridondante';$a=$b}
 elseif(!$b){$script:backupWarning='Copia ridondante danneggiata o assente'}
 elseif((BackupHash (ConvertTo-Json -InputObject $a -Depth 16 -Compress)) -ne (BackupHash (ConvertTo-Json -InputObject $b -Depth 16 -Compress))){$script:backupWarning='Copie divergenti: primaria prioritaria (scritta per prima)'}
 foreach($r in @($a.Records)){if($null -ne $r){Write-Output $r}}
}
function SaveJournal($records){
 ValidateRecords @($records)
 $payload=NewPayload @($records) 'Journal'
 WriteEnvelope $journal $payload
 WriteEnvelope $mirror $payload
 $a=ReadEnvelope $journal;$b=ReadEnvelope $mirror
 if((BackupHash (ConvertTo-Json -InputObject $a -Depth 16 -Compress)) -ne (BackupHash (ConvertTo-Json -InputObject $b -Depth 16 -Compress))){throw 'Copie backup non identiche; modifica bloccata'}
 if(!(Test-Path -LiteralPath $(if($initializedFlag){$initializedFlag}else{Join-Path $backupDir 'initialized.flag'}))){[IO.File]::WriteAllText($(if($initializedFlag){$initializedFlag}else{Join-Path $backupDir 'initialized.flag'}),'2')}
}
function MigrateLegacy{
 if(!(Test-Path -LiteralPath $legacyJournal)){return}
 if((Test-Path -LiteralPath $journal) -or (Test-Path -LiteralPath $mirror)){throw 'Backup legacy e v2 entrambi presenti: controllo manuale richiesto'}
 $records=@()
 $batch=[guid]::NewGuid().ToString('N')
 foreach($r in (Get-Content -LiteralPath $legacyJournal -Raw|ConvertFrom-Json)){
  $records+= [pscustomobject]@{Name=$r.Name;Path=$r.Path;Key=$r.Key;Old=$r.Old;Target=$r.Target;BatchId=$batch;Id=[guid]::NewGuid().ToString('N');Time=(Get-Date).ToString('o')}
 }
 ValidateRecords $records
 $archive=Join-Path $backupDir ('legacy-'+$batch+'.json')
 Copy-Item -LiteralPath $legacyJournal -Destination $archive
 if((Get-FileHash -LiteralPath $archive).Hash -ne (Get-FileHash -LiteralPath $legacyJournal).Hash){throw 'Copia legacy non verificata'}
 SaveJournal $records
 Move-Item -LiteralPath $legacyJournal -Destination (Join-Path $backupDir ('legacy-original-'+$batch+'.json'))
}
function ReadJournal {LoadJournal}
function SnapshotRecords($items){
 $existing=@(ReadJournal)
 $batch=[guid]::NewGuid().ToString('N');$records=@()
 foreach($item in @($items)){
  $old=ReadValue $item.Path $item.Key;$target=$item.TargetState
  if(Same $old $target){continue}
  if(@($existing|Where-Object {$_.Path -eq $item.Path -and $_.Key -eq $item.Key}).Count){throw "Backup gia attivo: $($item.Name). Ripristina prima di riapplicare."}
  if($item.Path.StartsWith('POWER|') -and (CurrentScheme) -ne $item.Path.Split('|')[1]){throw 'Piano energetico cambiato: esegui una nuova scansione'}
  $records+= [pscustomobject]@{Name=$item.Name;Path=$item.Path;Key=$item.Key;Old=$old;Target=$target;BatchId=$batch;Id=[guid]::NewGuid().ToString('N');Time=(Get-Date).ToString('o')}
 }
 ValidateRecords $records
 if($records.Count){
  $file=Join-Path $backupDir ('snapshot-'+$batch+'.json')
  WriteEnvelope $file (NewPayload $records 'Snapshot')
  $read=ReadEnvelope $file
  ValidateRecords @($read.Records)
  if(@($read.Records).Count -ne $records.Count){throw 'Snapshot incompleto'}
 }
 [pscustomobject]@{Id=$batch;Records=$records}
}
function ApplyValue($item){
 if($item.Path.StartsWith('POWER|')){
  if((CurrentScheme) -ne $item.Path.Split('|')[1]){throw 'Piano cambiato: esegui nuova scansione'}
  if((Test-Path (Join-Path $env:LOCALAPPDATA 'BrabusPC-WinUtil-State\power.json')) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'BrabusPCOptimizerState\restore.json'))){throw 'Ripristina prima altri optimizer'}
 }
 $old=ReadValue $item.Path $item.Key;$target=$item.TargetState
 if(Same $old $target){Event $item.Name (Display $old) (Display $target) 'GIA CONFIGURATO';return}
 $batch=$script:activeBatch
 if(!$batch){$batch=SnapshotRecords @($item)}
 $record=@($batch.Records|Where-Object {$_.Path -eq $item.Path -and $_.Key -eq $item.Key})|Select-Object -First 1
 if(!$record -or !(Same $old $record.Old) -or !(Same $target $record.Target)){throw 'Valore cambiato dopo snapshot; ripetere scansione'}
 $entries=@(ReadJournal)
 if(@($entries|Where-Object {$_.Path -eq $item.Path -and $_.Key -eq $item.Key}).Count){throw 'Backup gia presente'}
 # Both journal copies are verified BEFORE the actual registry/power write.
 SaveJournal @($entries+$record)
 try{
  if(!(Same (ReadValue $item.Path $item.Key) $record.Old)){throw 'Valore cambiato prima della scrittura'}
  WriteValue $item.Path $item.Key $target
  $actual=ReadValue $item.Path $item.Key
  if(!(Same $actual $target)){throw 'Verifica fallita'}
  Event $item.Name (Display $old) (Display $actual) 'VERIFICATO'
 }catch{Event $item.Name (Display $old) '?' ('ERRORE: '+$_.Exception.Message);throw}
}
function RestoreRecords($ids){
 $records=@(ReadJournal)
 $selected=@($records|Where-Object {$_.Id -in $ids})
 if(!$selected.Count){return}
 $file=Join-Path $backupDir ('restore-'+[guid]::NewGuid().ToString('N')+'.json')
 WriteEnvelope $file (NewPayload $selected 'RestoreAttempt')
 $null=ReadEnvelope $file
 $failed=0
 [array]::Reverse($selected)
 foreach($r in $selected){
  try{
   $now=ReadValue $r.Path $r.Key
   if(!(Same $now $r.Old)){
    if(!(Same $now $r.Target)){throw 'Valore cambiato esternamente: non sovrascritto'}
    WriteValue $r.Path $r.Key $r.Old
    if(!(Same (ReadValue $r.Path $r.Key) $r.Old)){throw 'Ripristino non verificato'}
   }
   $remaining=@(ReadJournal|Where-Object Id -ne $r.Id)
   SaveJournal $remaining
   Event $r.Name (Display $now) (Display $r.Old) 'RIPRISTINATO'
  }catch{$failed++;Event $r.Name '-' '-' ('ERRORE RIPRISTINO: '+$_.Exception.Message)}
 }
 if($failed){throw "$failed modifiche non ripristinate; backup conservato"}
}
function RestoreAll{RestoreRecords @(ReadJournal|ForEach-Object Id)}
function BackupStatus{
 $records=@(ReadJournal)
 [pscustomobject]@{Pending=$records.Count;Snapshots=@(Get-ChildItem -LiteralPath $backupDir -Filter 'snapshot-*.json' -File).Count;Warning=$script:backupWarning}
}

function Make($name,$category,$path,$key,$value,$level,$note){
 $before=ReadValue $path $key
 $target=[pscustomobject]@{Exists=$true;Kind='DWord';Value=$value}
 [pscustomobject]@{Name=$name;Category=$category;Path=$path;Key=$key;TargetState=$target;Before=(Display $before);After=(Display $target);Status=$(if(Same $before $target){'GIA CONFIGURATO'}else{'DISPONIBILE'});Level=$level;Note=$note;Selected=$false}
}
# Independent extra modules, not imported Winhance code.
function IsElevated {
 ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function PersonalPolicyCatalog {
 # Read Microsoft templates on the actual device; skip unavailable policy definitions.
 if((Get-CimInstance Win32_ComputerSystem).PartOfDomain){return}
 $definitions=@(
  @('CloudContent.admx','DisableThirdPartySuggestions','Spotlight: suggerimenti terze parti','Debloat'),
  @('CloudContent.admx','DisableSpotlightCollectionOnDesktop','Spotlight: raccolta sul desktop','Debloat'),
  @('CloudContent.admx','DisableWindowsSpotlightOnActionCenter','Spotlight: suggerimenti nel centro notifiche','Debloat'),
  @('CloudContent.admx','DisableWindowsSpotlightOnSettings','Spotlight: suggerimenti in Impostazioni','Debloat'),
  @('CloudContent.admx','DisableWindowsSpotlightWindowsWelcomeExperience','Spotlight: schermata benvenuto','Debloat'),
  @('CloudContent.admx','DisableTailoredExperiencesWithDiagnosticData','Policy: esperienze personalizzate','Privacy'),
  @('CloudContent.admx','DisableWindowsSpotlightFeatures','Spotlight: disabilita tutte le funzioni','Debloat'),
  @('WindowsExplorer.admx','DisableThumbsDBOnNetworkFolders','Esplora file: cache miniature di rete','Explorer'),
  @('Explorer.admx','DisableThumbsDBOnNetworkFolders','Esplora file: cache miniature di rete','Explorer')
 )
 $seen=@{}
 foreach($d in $definitions){
  $file=Join-Path (Join-Path $env:windir 'PolicyDefinitions') $d[0]
  if(!(Test-Path -LiteralPath $file)){continue}
  try{
   [xml]$xml=Get-Content -LiteralPath $file -Raw
   $policy=$xml.policyDefinitions.policies.policy|Where-Object {$_.name -eq $d[1] -and $_.class -eq 'User' -and $_.key -and $_.valueName -and $null -ne $_.enabledValue.decimal.value}|Select-Object -First 1
   if(!$policy){continue}
   $id="$($policy.key)|$($policy.valueName)"
   if($seen.ContainsKey($id)){continue};$seen[$id]=$true
   Make $d[2] $d[3] $policy.key $policy.valueName ([int]$policy.enabledValue.decimal.value) 'OptIn' 'Criterio utente da ADMX locale; edizione/build e gestione MDM possono limitarne effetto'
  }catch{}
 }
}
function AdditionalCatalog {
 $ex='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
 $cd='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
 $n='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
 Make 'Disattiva suggerimenti soft landing' 'Debloat' $cd 'SoftLandingEnabled' 0 'OptIn' 'Preferenza legacy: effetto variabile'
 Make 'Disattiva sottoscrizioni promozionali' 'Debloat' $cd 'SubscribedContentEnabled' 0 'OptIn' 'Preferenza utente per contenuti promozionali'
 Make 'Preferenza lingua non condivisa sul web' 'Privacy' 'Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1 'OptIn' 'Influenza lingua automatica dei siti compatibili'
 Make 'Diagnostica digitazione facoltativa' 'Privacy' 'Software\Microsoft\Input\TIPC' 'Enabled' 0 'OptIn' 'Riduce invio facoltativo dati digitazione; non tocca riconoscimento vocale'
 Make 'Notifiche account in Impostazioni' 'Notifications' 'Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications' 'EnableAccountNotifications' 0 'OptIn' 'Puoi perdere promemoria account e backup'
 Make 'Notifiche barra di gioco' 'Notifications' 'Software\Microsoft\GameBar' 'ShowStartupPanel' 0 'OptIn' 'Nasconde pannello di avvio Game Bar; dipende dalla versione'
 Make 'Notifiche toast Windows' 'Notifications' 'Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 'OptIn' 'Disabilita toast globali; potresti perdere notifiche importanti; mai nei preset'
 Make 'Suoni notifiche toast' 'Audio' $n 'NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND' 0 'OptIn' 'Preferenza suono notifiche; non modifica audio dei giochi'
 Make 'Mostra desktop con angolo barra' 'Visual' $ex 'TaskbarSd' 1 'OptIn' 'Preferenza usabilita; Windows 11 compatibile'
 Make 'Checkbox selezione file' 'Explorer' $ex 'AutoCheckSelect' 1 'OptIn' 'Preferenza selezione file'
 Make 'Mostra percorso completo in titolo' 'Explorer' 'Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1 'OptIn' 'Preferenza Esplora file; supporto build variabile'
 Make 'Disattiva Aero Shake' 'Visual' $ex 'DisallowShaking' 1 'OptIn' 'Evita minimizzazione finestre tramite gesto'
 PersonalPolicyCatalog
}
function SoftwareCatalog {
 $raw=@'
Browser|Firefox|Mozilla.Firefox
Browser|Brave|Brave.Brave
Browser|Chrome|Google.Chrome
Browser|Vivaldi|Vivaldi.Vivaldi
Gaming|Steam|Valve.Steam
Gaming|Epic Games Launcher|EpicGames.EpicGamesLauncher
Gaming|Discord|Discord.Discord
Gaming|OBS Studio|OBSProject.OBSStudio
Gaming|Heroic Games Launcher|HeroicGamesLauncher.HeroicGamesLauncher
Gaming|Playnite|Playnite.Playnite
Gaming|MSI Afterburner|Guru3D.Afterburner
Media|VLC|VideoLAN.VLC
Media|Audacity|Audacity.Audacity
Media|HandBrake|HandBrake.HandBrake
Media|foobar2000|PeterPawlowski.foobar2000
Utility|7-Zip|7zip.7zip
Utility|PowerToys|Microsoft.PowerToys
Utility|Everything|voidtools.Everything
Utility|TreeSize Free|JAMSoftware.TreeSize.Free
Utility|Notepad++|Notepad++.Notepad++
Utility|CrystalDiskInfo|CrystalDewWorld.CrystalDiskInfo
Utility|WinDirStat|WinDirStat.WinDirStat
Utility|HWiNFO|REALiX.HWiNFO
Utility|CPU-Z|CPUID.CPU-Z
Utility|GPU-Z|TechPowerUp.GPU-Z
Office|LibreOffice|TheDocumentFoundation.LibreOffice
Office|SumatraPDF|SumatraPDF.SumatraPDF
Office|PDF24|geeksoftwareGmbH.PDF24Creator
Development|Git|Git.Git
Development|Visual Studio Code|Microsoft.VisualStudioCode
Development|PowerShell|Microsoft.PowerShell
Development|Python 3.13|Python.Python.3.13
Development|Node.js LTS|OpenJS.NodeJS.LTS
Development|Windows Terminal|Microsoft.WindowsTerminal
Creative|GIMP|GIMP.GIMP.3
Creative|Krita|KDE.Krita
Creative|Blender|BlenderFoundation.Blender
Creative|Paint.NET|dotPDN.PaintDotNet
Communication|Telegram|Telegram.TelegramDesktop
Communication|Signal|OpenWhisperSystems.Signal
Communication|Zoom|Zoom.Zoom
'@
 foreach($line in ($raw -split '\r?\n')){
  if(!$line.Trim()){continue}
  $p=$line.Split('|')
  [pscustomobject]@{Category=$p[0];Name=$p[1];Id=$p[2];Label="$($p[0])  |  $($p[1])  [$($p[2])]"}
 }
}
function ModuleDialog($title,$hint,$items,$display,$actionTitle,[scriptblock]$action){
 $d=New-Object Windows.Window
 $d.Title=$title;$d.Width=830;$d.Height=640;$d.Owner=$w;$d.WindowStartupLocation='CenterOwner';$d.Background='#0B1220';$d.Foreground='#E3ECF9';$d.Resources.MergedDictionaries.Add($w.Resources);SetDarkChrome $d
 $panel=New-Object Windows.Controls.DockPanel;$panel.Margin='16'
 $head=New-Object Windows.Controls.StackPanel;[Windows.Controls.DockPanel]::SetDock($head,'Top')
 $note=New-Object Windows.Controls.TextBlock;$note.Text=$hint;$note.TextWrapping='Wrap';$note.Margin='0,0,0,10';$null=$head.Children.Add($note)
 $filter=New-Object Windows.Controls.TextBox;$filter.Margin='0,0,0,10';$null=$head.Children.Add($filter);$null=$panel.Children.Add($head)
 $buttons=New-Object Windows.Controls.StackPanel;$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';[Windows.Controls.DockPanel]::SetDock($buttons,'Bottom')
 $go=New-Object Windows.Controls.Button;$go.Content=$actionTitle;$go.Background='#0C7189';$null=$buttons.Children.Add($go)
 $close=New-Object Windows.Controls.Button;$close.Content='CHIUDI';$close.IsCancel=$true;$null=$buttons.Children.Add($close);$null=$panel.Children.Add($buttons)
 $list=New-Object Windows.Controls.ListBox;$list.DisplayMemberPath=$display;$list.ItemsSource=@($items);$list.SelectionMode='Single';$null=$panel.Children.Add($list)
 $filter.Add_TextChanged({$q=$filter.Text.Trim();$list.ItemsSource=@($items|Where-Object {!$q -or [string]$_.$display -like "*$q*"})})
 $go.Add_Click({if($list.SelectedItem){try{& $action $list.SelectedItem}catch{$status.Text=$_.Exception.Message}}})
 $d.Content=$panel;$null=$d.ShowDialog()
}
function OpenSoftwareCenter {
 if(!(Get-Command winget -ErrorAction SilentlyContinue)){throw 'WinGet non disponibile: installa App Installer da Microsoft Store'}
 $items=@(SoftwareCatalog)
 ModuleDialog 'Software Center / WinGet' 'Catalogo di candidati. Ogni ID viene verificato sul repository winget prima di installare. Nessuna installazione automatica in blocco.' $items 'Label' 'VERIFICA E INSTALLA' {
  param($item)
  $id=[string]$item.Id
  if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{1,99}$' -or $id -notin @(SoftwareCatalog|ForEach-Object Id)){throw 'ID non autorizzato'}
  $details=& winget show --id $id --exact --source winget --disable-interactivity 2>&1
  if($LASTEXITCODE -ne 0){$status.Text="ID non verificato: $id";return}
  if(!(ConfirmDark "Installare $($item.Name)?" ($details|Out-String))){return}
  $job=Start-Process -FilePath (Get-Command winget).Source -ArgumentList @('install','--id',$id,'--exact','--source','winget','--interactive') -PassThru -Wait
  $result=if($job.ExitCode -eq 0){'COMANDO RIUSCITO - verifica elenco installato'}else{"ERRORE/ANNULLATO: $($job.ExitCode)"}
  Event "WinGet: $id" 'Installazione richiesta' $job.ExitCode $result
  UpdateLog;$status.Text=$result
 }
}
function GetFeatureInventory{
 @(Get-CimInstance Win32_OptionalFeature -ErrorAction Stop|ForEach-Object {
  $state=switch([int]$_.InstallState){1{'Abilitata'} 2{'Disabilitata'} 3{'Assente'} default{'Sconosciuta'}}
  [pscustomobject]@{Name=$_.Name;State=$state;Label="$state  |  $($_.Name)"}
 }|Sort-Object Name)
}
function OpenFeatureCenter{
 $features=@(GetFeatureInventory)
 ModuleDialog 'Funzionalita Windows' 'Inventario delle funzionalita del sistema. L attivazione/rimozione resta nel gestore ufficiale Windows, che controlla dipendenze e richiede elevazione quando necessaria. Non disabilitare componenti usati da giochi, WSL o virtualizzazione.' $features 'Label' 'APRI GESTORE WINDOWS' {
  param($item)
  Start-Process optionalfeatures.exe
  Event 'Funzionalita Windows' $item.Name 'Gestore ufficiale aperto' 'GUIDATO'
  UpdateLog
 }
}
function GetServiceInventory {
 @(Get-CimInstance Win32_Service|ForEach-Object {
  [pscustomobject]@{Name=$_.Name;State=$_.State;StartMode=$_.StartMode;Label="$($_.StartMode) / $($_.State)  |  $($_.DisplayName) [$($_.Name)]"}
 }|Sort-Object Label)
}
function OpenServiceCenter {
 ModuleDialog 'Servizi Windows / Inventario' 'Inventario in sola lettura. I servizi non vengono arrestati o disabilitati automaticamente: possono avere dipendenze o essere necessari a sicurezza, rete e periferiche.' @(GetServiceInventory) 'Label' 'APRI SERVIZI WINDOWS' {
  param($item)
  Start-Process services.msc
  Event 'Servizi Windows' $item.Name 'Gestore ufficiale aperto' 'GUIDATO'
  UpdateLog
 }
}
function ExtendedDiagnostics {
 $out=[ordered]@{}
 $out.Power=(& powercfg /getactivescheme|Out-String).Trim()
 $out.Adapter=@(Get-NetAdapter -ErrorAction SilentlyContinue|Select-Object Name,Status,LinkSpeed,InterfaceDescription)
 $out.DNS=@(Get-DnsClientServerAddress -ErrorAction SilentlyContinue|Select-Object InterfaceAlias,AddressFamily,ServerAddresses)
 $out.NetworkCounters=@(Get-NetAdapterStatistics -ErrorAction SilentlyContinue|Select-Object Name,ReceivedDiscardedPackets,ReceivedPacketErrors,OutboundDiscardedPackets,OutboundPacketErrors)
 $out.Storage=@(Get-PhysicalDisk -ErrorAction SilentlyContinue|Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size)
 $out.GPU=@(Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,CurrentRefreshRate)
 $out.DriverIssues=@(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue|Select-Object Name,ConfigManagerErrorCode)
 $out.Audio=@(Get-CimInstance Win32_SoundDevice|Select-Object Name,Status)
 $out.UpdateService=@(Get-Service wuauserv,BITS,DoSvc -ErrorAction SilentlyContinue|Select-Object Name,Status,StartType)
 $out.Features=@(GetFeatureInventory|Select-Object Name,State)
 $out.Services=@(GetServiceInventory|Group-Object StartMode|Select-Object Name,Count)
 $out.Note='Counters are cumulative snapshots; no conclusion about bottlenecks or latency from these alone.'
 return $out
}
function ShowExtendedDiagnostics{
 $data=ExtendedDiagnostics
 $file=Join-Path $root ('extended-'+[guid]::NewGuid().ToString()+'.json')
 Atomic $file $data
 $w.FindName('Report').Text=$data|ConvertTo-Json -Depth 8
 $w.FindName('Tabs').SelectedIndex=1
 $status.Text="Diagnostica estesa: $file"
}

function OpenGPUPreference {
 $dlg=New-Object Microsoft.Win32.OpenFileDialog
 $dlg.Title='Seleziona eseguibile del gioco'
 $dlg.Filter='Applicazioni Windows (*.exe)|*.exe'
 if($dlg.ShowDialog($w) -ne $true){return}
 $exe=[IO.Path]::GetFullPath($dlg.FileName)
 if(!(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Eseguibile non trovato'}
 $path='Software\Microsoft\DirectX\UserGpuPreferences'
 $before=ReadValue $path $exe
 if($before.Exists -and $before.Kind -ne 'String'){throw 'Formato esistente non supportato'}
 $old=if($before.Exists){[string]$before.Value}else{''}
 $parts=@($old.Split(';')|Where-Object {$_ -and $_ -notmatch '^GpuPreference='})
 $new=(@($parts)+@('GpuPreference=2')) -join ';'
 $new+=';'
 $item=MakeString ('GPU preferita: '+[IO.Path]::GetFileName($exe)) 'GPU' $path $exe $new 'Preferenza Windows alta prestazione, non overclock; preserva altri campi'
 $msg="Eseguibile: $exe"+[Environment]::NewLine+"Prima: $($item.Before)"+[Environment]::NewLine+"Dopo: $($item.After)"+[Environment]::NewLine+'Utile soprattutto con piu GPU; non forza FPS superiori. Riavvia il gioco dopo il cambio.'
 if(!(ConfirmDark 'Preferenza GPU per gioco' $msg)){return}
 ApplyValue $item
 RefreshRows
 $status.Text='Preferenza GPU scritta e verificata; ripristinabile. Riavvia il gioco.'
}

function ExpansionCatalog {
 $ex='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
 $desktop='Control Panel\Desktop'
 $mouse='Control Panel\Mouse'
 $keyboard='Control Panel\Keyboard'
 $build=[int](Get-CimInstance Win32_OperatingSystem).BuildNumber
 $pc=Get-CimInstance Win32_ComputerSystem
 # Existing preference keys only: avoid blindly creating undocumented settings.
 $raw=@'
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowSuperHidden|0|Mantieni nascosti file protetti|Non mostra file protetti di sistema
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|AlwaysShowMenus|1|Menu classico quando supportato|Preferenza legacy
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowPreviewHandlers|1|Gestori anteprima Explorer|Preferenza anteprima
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|NavPaneExpandToCurrentFolder|1|Navigazione: espandi cartella attuale|Preferenza
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|NavPaneShowAllFolders|1|Navigazione: tutte le cartelle|Preferenza
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|NavPaneShowLibraries|1|Navigazione: Raccolte|Preferenza
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowTypeOverlay|1|Icona tipo su miniature|Preferenza
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|FolderContentsInfoTip|0|Descrizioni cartelle: off|Riduce informazioni al passaggio mouse
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowFolderSizeTip|0|Dimensioni nei suggerimenti: off|Preferenza
Explorer|Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_TrackDocs|0|Documenti recenti Jump List: off|Non cancella documenti
Visual|Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|ColorPrevalence|0|Colore accento barra e Start: off|Preferenza estetica
Visual|Software\Microsoft\Windows\DWM|ColorPrevalence|0|Colore accento bordi: off|Preferenza estetica
Input|Software\Microsoft\TabletTip\1.7|EnableTextPrediction|0|Tastiera touch: predizione off|Preferenza
Input|Software\Microsoft\TabletTip\1.7|EnableAutocorrection|0|Tastiera touch: autocorrezione off|Preferenza
Input|Software\Microsoft\TabletTip\1.7|EnableSpellchecking|0|Tastiera touch: ortografia off|Preferenza
Input|Software\Microsoft\TabletTip\1.7|EnableKeyAudioFeedback|0|Tastiera touch: suono off|Preferenza
Input|Software\Microsoft\Input\Settings|EnableHwkbTextPrediction|0|Tastiera fisica: suggerimenti off|Preferenza
Input|Software\Microsoft\Input\Settings|EnableHwkbAutocorrection|0|Tastiera fisica: correzione off|Preferenza
Input|Software\Microsoft\Input\Settings|MultilingualEnabled|0|Suggerimenti multilingue: off|Preferenza
Privacy|Software\Microsoft\Windows\CurrentVersion\Clipboard|EnableClipboardHistory|0|Cronologia appunti: off|Win+V non disponibile
Privacy|Software\Microsoft\Windows\CurrentVersion\Clipboard|EnableCloudClipboard|0|Sincronizzazione appunti: off|Copia locale resta
Gaming|Software\Microsoft\GameBar|UseNexusForGameBarEnabled|0|Tasto Xbox non apre Game Bar|Preferenza controller
Notifications|Software\Microsoft\Windows\CurrentVersion\Notifications\Settings|NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK|0|Notifiche normali sopra blocco: off|Privacy schermata blocco
'@
 foreach($line in ($raw -split '\r?\n')){
  if(!$line.Trim()){continue};$p=$line.Split('|')
  $v=ReadValue $p[1] $p[2];if(!$v.Exists -or $v.Kind -ne 'DWord'){continue}
  Make $p[4] $p[0] $p[1] $p[2] ([int]$p[3]) 'OptIn' ($p[5]+'; effetto dipende dalla build')
 }
 if($build -ge 22000){
  foreach($i in @(
   @('Badge app barra: off','TaskbarBadges',0),
   @('Lampeggi barra: off','TaskbarFlashing',0),
   @('Barra su tutti gli schermi','MMTaskbarEnabled',1),
   @('Barra secondaria: solo app schermo','MMTaskbarMode',2),
   @('Pulsante Chat legacy: off','TaskbarMn',0),
   @('Pulsante Copilot legacy: off','ShowCopilotButton',0),
   @('Secondi nella barra orologio','ShowSecondsInSystemClock',1)
  )){
   $v=ReadValue $ex $i[1];if($v.Exists -and $v.Kind -eq 'DWord'){Make $i[0] 'Taskbar' $ex $i[1] $i[2] 'OptIn' 'Preferenza utente, non FPS; build dipendente'}
  }
 }
 foreach($i in @(
  @('Mouse: sensibilita standard','Input',$mouse,'MouseSensitivity','10'),
  @('Mouse: doppio clic 500 ms','Input',$mouse,'DoubleClickSpeed','500'),
  @('Mouse: soglia doppio clic X','Input',$mouse,'DoubleClickWidth','4'),
  @('Mouse: soglia doppio clic Y','Input',$mouse,'DoubleClickHeight','4'),
  @('Mouse: hover 400 ms','Input',$mouse,'MouseHoverTime','400'),
  @('Mouse: scorrimento verticale 3','Input',$desktop,'WheelScrollLines','3'),
  @('Mouse: scorrimento orizzontale 3','Input',$desktop,'WheelScrollChars','3'),
  @('Tastiera: ripetizione rapida','Input',$keyboard,'KeyboardSpeed','31'),
  @('Tastiera: ritardo ripetizione medio','Input',$keyboard,'KeyboardDelay','1'),
  @('Desktop: wallpaper centrato','Visual',$desktop,'WallpaperStyle','0'),
  @('Desktop: sfondo non affiancato','Visual',$desktop,'TileWallpaper','0'),
  @('Desktop: trascina mostrando contenuto','Visual',$desktop,'DragFullWindows','1'),
  @('Desktop: cursore lampeggia 530 ms','Visual',$desktop,'CursorBlinkRate','530'),
  @('Desktop: salvaschermo 15 min','Visual',$desktop,'ScreenSaveTimeOut','900'),
  @('Desktop: lampeggio focus 3 volte','Visual',$desktop,'ForegroundFlashCount','3'),
  @('Desktop: bordo standard','Visual','Control Panel\Desktop\WindowMetrics','BorderWidth','-15'),
  @('Desktop: bordo aggiuntivo standard','Visual','Control Panel\Desktop\WindowMetrics','PaddedBorderWidth','-60')
 )){
  $v=ReadValue $i[2] $i[3];if($v.Exists -and $v.Kind -eq 'String'){MakeString $i[0] $i[1] $i[2] $i[3] $i[4] 'Preferenza Windows; puo richiedere nuovo accesso; non modifica latenza gioco'}
 }
 # Only on personal PCs; don't change microphone/camera/accessibility/security.
 if(!$pc.PartOfDomain){
 $cap='Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
 foreach($i in @(
  @('activity','Attivita fisica'),@('appDiagnostics','Diagnostica altre app'),@('appointments','Calendario'),@('contacts','Contatti'),@('email','Posta'),@('chat','Messaggi'),@('userAccountInformation','Dati account'),@('userDataTasks','Attivita e promemoria'),@('phoneCallHistory','Cronologia chiamate'),@('phoneCall','Chiamate'),@('documentsLibrary','Documenti'),@('musicLibrary','Musica'),@('picturesLibrary','Immagini'),@('videosLibrary','Video'),@('broadFileSystemAccess','Accesso esteso file'),@('location','Posizione'),@('userNotificationListener','Lettura notifiche da app'),@('systemAIModels','Modelli AI locali')
 )){
  $path="$cap\$($i[0])";$v=ReadValue $path 'Value'
  if($v.Exists -and $v.Kind -eq 'String' -and $v.Value -in @('Allow','Deny')){MakeString ('Permesso app: '+$i[1]+' off') 'App Privacy' $path 'Value' 'Deny' 'Puo limitare app che usano questa funzione; non blocca tutti i programmi desktop; ripristinabile'}
 }
 $policies=@(
  @('Taskbar.admx','NoBalloonFeatureAdvertisements','Suggerimenti funzionalita barra','Privacy'),
  @('Taskbar.admx','NoSystraySystemPromotion','Promozioni area notifiche','Debloat'),
  @('Taskbar.admx','TaskbarNoThumbnail','Anteprime barra: off','Taskbar'),
  @('Taskbar.admx','NoRemoteDestinations','Destinazioni remote Jump List: off','Privacy'),
  @('Taskbar.admx','TurnOffAbbreviatedDateTimeFormat','Data e ora estesa','Taskbar'),
  @('Taskbar.admx','AlwaysShowNotificationIcon','Icona notifiche visibile','Taskbar'),
  @('StartMenu.admx','ShowRunAsDifferentUserInStart','Mostra Esegui come altro utente','Explorer'),
  @('StartMenu.admx','HideCategoryView','Nascondi vista categorie Start','Taskbar'),
  @('WindowsExplorer.admx','HideContentViewModeSnippets','Nascondi estratti vista contenuto','Privacy'),
  @('WindowsExplorer.admx','NoStrCmpLogical','Ordinamento nomi lessicografico','Explorer'),
  @('Search.admx','DisableSearchHistory','Cronologia ricerca criterio utente','Privacy'),
  @('EdgeUI.admx','DisableHelpSticker','Suggerimenti interfaccia legacy','Debloat'),
  @('WindowsCopilot.admx','TurnOffWindowsCopilot','Copilot Windows legacy: off','Debloat'),
  @('WindowsCopilot.admx','DisableAIDataAnalysis','Recall: analisi dati AI off','Privacy'),
  @('WindowsCopilot.admx','DisableClickToDo','Click to Do: off','Privacy')
 )
 foreach($i in $policies){
  try{
   $file=Join-Path "$env:windir\PolicyDefinitions" $i[0];if(!(Test-Path -LiteralPath $file)){continue}
   [xml]$xml=Get-Content -LiteralPath $file -Raw
   $p=$xml.policyDefinitions.policies.policy|Where-Object {$_.name -eq $i[1] -and $_.class -in @('User','Both') -and $_.key -and $_.valueName -and $null -ne $_.enabledValue.decimal.value}|Select-Object -First 1
   if(!$p){continue};$v=ReadValue $p.key $p.valueName;if($v.Exists -and $v.Kind -ne 'DWord'){continue}
   Make $i[2] $i[3] $p.key $p.valueName ([int]$p.enabledValue.decimal.value) 'OptIn' 'Criterio utente ADMX locale; dipende da edizione/build; non usare su PC gestiti'
  }catch{}
 }
 $pf86=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
 $browsers=@(
  @{Name='Edge';Key='Software\Policies\Microsoft\Edge';Exe='msedge.exe';Dirs=@("$env:ProgramFiles\Microsoft\Edge\Application","$pf86\Microsoft\Edge\Application","$env:LOCALAPPDATA\Microsoft\Edge\Application")},
  @{Name='Chrome';Key='Software\Policies\Google\Chrome';Exe='chrome.exe';Dirs=@("$env:ProgramFiles\Google\Chrome\Application","$pf86\Google\Chrome\Application","$env:LOCALAPPDATA\Google\Chrome\Application")}
 )
 foreach($b in $browsers){
  $installed=$false;foreach($d in $b.Dirs){if(Test-Path -LiteralPath (Join-Path $d $b.Exe)){$installed=$true}}
  foreach($h in @('HKLM:','HKCU:')){if(Test-Path "$h\Software\Microsoft\Windows\CurrentVersion\App Paths\$($b.Exe)"){$installed=$true}}
  if(!$installed){continue}
  $rows=@(
   @('BackgroundModeEnabled',0,'Processi in background dopo chiusura'),
   @('SearchSuggestEnabled',0,'Suggerimenti online digitazione'),
   @('NetworkPredictionOptions',2,'Precaricamento rete'),
   @('AlternateErrorPagesEnabled',0,'Pagine errore alternative online'),
   @('SpellCheckServiceEnabled',0,'Controllo ortografico cloud'),
   @('ShowHomeButton',1,'Pulsante Home visibile'),
   @('BookmarkBarEnabled',1,'Barra preferiti visibile'),
   @('AutofillAddressEnabled',0,'Compilazione automatica indirizzi'),
   @('AutofillCreditCardEnabled',0,'Compilazione automatica carte'),
   @('TranslateEnabled',0,'Traduzione automatica')
  )
  if($b.Name -eq 'Edge'){
   $rows+=@(
    @('StartupBoostEnabled',0,'Avvio anticipato in background'),
    @('PersonalizationReportingEnabled',0,'Personalizzazione dati navigazione'),
    @('EdgeShoppingAssistantEnabled',0,'Assistente shopping'),
    @('NewTabPageContentEnabled',0,'Feed notizie nuova scheda'),
    @('NewTabPagePrerenderEnabled',0,'Precaricamento nuova scheda'),
    @('NewTabPageQuickLinksEnabled',0,'Collegamenti rapidi nuova scheda'),
    @('ShowRecommendationsEnabled',0,'Raccomandazioni funzionalita'),
    @('HubsSidebarEnabled',0,'Barra laterale'),
    @('MicrosoftEdgeInsiderPromotionEnabled',0,'Promozione Edge Insider'),
    @('EdgeEDropEnabled',0,'Condivisione Drop'),
    @('EdgeOpenInSidebarEnabled',0,'Apri nella barra laterale'),
    @('EdgeHistoryAISearchEnabled',0,'Ricerca AI cronologia'),
    @('MicrosoftEditorSynonymsEnabled',0,'Suggerimenti sinonimi cloud'),
    @('MouseGestureEnabled',0,'Gesti mouse')
   )
  }else{
   $rows+=@(
    @('MetricsReportingEnabled',0,'Statistiche utilizzo facoltative'),
    @('PromotionalTabsEnabled',0,'Schede promozionali'),
    @('UrlKeyedAnonymizedDataCollectionEnabled',0,'Raccolta URL anonimizzati')
   )
  }
  foreach($i in $rows){
   $v=ReadValue $b.Key $i[0];if($v.Exists -and $v.Kind -ne 'DWord'){continue}
   Make ($b.Name+': '+$i[2]) 'Browser' $b.Key $i[0] $i[1] 'OptIn' 'Criterio locale; puo mostrare Gestito dalla tua organizzazione. Richiede riavvio browser; non tocca sicurezza o aggiornamenti'
  }
 }
 }
 if($pc.PCSystemType -eq 1 -and !@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count){
  $plan=CurrentScheme
  foreach($i in @(
   @('Monitor: spegnimento dopo 20 min','7516b95f-f776-4464-8c53-06167f40cc99','3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e',1200,'Risparmio; non FPS'),
   @('Sospensione: dopo 60 min','238c9fa8-0aad-41ed-83f4-97be242c8f20','29f6c1db-86da-48c5-9fdb-f2b67b1f44da',3600,'Attenzione download e server'),
   @('Ibernazione: dopo 180 min','238c9fa8-0aad-41ed-83f4-97be242c8f20','9d7815a6-7ee4-497e-8888-515a05f02364',10800,'Solo se ibernazione disponibile')
  )){
   $path="POWER|$plan|$($i[1])";try{$old=PowerRead $path $i[2];$target=[pscustomobject]@{Exists=$true;Kind='DWord';Value=[int]$i[3]};[pscustomobject]@{Name=$i[0];Category='Power / CPU';Path=$path;Key=$i[2];TargetState=$target;Before=(Display $old);After=(Display $target);Status=$(if(Same $old $target){'GIA CONFIGURATO'}else{'DISPONIBILE'});Level='OptIn';Note=$i[4]+'; solo desktop AC';Selected=$false}}catch{}
  }
 }
 $np='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
 $rk=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($np)
 if($rk){try{
  foreach($id in $rk.GetSubKeyNames()){
   if($id -notmatch '(?i)Discord|Spotify|Steam|EpicGames|Battle\.net|Telegram|WhatsApp|Chrome|Firefox|Brave|Vivaldi|Opera|Twitch|Xbox|GameBar|Teams|Outlook|Microsoft\.GamingApp|Medal|Riot|Nexus|CurseForge'){continue}
   if($id -match '(?i)Security|Defender|Update|Firewall'){continue}
   $path="$np\$id";$v=ReadValue $path 'Enabled'
   if(!$v.Exists -or $v.Kind -eq 'DWord'){Make ('Notifiche app: '+$id) 'App Notifications' $path 'Enabled' 0 'OptIn' 'Disattiva notifiche di questa app; potresti perdere messaggi; non disinstalla'}
  }
 }finally{$rk.Dispose()}}
}

function RawCatalog{
 $cd='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
 $ex='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
 Make 'Windows Game Mode' 'Gaming' 'Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'Gaming' 'Attiva Game Mode; beneficio dipende dal gioco'
 Make 'Registrazione game in background' 'Gaming' 'Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 'OptIn' 'Disabilita cattura Windows; non modifica Medal'
 Make 'Suggerimenti e app promosse' 'Debloat' $cd 'SilentInstalledAppsEnabled' 0 'Safe' 'Preferenza utente; il supporto varia per build'
 Make 'Contenuti suggeriti' 'Debloat' $cd 'ContentDeliveryAllowed' 0 'Safe' 'Preferenza utente per contenuti promossi; verifica dopo aggiornamenti'
 Make 'Suggerimenti in Impostazioni' 'Debloat' $cd 'SubscribedContent338393Enabled' 0 'Safe' 'Preferenza utente; effetto dipende dalla versione'
 Make 'Suggerimenti Windows' 'Debloat' $cd 'SubscribedContent338389Enabled' 0 'Safe' 'Preferenza utente; effetto dipende dalla versione'
 Make 'Pubblicita in Esplora file' 'Debloat' $ex 'ShowSyncProviderNotifications' 0 'Safe' 'Riduce notifiche promozionali del provider di sincronizzazione'
 Make 'Esperienze personalizzate' 'Privacy' 'Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'Safe' 'Non disattiva la diagnostica obbligatoria'
 $os=Get-CimInstance Win32_OperatingSystem
 if([int]$os.BuildNumber -ge 22000){Make 'Pulsante Widget nella barra' 'Debloat' $ex 'TaskbarDa' 0 'OptIn' 'Nasconde il pulsante; non rimuove componenti'}
# Additional per-user preferences. Opt-in for behavior changes.
 Make 'Privacy ID pubblicitario' 'Privacy' 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'Safe' 'Disabilita ID pubblicitario utente'
 Make 'Suggerimenti schermata di benvenuto' 'Debloat' $cd 'SubscribedContent310093Enabled' 0 'Safe' 'Preferenza per esperienze di benvenuto'
 Make 'Suggerimenti in Timeline' 'Debloat' $cd 'SubscribedContent338388Enabled' 0 'Safe' 'Preferenza contenuti suggeriti'
 Make 'Suggerimenti in Start' 'Debloat' $cd 'SystemPaneSuggestionsEnabled' 0 'Safe' 'Preferenza; dipende dalla build'
 Make 'Suggerimenti post configurazione' 'Debloat' 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 'Safe' 'Riduce inviti a completare la configurazione'
 Make 'Notifiche suggerimenti' 'Debloat' 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0 'Safe' 'Solo notifiche di suggerimenti'
 Make 'Feedback richiesto' 'Privacy' 'Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0 'OptIn' 'Preferenza frequenza feedback; non blocca telemetria obbligatoria'
 Make 'Risultati web nella ricerca Start' 'Privacy' 'Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 'OptIn' 'Preferenza ricerca; policy e supporto dipendono dalla build'
 Make 'Trasparenza interfaccia' 'Visual' 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 'Gaming' 'Riduce effetti visivi; nessuna promessa FPS'
 Make 'Animazioni barra applicazioni' 'Visual' $ex 'TaskbarAnimations' 0 'Gaming' 'Riduce animazioni shell'
 Make 'Estensioni file visibili' 'Explorer' $ex 'HideFileExt' 0 'Safe' 'Mostra estensioni dei file; sicurezza e usabilita'
 Make 'File nascosti visibili' 'Explorer' $ex 'Hidden' 1 'OptIn' 'Mostra file nascosti; non mostra file protetti di sistema'
 Make 'Apertura Esplora file: Questo PC' 'Explorer' $ex 'LaunchTo' 1 'OptIn' 'Preferenza navigazione'
 Make 'File recenti in Home' 'Privacy' 'Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0 'OptIn' 'Non mostra file recenti in Home'
 Make 'Cartelle frequenti in Home' 'Privacy' 'Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0 'OptIn' 'Non mostra cartelle frequenti in Home'
 Make 'Cronologia app avviate' 'Privacy' $ex 'Start_TrackProgs' 0 'OptIn' 'Influisce sui suggerimenti basati sulle app'
 Make 'Evidenziazioni ricerca' 'Debloat' 'Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0 'Safe' 'Riduce contenuti dinamici della ricerca'
 Make 'Icona Task View' 'Visual' $ex 'ShowTaskViewButton' 0 'OptIn' 'Nasconde solo il pulsante; Win+Tab resta disponibile'
 Make 'Tema app scuro' 'Visual' 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0 'OptIn' 'Preferenza tema Windows, non impone tema a tutte le app'
 Make 'Tema sistema scuro' 'Visual' 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0 'OptIn' 'Preferenza tema Windows'
 Make 'Cattura gioco Game DVR' 'Gaming' 'System\GameConfigStore' 'GameDVR_Enabled' 0 'OptIn' 'Disabilita cattura Windows; scegliere solo se non usata'
 if([int]$os.BuildNumber -ge 22000){
  Make 'Barra applicazioni: ricerca nascosta' 'Visual' 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0 'OptIn' 'Ricerca da Start resta disponibile'
  Make 'Allineamento barra a sinistra' 'Visual' $ex 'TaskbarAl' 0 'OptIn' 'Solo preferenza estetica'
 }

 AdditionalCatalog
 MoreCatalog
 ExpansionCatalog
 $run='Software\Microsoft\Windows\CurrentVersion\Run'
 $allow=@('Discord','Steam','Spotify','EpicGamesLauncher','Epic Games Launcher','Battle.net','EADM','electron.app.CurseForge','WallpaperEngine','Opera Stable','RiotClient','electron.app.BlueStacks Services')
 foreach($name in $allow){
  $old=ReadValue $run $name
  if($old.Exists -and $old.Kind -in @('String','ExpandString')){
   [pscustomobject]@{Name="Avvio: $name";Category='Startup';Path=$run;Key=$name;TargetState=[pscustomobject]@{Exists=$false;Kind='';Value=$null};Before='Attivo in Run';After='Rimosso da Run';Status='DISPONIBILE';Level='OptIn';Note='App resta installata; non chiude processi; avvio automatico da altre fonti possibile';Selected=$false}
  }
 }
}
function GetPWU($row){
 $rank=1;$why='Preferenza, privacy o usabilita; impatto prestazioni generalmente minimo o non misurato.'
 if($row.Category -eq 'Startup'){
  $rank=2;$why='Potenziale risparmio di RAM/CPU e tempo di avvio se questa app parte e resta attiva. Non chiude processi gia aperti.'
 }elseif($row.Category -eq 'Gaming' -and $row.Key -in @('AutoGameModeEnabled','AppCaptureEnabled','GameDVR_Enabled')){
  $rank=2;$why='Possibile beneficio durante il gioco, soprattutto se la cattura in background e realmente attiva; dipende dal carico.'
 }elseif($row.Category -eq 'Browser' -and $row.Key -in @('BackgroundModeEnabled','StartupBoostEnabled','NetworkPredictionOptions','NewTabPagePrerenderEnabled')){
  $rank=2;$why='Possibile riduzione dei processi o del precaricamento del browser; dipende da utilizzo e RAM.'
 }elseif($row.Path.StartsWith('POWER|')){
  if($row.Key -eq 'bc5038f7-23e0-4960-96da-33abaf5935ec'){
   $n=0
   if([int]::TryParse([string]$row.Before,[ref]$n) -and $n -le 80 -and $n -gt 0){
    $rank=3;$why='Potenziale elevato se la CPU e limitata a 80% o meno e il carico e CPU-bound; maggior calore e consumo. Non e una misura FPS.'
   }else{$rank=2;$why='Rimuove un eventuale limite CPU; beneficio solo se il limite riduce le prestazioni.'}
  }elseif($row.Key -in @('be337238-0d82-4146-a960-4f3749d470c7','36687f9e-e3a5-4dbf-b1dc-15eb381c6863')){
   $rank=2;$why='Possibile variazione di reattivita CPU; dipende da hardware, firmware e temperature. Puo aumentare i consumi.'
  }else{$why='Preferenza energetica o risparmio; beneficio prestazioni non garantito e possibili consumi maggiori.'}
 }elseif($row.Key -in @('EnableTransparency','TaskbarAnimations','MinAnimate','IconsOnly','ShowPreviewHandlers')){
  $why='Riduce o modifica effetti della shell; impatto soprattutto sulla UI, non sugli FPS del gioco.'
 }
 $label=@('','Low','Medium','High')[$rank]
 [pscustomobject]@{Rank=$rank;Label=$label;Reason=$why}
}
function Catalog{
 foreach($r in @(RawCatalog)){
  $p=GetPWU $r
  $r|Add-Member NoteProperty PWU $p.Label -Force
  $r|Add-Member NoteProperty PWURank $p.Rank -Force
  $r|Add-Member NoteProperty PWUReason $p.Reason -Force
  $r
 }
}
function Inventory{
 $os=Get-CimInstance Win32_OperatingSystem
 $cpu=Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
 $gpu=Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,CurrentRefreshRate
 $disk=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'|ForEach-Object {[pscustomobject]@{Drive=$_.DeviceID;FreeGiB=[math]::Round($_.FreeSpace/1GB,1);FreePct=[math]::Round(100*$_.FreeSpace/[math]::Max([double]1,[double]$_.Size),1)}}
 $apps=@(Get-AppxPackage|Where-Object {!$_.IsFramework -and !$_.NonRemovable}|Select-Object Name,PackageFullName)
 [ordered]@{Time=(Get-Date).ToString('o');Windows=$os.Caption;Build=$os.BuildNumber;CPU=@($cpu);GPU=@($gpu);RAMGiB=[math]::Round($os.TotalVisibleMemorySize/1MB,1);FreeRAMGiB=[math]::Round($os.FreePhysicalMemory/1MB,1);PowerPlan=((& powercfg /getactivescheme)|Out-String).Trim();Disks=@($disk);Startup=@(Get-CimInstance Win32_StartupCommand|Select-Object Name,Location);HeavyRAM=@(Get-Process|Sort-Object WorkingSet64 -Descending|Select-Object -First 12 ProcessName,WorkingSet64);OptionalApps=$apps;Network=@(Get-NetAdapter -ErrorAction SilentlyContinue|Select-Object Name,Status,LinkSpeed);Notes='Analisi locale; non identifica da sola colli di bottiglia o incremento FPS.'}
}
function SaveScan{
 $items=@(Catalog);$inv=Inventory
 $file=Join-Path $root ('scan-'+[guid]::NewGuid().ToString()+'.json')
 Atomic $file @{Inventory=$inv;Findings=@($items|Select-Object Name,Category,Before,After,Status,PWU,PWUReason,Note)}
 $file
}
function OptionalPackages {
 $allow=@('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsFeedbackHub','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.WindowsMaps','Microsoft.MicrosoftOfficeHub','Clipchamp.Clipchamp','Microsoft.ZuneMusic','Microsoft.ZuneVideo','MSTeams','Microsoft.Todos','Microsoft.YourPhone','Microsoft.WindowsSoundRecorder','Microsoft.WindowsAlarms','Microsoft.PowerAutomateDesktop','Microsoft.Windows.DevHome','Microsoft.MicrosoftStickyNotes','MicrosoftCorporationII.QuickAssist','Microsoft.Copilot','Microsoft.BingSearch','Microsoft.Microsoft3DViewer','Microsoft.MSPaint','Microsoft.MixedReality.Portal','Microsoft.Print3D','Microsoft.SkypeApp','Microsoft.People','Microsoft.WindowsCamera','Microsoft.Windows.Photos','Microsoft.WindowsCalculator','Microsoft.WindowsNotepad','Microsoft.Paint','Microsoft.WindowsReadingList')
 @(Get-AppxPackage | Where-Object {$_.Name -in $allow -and !$_.IsFramework -and !$_.NonRemovable} | Sort-Object Name)
}
function RemoveOptionalApps {
 $packages=@(OptionalPackages)
 if(!$packages.Count){$status.Text='Nessuna app opzionale rilevata';return}
 $dlg=New-Object Windows.Window
 $dlg.Background='#0B1220';$dlg.Foreground='#E3ECF9';$dlg.Resources.MergedDictionaries.Add($w.Resources);SetDarkChrome $dlg;$dlg.Title='Debloat app opzionali - selezione manuale';$dlg.Width=640;$dlg.Height=440;$dlg.Owner=$w;$dlg.WindowStartupLocation='CenterOwner'
 $panel=New-Object Windows.Controls.DockPanel;$panel.Margin='12'
 $note=New-Object Windows.Controls.TextBlock;$note.Text='Seleziona solo app che non usi. Rimozione per utente corrente: dati e preferenze possono andare persi. Il ripristino automatico non e garantito.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,10'
 [Windows.Controls.DockPanel]::SetDock($note,'Top');$null=$panel.Children.Add($note)
 $btn=New-Object Windows.Controls.Button;$btn.Content='Rimuovi selezionate';$btn.Padding='12';[Windows.Controls.DockPanel]::SetDock($btn,'Bottom');$null=$panel.Children.Add($btn)
 $lb=New-Object Windows.Controls.ListBox;$lb.SelectionMode='Multiple';$lb.DisplayMemberPath='Name';$lb.ItemsSource=$packages;$null=$panel.Children.Add($lb)
 $dlg.Content=$panel
 $btn.Add_Click({if($lb.SelectedItems.Count){$dlg.DialogResult=$true}})
 if($dlg.ShowDialog() -ne $true){return}
 $chosen=@($lb.SelectedItems | ForEach-Object {$_})
 $preview=($chosen|ForEach-Object Name)-join [Environment]::NewLine
 if(!(ConfirmDark 'Conferma disinstallazione' "Disinstallare queste app per l'utente corrente? Il ripristino non e automatico e i dati potrebbero andare persi.$([Environment]::NewLine)$preview")){return}
 $ok=0;$fail=0
 foreach($app in $chosen){
  try{
   $name=$app.Name
   $current=@(OptionalPackages|Where-Object PackageFullName -eq $app.PackageFullName)
   if(!$current.Count){throw 'Pacchetto non piu disponibile'}
   Event $name 'Installato' 'In attesa' 'RIMOZIONE RICHIESTA'
   Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
   if(Get-AppxPackage -Name $name){throw 'Pacchetto ancora presente'}
   Event $name 'Installato' 'Rimosso per utente corrente' 'VERIFICATO - reinstallazione manuale Store';$ok++
  }catch{Event $app.Name 'Installato' '?' ('ERRORE: '+$_.Exception.Message);$fail++}
 }
 UpdateLog;$w.FindName('Tabs').SelectedIndex=2;$status.Text="App rimosse: $ok; errori: $fail. Per reinstallazione usare Microsoft Store; dati non garantiti."
}

if($SelfTest){
 $test='Software\BrabusPC-Test-'+[guid]::NewGuid().ToString()
 $tmp=Join-Path $env:TEMP ('BrabusTest-'+[guid]::NewGuid().ToString())
 $null=New-Item -ItemType Directory $tmp
  $backupDir=$tmp;$legacyJournal=Join-Path $tmp 'legacy.json';$journal=Join-Path $tmp 'active.json';$mirror=Join-Path $tmp 'mirror.json';$log=Join-Path $tmp 'log.jsonl'
 try{
  $one=Make 'Test' 'Test' $test 'Missing' 1 'Safe' 'test'
  ApplyValue $one
  $two=Make 'Test2' 'Test' $test 'Second' 0 'Safe' 'test'
  ApplyValue $two
  if(@(ReadJournal).Count -ne 2){throw 'Journal'}
  if((ReadValue $test 'Missing').Value -ne 1){throw 'Write'}
  RestoreAll
  if((ReadValue $test 'Missing').Exists -or (ReadValue $test 'Second').Exists -or @(ReadJournal).Count){throw 'Restore'}
  $testCatalog=@(Catalog);if($testCatalog.Count -lt 65){throw "Catalog expansion missing"};if(@($testCatalog|Group-Object Path,Key|Where-Object Count -gt 1).Count){throw "Duplicate catalog keys"}
   if(@($testCatalog|Where-Object {$_.PWU -notin @('Low','Medium','High') -or $_.PWURank -notin @(1,2,3) -or !$_.PWUReason}).Count){throw 'Invalid PWU'}
 $probe=[pscustomobject]@{Category='Power / CPU';Path='POWER|test';Key='bc5038f7-23e0-4960-96da-33abaf5935ec';Before='60'}
 if((GetPWU $probe).Label -ne 'High'){throw 'Conditional High rating failed'}
 $testCatalog|Group-Object PWU|ForEach-Object {Write-Output ("PWU "+$_.Name+": "+$_.Count)}
  Write-Output ("PASS registry test keys, two backups, verification, rollback, catalog: "+$testCatalog.Count); $testCatalog|Group-Object Category|Sort-Object Name|ForEach-Object {Write-Output ($_.Name+": "+$_.Count)}
 }finally{[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($test,$false);Remove-Item -LiteralPath $tmp -Recurse -Force}
 exit 0
}
$mutexName=if($UiTest){"Local\BrabusPCDebloater-UiTest-"+[guid]::NewGuid().ToString()}else{'Local\BrabusPCDebloater'};$mutex=New-Object Threading.Mutex($false,$mutexName)
try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
if(!$locked){throw 'Debloater gia aperto'}
try{
if(!$UiTest -and !$Scan){MigrateLegacy}; if($Undo){RestoreAll;Write-Output 'Ripristino completato';exit 0}
if($Scan){SaveScan;exit 0}
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BrabusDwm {
 [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd,int attr,ref int value,int size);
}
"@
[xml]$x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="BRABUS UTIL | ONE-SHOT DEBLOATER" Width="1280" Height="820" MinWidth="970" MinHeight="650" Background="#080D16" Foreground="#DCE9FC" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
<Window.Resources>
<SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#101B2A"/>
<SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E3ECF9"/>
<SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#17283C"/>
<SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#E3ECF9"/>
<SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#174862"/>
<SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>
<Style TargetType="TextBlock"><Setter Property="Foreground" Value="#DCE9FC"/></Style>
<Style TargetType="Button">
<Setter Property="Background" Value="#17283C"/><Setter Property="Foreground" Value="#DCE9FC"/><Setter Property="Padding" Value="14,10"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="BorderBrush" Value="#29445F"/>
<Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#24435B"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#126480"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value=".45"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5CE1F5"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E3ECF9"/><Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><StackPanel Orientation="Horizontal"><Border x:Name="cb" Width="18" Height="18" Background="#0C1726" BorderBrush="#52718A" BorderThickness="1" CornerRadius="3"><Path x:Name="tick" Data="M 3,9 L 7,13 L 15,4" Stroke="#071521" StrokeThickness="2.5" Visibility="Collapsed"/></Border><ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center"/></StackPanel><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="cb" Property="Background" Value="#43D7E8"/><Setter TargetName="tick" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value=".5"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType="TextBox"><Setter Property="Background" Value="#101B2A"/><Setter Property="Foreground" Value="#E3ECF9"/><Setter Property="CaretBrush" Value="#43D7E8"/><Setter Property="SelectionBrush" Value="#24758D"/><Setter Property="BorderBrush" Value="#29445F"/><Setter Property="Padding" Value="9"/></Style>
<Style TargetType="TabControl"><Setter Property="Background" Value="#0E1928"/><Setter Property="BorderBrush" Value="#253B50"/><Setter Property="Padding" Value="6"/></Style>
<Style TargetType="TabItem"><Setter Property="Foreground" Value="#9EB5CC"/><Setter Property="Background" Value="#111F32"/><Setter Property="Padding" Value="14,9"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem"><Border x:Name="tab" Background="{TemplateBinding Background}" BorderBrush="#253B50" BorderThickness="1" CornerRadius="5,5,0,0" Padding="{TemplateBinding Padding}" Margin="2,0"><ContentPresenter ContentSource="Header"/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="tab" Property="Background" Value="#173A50"/><Setter Property="Foreground" Value="#5CE1F5"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tab" Property="BorderBrush" Value="#43D7E8"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType="DataGrid"><Setter Property="Background" Value="#0D1725"/><Setter Property="Foreground" Value="#DCE9FC"/><Setter Property="RowBackground" Value="#111F30"/><Setter Property="AlternatingRowBackground" Value="#152539"/><Setter Property="BorderBrush" Value="#253B50"/><Setter Property="GridLinesVisibility" Value="Horizontal"/><Setter Property="HorizontalGridLinesBrush" Value="#24384E"/><Setter Property="HeadersVisibility" Value="Column"/><Setter Property="RowHeight" Value="36"/><Setter Property="ColumnHeaderHeight" Value="39"/></Style>
<Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#20354A"/><Setter Property="Foreground" Value="#99DDE8"/><Setter Property="BorderBrush" Value="#29445F"/><Setter Property="BorderThickness" Value="0,0,1,1"/><Setter Property="Padding" Value="8"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
<Style TargetType="DataGridRow"><Setter Property="Foreground" Value="#DCE9FC"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#174862"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></Style.Triggers></Style>
<Style TargetType="DataGridCell"><Setter Property="Foreground" Value="#DCE9FC"/><Setter Property="Padding" Value="6"/><Setter Property="BorderThickness" Value="0"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#174862"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></Style.Triggers></Style>
<Style TargetType="ListBox"><Setter Property="Background" Value="#101B2A"/><Setter Property="Foreground" Value="#E3ECF9"/><Setter Property="BorderBrush" Value="#29445F"/></Style>
<Style TargetType="ListBoxItem"><Setter Property="Foreground" Value="#E3ECF9"/><Setter Property="Padding" Value="8"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#174862"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></Style.Triggers></Style>
<Style TargetType="ScrollBar"><Setter Property="Background" Value="#0D1725"/><Setter Property="Width" Value="13"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="#0D1725"><Track x:Name="PART_Track" IsDirectionReversed="True"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Background="Transparent" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#3B5A72" CornerRadius="4" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Background="Transparent" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton></Track></Grid><ControlTemplate.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="13"/></Trigger></Style.Triggers></Style>
</Window.Resources>
<Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<Border Background="#111F32" CornerRadius="12" Padding="17"><DockPanel><StackPanel DockPanel.Dock="Right" VerticalAlignment="Center"><TextBlock Text="CONTROL CENTER  /  1.7 NETWORK" Foreground="#5CE1F5" FontWeight="Bold"/><TextBlock Text="LOCAL  |  NO AI  |  NO RESIDENT PROCESS" FontSize="11" Foreground="#9EB5CC"/></StackPanel><StackPanel><TextBlock Text="BRABUS / UTIL" FontSize="34" Foreground="#43D7E8" FontWeight="Bold"/><TextBlock Text="ONE-SHOT DEBLOATER  /  SCAN - APPLY - VERIFY - CLOSE" Foreground="#9EB5CC"/><TextBlock Name="Hardware" Foreground="#DCE9FC" TextWrapping="Wrap" Margin="0,6,0,0"/></StackPanel></DockPanel></Border>
<Grid Grid.Row="1" Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
<Border Background="#122236" CornerRadius="8" Padding="12" Margin="0,0,6,0"><StackPanel><TextBlock Text="CATALOGO COMPATIBILE" Foreground="#9EB5CC" FontSize="11"/><TextBlock Name="Total" Text="--" FontSize="24" FontWeight="Bold" Foreground="#43D7E8"/></StackPanel></Border>
<Border Grid.Column="1" Background="#122236" CornerRadius="8" Padding="12" Margin="3,0"><StackPanel><TextBlock Text="MARGINI DI INTERVENTO" Foreground="#9EB5CC" FontSize="11"/><TextBlock Name="Available" Text="--" FontSize="24" FontWeight="Bold" Foreground="#F4C77B"/></StackPanel></Border>
<Border Grid.Column="2" Background="#122236" CornerRadius="8" Padding="12" Margin="6,0,0,0"><StackPanel><TextBlock Text="GIA CONFIGURATI" Foreground="#9EB5CC" FontSize="11"/><TextBlock Name="Done" Text="--" FontSize="24" FontWeight="Bold" Foreground="#73E6AE"/></StackPanel></Border><Border Grid.Column="3" Background="#122236" CornerRadius="8" Padding="12" Margin="6,0,0,0"><StackPanel><TextBlock Text="RIPRISTINI IN BACKUP" Foreground="#9EB5CC" FontSize="11"/><TextBlock Name="Pending" Text="--" FontSize="24" FontWeight="Bold" Foreground="#A9C9FA"/></StackPanel></Border>
</Grid>
<Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="295"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Border Background="#111F32" CornerRadius="10" Padding="9" Margin="0,0,10,0"><DockPanel><StackPanel DockPanel.Dock="Top">
<TextBlock Text="01 / PRESET" Foreground="#43D7E8" FontWeight="Bold" Margin="4,4,0,8"/>
<UniformGrid Columns="2"><UniformGrid.Resources><Style TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Padding" Value="5,4"/><Setter Property="Margin" Value="2"/><Setter Property="FontSize" Value="11"/></Style></UniformGrid.Resources><Button Name="Scan" Content="ANALIZZA PC"/><Button Name="Safe" Content="SAFE"/><Button Name="Gaming" Content="GAMING"/><Button Name="Ultimate" Content="ULTIMATE"/><Button Name="SelectAll" Content="SELEZIONA TUTTO" Background="#0C7189"/><Button Name="Clear" Content="DESELEZIONA TUTTO"/><Button Name="Export" Content="ESPORTA PRESET"/><Button Name="Import" Content="IMPORTA PRESET"/></UniformGrid>
<TextBlock Text="02 / CATEGORIE TWEAK" Foreground="#43D7E8" FontWeight="Bold" Margin="4,9,0,5"/><ListBox Name="CategoryList" Margin="1,0,1,3" Background="Transparent" BorderThickness="0" ScrollViewer.VerticalScrollBarVisibility="Disabled" ScrollViewer.HorizontalScrollBarVisibility="Disabled"><ListBox.ItemsPanel><ItemsPanelTemplate><UniformGrid Columns="2"/></ItemsPanelTemplate></ListBox.ItemsPanel><ListBox.ItemContainerStyle><Style TargetType="ListBoxItem"><Setter Property="Margin" Value="2"/><Setter Property="Padding" Value="5,3"/><Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="FontSize" Value="11"/><Setter Property="Foreground" Value="#DCE9FC"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="cat" Background="#17283C" BorderBrush="#29445F" BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="cat" Property="Background" Value="#126480"/><Setter TargetName="cat" Property="BorderBrush" Value="#43D7E8"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="cat" Property="BorderBrush" Value="#43D7E8"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle></ListBox></StackPanel><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel><TextBlock Text="03 / STRUMENTI" Foreground="#43D7E8" FontWeight="Bold" Margin="4,16,0,8"/>
<Button Name="Debloat" Content="RIMUOVI APP OPZIONALI"/><Button Name="Apps" Content="APP INSTALLATE"/><Button Name="Startup" Content="AVVIO WINDOWS"/><Button Name="Power" Content="PIANI ENERGETICI"/><Button Name="Storage" Content="ARCHIVIAZIONE"/><Button Name="Graphics" Content="GRAFICA WINDOWS"/><Button Name="GpuApp" Content="GPU PER GIOCO"/><Button Name="Software" Content="SOFTWARE CENTER"/><Button Name="Features" Content="FUNZIONALITA WINDOWS"/><Button Name="Services" Content="SERVIZI WINDOWS"/><Button Name="Diag" Content="DIAGNOSTICA AVANZATA"/><Button Name="Updates" Content="WINDOWS UPDATE"/><Button Name="Audio" Content="AUDIO E NOTIFICHE"/><Button Name="Network" Content="NETWORK CENTER" Background="#0C7189"/>
<TextBlock Text="04 / RIPRISTINO" Foreground="#43D7E8" FontWeight="Bold" Margin="4,16,0,8"/>
<Button Name="Backup" Content="BACKUP &amp; RECOVERY CENTER"/><Button Name="Undo" Content="RIPRISTINA TUTTI I TWEAK"/><Button Name="Files" Content="LOG E REPORT"/>
<TextBlock Text="Defender, firewall, UAC e aggiornamenti intatti." Foreground="#73E6AE" TextWrapping="Wrap" Margin="4,12,0,0" FontSize="12"/>
</StackPanel></ScrollViewer></DockPanel></Border>
<TabControl Grid.Column="1" Name="Tabs"><TabItem Header="IMPOSTAZIONI"><DockPanel Margin="6"><Border DockPanel.Dock="Bottom" Background="#17283C" Padding="12" CornerRadius="6" Margin="0,8,0,0"><TextBlock Name="TweakDetail" Text="Seleziona una voce per vedere i dettagli." TextWrapping="Wrap" MinHeight="45"/></Border><StackPanel DockPanel.Dock="Top" Margin="0,0,0,8"><DockPanel><Button DockPanel.Dock="Right" Name="SelectPage" Content="SELEZIONA VISIBILI"/><TextBlock Name="CategoryTitle" Text="IMPOSTAZIONI / Tutte" FontSize="21" FontWeight="Bold" Foreground="#43D7E8" VerticalAlignment="Center"/></DockPanel><TextBlock Text="RICERCA / nome, categoria, stato, descrizione o chiave" Foreground="#9EB5CC" FontSize="11"/><TextBox Name="Filter" Margin="0,4,0,5"/>
<WrapPanel Margin="0,0,0,3"><TextBlock Text="PWU" FontWeight="Bold" Foreground="#43D7E8" VerticalAlignment="Center" Margin="0,0,6,0"/><Button Name="PWUAll" Content="Tutti" Padding="8,4" Margin="2"/><Button Name="PWULow" Content="Low" Padding="8,4" Margin="2"/><Button Name="PWUMedium" Content="Medium" Padding="8,4" Margin="2"/><Button Name="PWUHigh" Content="High" Padding="8,4" Margin="2"/><TextBlock Text="STATO" Foreground="#9EB5CC" VerticalAlignment="Center" Margin="10,0,5,0"/><Button Name="StateAll" Content="Tutti" Padding="8,4" Margin="2"/><Button Name="StateAvailable" Content="Disponibili" Padding="8,4" Margin="2"/><Button Name="StateDone" Content="Configurati" Padding="8,4" Margin="2"/><Button Name="StateSelected" Content="Selezionati" Padding="8,4" Margin="2"/><Button Name="ResetFilters" Content="RESET" Padding="8,4" Margin="2"/></WrapPanel><DockPanel><TextBlock Name="FilterCount" Foreground="#AFC9DF" VerticalAlignment="Center" DockPanel.Dock="Right"/><TextBlock Text="PWU: impatto potenziale, non benchmark. Clicca la colonna per ordinare." Foreground="#9EB5CC" FontSize="11" TextWrapping="Wrap"/></DockPanel></StackPanel><DataGrid Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" SelectionMode="Extended" EnableRowVirtualization="True"><DataGrid.Columns><DataGridTemplateColumn Header="ON" Width="46"><DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Selected,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn><DataGridTextColumn Header="Categoria" Binding="{Binding Category}" IsReadOnly="True" Width="90"/><DataGridTemplateColumn Header="PWU" SortMemberPath="PWURank" CanUserSort="True" IsReadOnly="True" Width="78"><DataGridTemplateColumn.CellTemplate><DataTemplate><Border CornerRadius="4" Padding="4,2" HorizontalAlignment="Center" VerticalAlignment="Center" ToolTip="{Binding PWUReason}"><Border.Style><Style TargetType="Border"><Setter Property="Background" Value="#28394C"/><Style.Triggers><DataTrigger Binding="{Binding PWU}" Value="Medium"><Setter Property="Background" Value="#78521D"/></DataTrigger><DataTrigger Binding="{Binding PWU}" Value="High"><Setter Property="Background" Value="#175A46"/></DataTrigger></Style.Triggers></Style></Border.Style><TextBlock Text="{Binding PWU}" FontWeight="SemiBold" FontSize="11" Foreground="#F2F6FC"/></Border></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn><DataGridTextColumn Header="Modifica" Binding="{Binding Name}" IsReadOnly="True" Width="230"/><DataGridTextColumn Header="Prima" Binding="{Binding Before}" IsReadOnly="True" Width="100"/><DataGridTextColumn Header="Dopo" Binding="{Binding After}" IsReadOnly="True" Width="100"/><DataGridTextColumn Header="Stato" Binding="{Binding Status}" IsReadOnly="True" Width="135"/><DataGridTextColumn Header="Spiegazione" Binding="{Binding Note}" IsReadOnly="True" Width="*"/></DataGrid.Columns></DataGrid></DockPanel></TabItem><TabItem Header="REPORT PC"><TextBox Name="Report" IsReadOnly="True" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/></TabItem><TabItem Header="CHANGE LOG"><TextBox Name="History" IsReadOnly="True" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/></TabItem><TabItem Header="CONTROL CENTER"><DockPanel Margin="8">
<Border DockPanel.Dock="Top" Background="#14283B" Padding="16" CornerRadius="8" Margin="0,0,0,10"><StackPanel>
<TextBlock Name="PageTitle" Text="CONTROL CENTER" FontSize="26" FontWeight="Bold" Foreground="#43D7E8"/>
<TextBlock Name="PageHint" Text="Apri uno strumento dal menu a sinistra." Foreground="#AFC9DF" TextWrapping="Wrap" Margin="0,6,0,8"/>
<DockPanel><Button DockPanel.Dock="Right" Name="PageRefresh" Content="AGGIORNA"/><TextBlock DockPanel.Dock="Right" Name="PageCount" VerticalAlignment="Center" Margin="10,0"/><TextBox Name="PageSearch" Margin="0,4,0,4"/></DockPanel>
</StackPanel></Border>
<Border DockPanel.Dock="Bottom" Background="#14283B" Padding="12" CornerRadius="8" Margin="0,10,0,0"><StackPanel>
<TextBlock Text="DETTAGLIO SELEZIONE" Foreground="#43D7E8" FontWeight="Bold"/><TextBox Name="PageDetail" IsReadOnly="True" TextWrapping="Wrap" MinHeight="60" MaxHeight="115" VerticalScrollBarVisibility="Auto" Margin="0,5,0,5"/>
<WrapPanel HorizontalAlignment="Right"><Button Name="PageCategory" Content="APRI IMPOSTAZIONI CORRELATE" Visibility="Collapsed"/><Button Name="PageAction" Content="" Visibility="Collapsed" Background="#0C7189"/></WrapPanel>
</StackPanel></Border>
<DataGrid Name="PageGrid" IsReadOnly="True" SelectionMode="Extended" AutoGenerateColumns="False" CanUserAddRows="False" EnableRowVirtualization="True"><DataGrid.Columns>
<DataGridTextColumn Header="Elemento" Binding="{Binding Name}" Width="2*"/><DataGridTextColumn Header="Stato / Valore" Binding="{Binding State}" Width="*"/><DataGridTextColumn Header="Informazioni" Binding="{Binding Detail}" Width="3*"/>
</DataGrid.Columns></DataGrid>
</DockPanel></TabItem><TabItem Header="NETWORK CENTER"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="9">
<Border CornerRadius="10" Padding="15" Margin="0,0,0,9"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#173C55" Offset="0"/><GradientStop Color="#102031" Offset="1"/></LinearGradientBrush></Border.Background><StackPanel><DockPanel><TextBlock DockPanel.Dock="Right" Text="CLOUDFLARE  /  HTTPS + ICMP" FontSize="11" Foreground="#AFC9DF" VerticalAlignment="Center"/><TextBlock Text="NETWORK / SPEED LAB" FontSize="25" FontWeight="Bold" Foreground="#43D7E8"/></DockPanel><TextBlock Name="NetLink" Text="--" Foreground="#73E6AE" Margin="0,5,0,3"/><TextBlock Name="NetAdmin" FontSize="11" Foreground="#AFC9DF"/><TextBlock Text="Test stimato, singola connessione. Circa 30 MB. Nessuna modifica automatica." TextWrapping="Wrap" Foreground="#AFC9DF" Margin="0,3,0,0"/></StackPanel></Border>
<UniformGrid Columns="2" Margin="0,0,0,6">
<Border Background="#12263A" CornerRadius="8" Padding="13" Margin="0,0,4,0"><StackPanel><TextBlock Text="DOWNLOAD / Mbps" Foreground="#AFC9DF" FontSize="12"/><TextBlock Name="NetDown" Text="--" FontSize="42" FontWeight="Bold" Foreground="#43D7E8"/><TextBlock Text="Velocita ricezione HTTPS" FontSize="11"/></StackPanel></Border>
<Border Background="#12263A" CornerRadius="8" Padding="13" Margin="4,0,0,0"><StackPanel><TextBlock Text="UPLOAD / Mbps" Foreground="#AFC9DF" FontSize="12"/><TextBlock Name="NetUp" Text="--" FontSize="42" FontWeight="Bold" Foreground="#A9C9FA"/><TextBlock Text="Velocita invio HTTPS" FontSize="11"/></StackPanel></Border>
</UniformGrid>
<UniformGrid Columns="3" Margin="0,0,0,6">
<Border Background="#12263A" CornerRadius="8" Padding="10" Margin="0,0,3,0"><StackPanel><TextBlock Text="PING / ms" FontSize="11"/><TextBlock Name="NetPing" Text="--" FontSize="26" Foreground="#73E6AE" FontWeight="Bold"/></StackPanel></Border>
<Border Background="#12263A" CornerRadius="8" Padding="10" Margin="3,0"><StackPanel><TextBlock Text="JITTER / ms" FontSize="11"/><TextBlock Name="NetJitter" Text="--" FontSize="26" Foreground="#F4C77B" FontWeight="Bold"/></StackPanel></Border>
<Border Background="#12263A" CornerRadius="8" Padding="10" Margin="3,0,0,0"><StackPanel><TextBlock Text="LOSS / %" FontSize="11"/><TextBlock Name="NetLoss" Text="--" FontSize="26" Foreground="#A9C9FA" FontWeight="Bold"/></StackPanel></Border>
</UniformGrid>
<Border Background="#101B2A" CornerRadius="8" Padding="10" Margin="0,0,0,8"><StackPanel><DockPanel><TextBlock DockPanel.Dock="Right" Name="NetStage" Text="PRONTO" Foreground="#43D7E8" TextWrapping="Wrap" MaxWidth="240"/><TextBlock Text="LATENCY TRACE / 10 PING" FontSize="11" Foreground="#AFC9DF"/></DockPanel><Viewbox Stretch="Fill" Height="72"><Canvas Width="300" Height="84"><Path Stroke="#29445F" StrokeThickness="1" Data="M 10,10 L 290,10 M 10,42 L 290,42 M 10,75 L 290,75"/><Polyline Name="NetTrace" Stroke="#43D7E8" StrokeThickness="2" StrokeLineJoin="Round"/></Canvas></Viewbox><ProgressBar Name="NetProgress" Height="7" Maximum="100" Value="0" Foreground="#43D7E8" Background="#22384D"/><WrapPanel HorizontalAlignment="Center" Margin="0,5,0,0"><Button Name="NetStart" Content="AVVIA SPEED TEST" Background="#0C7189"/><Button Name="NetCancel" Content="ANNULLA" IsEnabled="False"/><Button Name="NetRefresh" Content="AGGIORNA RETE"/><Button Name="NetFlushDNS" Content="SVUOTA CACHE DNS"/></WrapPanel></StackPanel></Border>
<Border Background="#14283B" CornerRadius="8" Padding="10" Margin="0,0,0,8"><StackPanel><TextBlock Text="DNS ATTUALI / INTERFACCE" FontWeight="Bold" Foreground="#43D7E8"/><TextBlock Name="NetInfo" Text="--" TextWrapping="Wrap" Margin="0,5,0,0"/></StackPanel></Border>
<TextBlock Text="NETWORK TWEAKS / DRIVER + BROWSER" FontSize="17" FontWeight="Bold" Foreground="#43D7E8" Margin="0,5,0,4"/><TextBlock Text="Seleziona una voce. Driver: solo modifiche compatibili, con backup separato e riavvio manuale. Le voci browser sono collegate al catalogo originale." TextWrapping="Wrap" Foreground="#AFC9DF"/>
<DataGrid Name="NetGrid" IsReadOnly="True" SelectionMode="Single" AutoGenerateColumns="False" CanUserAddRows="False" Height="260" Margin="0,8,0,4"><DataGrid.Columns><DataGridTextColumn Header="Tweak" Binding="{Binding Name}" Width="2*"/><DataGridTextColumn Header="PWU" Binding="{Binding PWU}" Width="65"/><DataGridTextColumn Header="Prima" Binding="{Binding Before}" Width="80"/><DataGridTextColumn Header="Dopo" Binding="{Binding After}" Width="80"/><DataGridTextColumn Header="Stato" Binding="{Binding Status}" Width="*"/></DataGrid.Columns></DataGrid>
<TextBlock Name="NetDetail" Text="Seleziona una voce per dettagli." TextWrapping="Wrap" Foreground="#AFC9DF" Margin="0,3,0,5"/><WrapPanel><Button Name="NetApply" Content="APPLICA TWEAK" Background="#0C7189"/><Button Name="NetRestore" Content="RIPRISTINA DRIVER" IsEnabled="False"/><TextBlock Name="NetBackupCount" Text="Backup rete: --" VerticalAlignment="Center" Margin="8,0"/></WrapPanel>
</StackPanel></ScrollViewer></TabItem></TabControl></Grid>
<Border Grid.Row="3" Background="#111F32" CornerRadius="8" Padding="10" Margin="0,10,0,0"><DockPanel><Button DockPanel.Dock="Right" Name="Apply" Background="#0C7189" Content="APPLICA MODIFICHE SELEZIONATE" FontWeight="Bold" Padding="20,12"/><TextBlock Name="Status" Text="Scansione iniziale..." TextWrapping="Wrap" VerticalAlignment="Center" Margin="6"/></DockPanel></Border>
</Grid></Window>
'@
$w=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
if($UiTest){if(!$w.FindName('Grid') -or !$w.FindName('Debloat')){throw 'GUI test failed'}; foreach($id in @('GpuApp','Software','Features','Services','Diag','Updates','Audio','SelectAll','CategoryList','PageGrid','PageAction','PageRefresh','SelectPage','Network','NetStart','NetGrid','NetDown','NetTrace','NetRestore','Pending','PWUHigh','PWUMedium','PWULow','StateAvailable','FilterCount','ResetFilters')){if(!$w.FindName($id)){throw ('Missing GUI control: '+$id)}}}
$grid=$w.FindName('Grid');$status=$w.FindName('Status')
function SetDarkChrome($win){
 try{
  $win.Add_SourceInitialized({
   try{
    $handle=(New-Object Windows.Interop.WindowInteropHelper $this).Handle
    $v=1
    $null=[BrabusDwm]::DwmSetWindowAttribute($handle,20,[ref]$v,4)
   }catch{}
  })
 }catch{}
}
function ConfirmDark($title,$message){
 $d=New-Object Windows.Window
 $d.Title=$title;$d.Width=720;$d.Height=500;$d.Owner=$w;$d.WindowStartupLocation='CenterOwner';$d.Background='#0B1220';$d.Foreground='#E3ECF9';$d.Resources.MergedDictionaries.Add($w.Resources);SetDarkChrome $d
 $p=New-Object Windows.Controls.DockPanel;$p.Margin='18'
 $buttons=New-Object Windows.Controls.StackPanel;$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';[Windows.Controls.DockPanel]::SetDock($buttons,'Bottom')
 $yes=New-Object Windows.Controls.Button;$yes.Content='CONFERMA';$yes.Background='#0C7189';$yes.IsDefault=$false
 $no=New-Object Windows.Controls.Button;$no.Content='ANNULLA';$no.IsCancel=$true
 $null=$buttons.Children.Add($no);$null=$buttons.Children.Add($yes);$null=$p.Children.Add($buttons)
 $tb=New-Object Windows.Controls.TextBox;$tb.Text=$message;$tb.IsReadOnly=$true;$tb.TextWrapping='Wrap';$tb.VerticalScrollBarVisibility='Auto';$tb.Margin='0,0,0,12';$null=$p.Children.Add($tb)
 $d.Content=$p;$yes.Add_Click({$d.DialogResult=$true})
 return ($d.ShowDialog() -eq $true)
}
function OpenRecoveryCenter{
 $b=BackupStatus
 $records=@(ReadJournal)
 $d=New-Object Windows.Window
 $d.Title='Backup & Recovery Center';$d.Width=960;$d.Height=680;$d.Owner=$w;$d.WindowStartupLocation='CenterOwner';$d.Background='#0B1220';$d.Foreground='#E3ECF9';$d.Resources.MergedDictionaries.Add($w.Resources);SetDarkChrome $d
 $p=New-Object Windows.Controls.DockPanel;$p.Margin='16'
 $head=New-Object Windows.Controls.TextBlock;$head.Text="BACKUP V2 | $($b.Pending) modifiche da ripristinare | $($b.Snapshots) snapshot storici. $($b.Warning)"+[Environment]::NewLine+'Seleziona uno o piu elementi per ripristinarli. I file storici sono consultabili, ma non vengono applicati come script.';$head.TextWrapping='Wrap';$head.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($head,'Top');$null=$p.Children.Add($head)
 $bar=New-Object Windows.Controls.StackPanel;$bar.Orientation='Horizontal';[Windows.Controls.DockPanel]::SetDock($bar,'Bottom')
 $buttons=@('RIPRISTINA SELEZIONATI','ULTIMA SESSIONE ATTIVA','VERIFICA COPIE','APRI CARTELLA','CHIUDI')
 $controls=@()
 foreach($n in $buttons){$btn=New-Object Windows.Controls.Button;$btn.Content=$n;$null=$bar.Children.Add($btn);$controls+=$btn}
 $controls[4].IsCancel=$true
 $null=$p.Children.Add($bar)
 $lb=New-Object Windows.Controls.ListBox;$lb.SelectionMode='Extended';$lb.DisplayMemberPath='Label'
 $lb.ItemsSource=@($records|ForEach-Object {[pscustomobject]@{Id=$_.Id;BatchId=$_.BatchId;Label="$($_.Name)  |  $(Display $_.Target) -> $(Display $_.Old)  |  $($_.Time)  |  $($_.BatchId.Substring(0,8))"}})
 $null=$p.Children.Add($lb)
 $d.Content=$p
 $controls[0].Add_Click({try{$ids=@($lb.SelectedItems|ForEach-Object Id);if($ids.Count -and (ConfirmDark 'Ripristino selettivo' "Ripristinare $($ids.Count) impostazioni?")){RestoreRecords $ids;$d.DialogResult=$true}}catch{$head.Text=$_.Exception.Message}})
 $controls[1].Add_Click({try{$r=@(ReadJournal);if(!$r.Count){return};$batch=$r[-1].BatchId;$ids=@($r|Where-Object BatchId -eq $batch|ForEach-Object Id);if(ConfirmDark 'Ripristino sessione' "Ripristinare $($ids.Count) impostazioni dell ultima sessione attiva?"){RestoreRecords $ids;$d.DialogResult=$true}}catch{$head.Text=$_.Exception.Message}})
 $controls[2].Add_Click({try{$v=BackupStatus;$head.Text="Record validi: $($v.Pending) | Snapshot: $($v.Snapshots) | $($v.Warning)";if(!$v.Warning){$head.Text+=' | Nessuna anomalia nelle copie disponibili'}}catch{$head.Text=$_.Exception.Message}})
 $controls[3].Add_Click({Start-Process explorer.exe $backupDir})
 $null=$d.ShowDialog()
 RefreshRows
}
function UpdateDashboard{
 $total=$script:rows.Count;$done=@($script:rows|Where-Object Status -eq 'GIA CONFIGURATO').Count
 $available=@($script:rows|Where-Object Status -eq 'DISPONIBILE').Count
 $w.FindName('Total').Text=[string]$total
 $w.FindName('Available').Text=[string]$available
 $w.FindName('Done').Text="$done / $total"
 try{$b=BackupStatus;$w.FindName('Pending').Text=[string]$b.Pending;if($b.Warning){$status.Text=$b.Warning}}catch{$w.FindName('Pending').Text='ERRORE';$status.Text=$_.Exception.Message}
}
$script:pwuFilter='All';$script:stateFilter='All'
function UpdateFilterButtons{
 foreach($pair in @(@('PWUAll','All'),@('PWULow','Low'),@('PWUMedium','Medium'),@('PWUHigh','High'))){$w.FindName($pair[0]).Background=if($script:pwuFilter -eq $pair[1]){'#126480'}else{'#17283C'}}
 foreach($pair in @(@('StateAll','All'),@('StateAvailable','Available'),@('StateDone','Done'),@('StateSelected','Selected'))){$w.FindName($pair[0]).Background=if($script:stateFilter -eq $pair[1]){'#126480'}else{'#17283C'}}
}
function FilterRows{
 $q=$w.FindName('Filter').Text.Trim()
 $terms=@($q -split '\s+'|Where-Object {$_})
 $visible=@($script:rows|Where-Object {
  $r=$_
  if($script:category -and $script:category -ne 'Tutte' -and $r.Category -ne $script:category){return $false}
  if($script:pwuFilter -ne 'All' -and $r.PWU -ne $script:pwuFilter){return $false}
  if($script:stateFilter -eq 'Available' -and $r.Status -ne 'DISPONIBILE'){return $false}
  if($script:stateFilter -eq 'Done' -and $r.Status -ne 'GIA CONFIGURATO'){return $false}
  if($script:stateFilter -eq 'Selected' -and !$r.Selected){return $false}
  $hay="$($r.Name) $($r.Category) $($r.Status) $($r.Note) $($r.Key) $($r.PWU) $($r.PWUReason)"
  foreach($term in $terms){if($hay.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -lt 0){return $false}}
  return $true
 })
 $grid.ItemsSource=$visible
 $w.FindName('FilterCount').Text="$($visible.Count) / $($script:rows.Count) visibili"
}
function UpdateLog{if(Test-Path $log){$w.FindName('History').Text=(Get-Content $log -Tail 200)-join [Environment]::NewLine}}
function RefreshRows{$script:rows=@(Catalog);$cl=$w.FindName("CategoryList");$cl.ItemsSource=@("Tutte")+@($script:rows.Category|Sort-Object -Unique);if($script:category -notin $cl.ItemsSource){$script:category="Tutte"};$cl.SelectedItem=$script:category;FilterRows;UpdateDashboard;UpdateLog}
function Guard($a){try{& $a}catch{$status.Text='ERRORE: '+$_.Exception.Message;UpdateLog}}
function ProfileId($row){if($row.Path.StartsWith("POWER|")){"POWER|$($row.Path.Split("|")[2])|$($row.Key)"}else{"$($row.Path)|$($row.Key)"}}
function ExportProfile{
 $items=@($script:rows|Where-Object Selected|ForEach-Object {ProfileId $_})
 if(!$items.Count){throw 'Seleziona almeno un tweak'}
 $dlg=New-Object Microsoft.Win32.SaveFileDialog
 $dlg.Filter='Brabus preset (*.brabus.json)|*.brabus.json';$dlg.FileName='Gaming.brabus.json'
 if($dlg.ShowDialog($w) -ne $true){return}
 Atomic $dlg.FileName @{Format='BrabusPreset';Version=1;Selections=$items}
 $status.Text='Preset esportato: solo identificatori, nessun dato hardware o valore privato.'
}
function ImportProfile{
 $dlg=New-Object Microsoft.Win32.OpenFileDialog
 $dlg.Filter='Brabus preset (*.brabus.json)|*.brabus.json'
 if($dlg.ShowDialog($w) -ne $true){return}
 if((Get-Item -LiteralPath $dlg.FileName).Length -gt 1MB){throw 'Preset troppo grande'}
 $p=Get-Content -LiteralPath $dlg.FileName -Raw|ConvertFrom-Json
 if($p.Format -ne 'BrabusPreset' -or $p.Version -ne 1){throw 'Formato non valido'}
 $ids=@($p.Selections|Where-Object {$_ -is [string]})
 foreach($r in $script:rows){$r.Selected=($ids -contains (ProfileId $r) -and $r.Status -eq 'DISPONIBILE')}
 $matched=@($script:rows|Where-Object Selected).Count
 $known=@($script:rows|ForEach-Object {ProfileId $_})
 $unknown=@($ids|Where-Object {$_ -notin $known}).Count
 $grid.Items.Refresh()
 $status.Text="Preset importato: $matched selezionati, $unknown non compatibili. Nessuna modifica applicata."
}
function SelectPreset($p){
 foreach($r in $script:rows){$r.Selected=($r.Status -eq 'DISPONIBILE' -and ($r.Level -eq 'Safe' -or ($p -ne 'Safe' -and $r.Level -eq 'Gaming')))}
 $grid.Items.Refresh()
 $w.FindName('Tabs').SelectedIndex=0; $status.Text="${p}: selezionati $(@($script:rows|Where-Object Selected).Count) tweak conservativi. Le opzioni personali e di avvio restano manuali."
}
# Integrated Control Center: all navigation is local to the main window.
$script:page='';$script:pageRows=@();$script:category='Tutte'
function PageRow($name,$state,$detail,$id=''){
 [pscustomobject]@{Name=[string]$name;State=[string]$state;Detail=[string]$detail;Id=[string]$id}
}
function ShowCategory($name){
 $script:category=$name
 $w.FindName('CategoryTitle').Text="IMPOSTAZIONI / $name";$cl=$w.FindName('CategoryList');if($cl.SelectedItem -ne $name -and $name -in $cl.ItemsSource){$cl.SelectedItem=$name}
 $w.FindName('Tabs').SelectedIndex=0
 FilterRows
}
function PageFilter{
 $q=$w.FindName('PageSearch').Text.Trim()
 $w.FindName('PageGrid').ItemsSource=@($script:pageRows|Where-Object {!$q -or $_.Name -like "*$q*" -or $_.State -like "*$q*" -or $_.Detail -like "*$q*"})
}
function SetPage($id,$title,$hint,$rows,$action='',$category=''){
 $script:page=$id;$script:pageRows=@($rows)
 $w.FindName('PageTitle').Text=$title
 $w.FindName('PageHint').Text=$hint
 $w.FindName('PageSearch').Text=''
 $w.FindName('PageCount').Text="$($script:pageRows.Count) elementi"
 $w.FindName('PageAction').Content=$action
 $w.FindName('PageAction').Visibility=if($action){'Visible'}else{'Collapsed'}
 $w.FindName('PageCategory').Visibility=if($category){'Visible'}else{'Collapsed'}
 $w.FindName('PageCategory').Tag=$category
 $w.FindName('PageDetail').Text='Seleziona una riga per consultare i dettagli.'
 $w.FindName('Tabs').SelectedIndex=3
 PageFilter
}
function InstalledAppRows{
 $seen=@{}
 foreach($p in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')){
  foreach($a in @(Get-ItemProperty -Path $p -ErrorAction SilentlyContinue)){
   if(!$a.DisplayName -or $a.SystemComponent -eq 1){continue}
   $id="$($a.DisplayName)|$($a.DisplayVersion)";if($seen.ContainsKey($id)){continue};$seen[$id]=$true
   PageRow $a.DisplayName $a.DisplayVersion $a.Publisher
  }
 }
 foreach($a in @(Get-AppxPackage|Where-Object {!$_.IsFramework})){PageRow $a.Name $a.Version 'App Microsoft Store / utente corrente'}
}
function OpenPage($id){
 switch($id){
 'Apps' {SetPage $id 'APP INSTALLATE' 'Inventario locale Win32 e Microsoft Store; nessuna disinstallazione automatica.' @(InstalledAppRows|Sort-Object Name)}
 'Debloat' {SetPage $id 'DEBLOAT / APP OPZIONALI' 'Selezione multipla. Rimuove solo app consentite per utente corrente; dati e reinstallazione non garantiti.' @(OptionalPackages|ForEach-Object {PageRow $_.Name 'Installata' "Versione: $($_.Version)" $_.PackageFullName}) 'RIMUOVI SELEZIONATE'}
 'Startup' {SetPage $id 'AVVIO WINDOWS' 'Inventario avvio automatico. Le voci modificabili e ripristinabili sono nella categoria Startup.' @(Get-CimInstance Win32_StartupCommand|ForEach-Object {PageRow $_.Name $_.Location $_.Command}) '' 'Startup'}
 'Power' { $active=CurrentScheme; $rows=@(powercfg /list|ForEach-Object {if($_ -match '([a-fA-F0-9-]{36})\s+\((.*?)\)(.*)'){PageRow $Matches[2] $(if($Matches[1] -eq $active){'Attivo'}else{'Disponibile'}) $Matches[1]}});SetPage $id 'ENERGIA / CPU' 'Piani rilevati. Modifica i parametri compatibili del piano attivo nella categoria Power / CPU. Non cambia piano automaticamente.' $rows '' 'Power / CPU'}
 'Storage' {SetPage $id 'ARCHIVIAZIONE' 'Spazio disponibile e salute dei dischi. Nessuna cancellazione automatica.' @(
 Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'|ForEach-Object {PageRow $_.DeviceID ("{0:N1} GB liberi" -f ($_.FreeSpace/1GB)) ("Capacita {0:N1} GB | {1:N1}% libero" -f ($_.Size/1GB),(100*$_.FreeSpace/[math]::Max([double]1,[double]$_.Size)))}
 Get-PhysicalDisk -ErrorAction SilentlyContinue|ForEach-Object {PageRow $_.FriendlyName $_.HealthStatus ("{0} | {1:N1} GB | {2}" -f $_.MediaType,($_.Size/1GB),$_.OperationalStatus)}
 )}
 'Graphics' {SetPage $id 'GRAFICA / DISPLAY' 'GPU, driver e refresh rilevati. Preferenze visive nella categoria Visual; GPU per gioco nella pagina dedicata.' @(Get-CimInstance Win32_VideoController|ForEach-Object {PageRow $_.Name $_.DriverVersion "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) | $($_.CurrentRefreshRate) Hz"}) '' 'Visual'}
 'GpuApp' { $rows=@();$k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\DirectX\UserGpuPreferences');if($k){try{$rows=@($k.GetValueNames()|ForEach-Object {PageRow ([IO.Path]::GetFileName($_)) $k.GetValue($_) $_ $_})}finally{$k.Dispose()}};SetPage $id 'GPU PER GIOCO' 'Profili GPU Windows per eseguibile. Aggiungi un gioco scegliendo il file EXE; modifica verificata con backup.' $rows 'AGGIUNGI GIOCO'}
 'Software' {SetPage $id 'SOFTWARE CENTER' 'Pacchetti candidati WinGet: verifica ID e dettagli prima di confermare ogni installazione. Gli installer possono aprire una finestra propria.' @(SoftwareCatalog|ForEach-Object {PageRow $_.Name $_.Category $_.Id $_.Id}) 'VERIFICA E INSTALLA'}
 'Features' {SetPage $id 'FUNZIONALITA WINDOWS' 'Inventario funzionalita Windows, in sola lettura per preservare dipendenze di giochi, WSL e virtualizzazione.' @(GetFeatureInventory|ForEach-Object {PageRow $_.Name $_.State 'Funzionalita Windows'})}
 'Services' {SetPage $id 'SERVIZI WINDOWS' 'Stato e tipo avvio. Sola lettura: nessuna disattivazione di servizi o protezioni.' @(GetServiceInventory|ForEach-Object {PageRow $_.Name $_.State "$($_.StartMode) | $($_.Label)"})}
 'Updates' {SetPage $id 'WINDOWS UPDATE' 'Stato dei servizi e aggiornamenti installati. Non disattiva aggiornamenti, non installa patch automaticamente.' @(
 Get-Service wuauserv,BITS,DoSvc -ErrorAction SilentlyContinue|ForEach-Object {PageRow $_.DisplayName $_.Status $_.StartType}
 Get-HotFix -ErrorAction SilentlyContinue|Sort-Object InstalledOn -Descending|ForEach-Object {PageRow $_.HotFixID $_.Description $_.InstalledOn}
 )}
 'Audio' {SetPage $id 'AUDIO E NOTIFICHE' 'Dispositivi audio rilevati; impostazioni notifiche gestite nella categoria Notifications.' @(Get-CimInstance Win32_SoundDevice|ForEach-Object {PageRow $_.Name $_.Status $_.Manufacturer}) '' 'Notifications'}
 'Network' {SetPage $id 'RETE / DNS' 'Interfacce, link e DNS correnti. Non altera la rete; dati locali.' @(
 Get-NetAdapter -ErrorAction SilentlyContinue|ForEach-Object {PageRow $_.Name $_.Status "$($_.LinkSpeed) | $($_.InterfaceDescription)"}
 Get-DnsClientServerAddress -ErrorAction SilentlyContinue|Where-Object {$_.ServerAddresses}|ForEach-Object {PageRow $_.InterfaceAlias 'DNS' ($_.ServerAddresses -join ', ')}
 )}
 'Diag' { $data=ExtendedDiagnostics;$rows=@();foreach($key in $data.Keys){foreach($v in @($data[$key])){if($v -is [string]){$rows+=PageRow $key '' $v}else{$rows+=PageRow $key '' (($v|Format-List|Out-String).Trim() -replace '\r?\n',' | ')}}};SetPage $id 'DIAGNOSTICA AVANZATA' 'Snapshot hardware e sistema. Nessuna conclusione automatica su colli di bottiglia o latenza.' $rows 'ESPORTA REPORT'}
 'Backup' { $b=BackupStatus;SetPage $id 'BACKUP / RECOVERY' "$($b.Pending) modifiche da ripristinare | $($b.Snapshots) snapshot. $($b.Warning)" @(ReadJournal|ForEach-Object {PageRow $_.Name (Display $_.Target) ("Ripristino: $(Display $_.Old) | $($_.Time)") $_.Id}) 'RIPRISTINA SELEZIONATI'}
 'Files' {SetPage $id 'LOG E REPORT LOCALI' 'File locali del programma. Seleziona un report o log per visualizzarlo qui; non condividerlo se contiene informazioni personali.' @(Get-ChildItem -LiteralPath $root -File|Where-Object {$_.Name -match '^(scan-|extended-|changes\.jsonl$)'}|Sort-Object LastWriteTime -Descending|ForEach-Object {PageRow $_.Name $_.LastWriteTime ("{0:N1} KB" -f ($_.Length/1KB)) $_.FullName}) 'LEGGI FILE'}
 default {throw "Pagina non valida: $id"}
 }
}
function InvokePageAction{
 $g=$w.FindName('PageGrid');$selected=@($g.SelectedItems);$one=$g.SelectedItem
 switch($script:page){
 'GpuApp' {OpenGPUPreference;OpenPage 'GpuApp'}
 'Software' {
  if(!$one){return};$id=$one.Id
  if($id -notin @(SoftwareCatalog|ForEach-Object Id) -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{1,99}$'){throw 'ID non autorizzato'}
  $cmd=Get-Command winget -ErrorAction SilentlyContinue;if(!$cmd){throw 'WinGet non disponibile'}
  $details=& winget show --id $id --exact --source winget --disable-interactivity 2>&1
  if($LASTEXITCODE -ne 0){throw "Pacchetto non verificato: $id"}
  if(!(ConfirmDark "Installare $($one.Name)?" ($details|Out-String))){return}
  $j=Start-Process -FilePath $cmd.Source -ArgumentList @('install','--id',$id,'--exact','--source','winget','--interactive') -PassThru -Wait
  Event "WinGet: $id" 'Installazione' $j.ExitCode 'COMANDO TERMINATO';UpdateLog;$status.Text="WinGet exit code: $($j.ExitCode)"
 }
 'Debloat' {
  if(!$selected.Count){return}
  if(!(ConfirmDark 'Disinstallazione app' ("Dati e preferenze possono andare persi. Ripristino non automatico."+[Environment]::NewLine+($selected.Name -join [Environment]::NewLine)))){return}
  $ok=0;$fail=0
  foreach($r in $selected){try{$app=OptionalPackages|Where-Object PackageFullName -eq $r.Id|Select-Object -First 1;if(!$app){throw 'App non consentita o non presente'};Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop;if(Get-AppxPackage -Name $app.Name){throw 'App ancora presente'};Event $app.Name 'Installata' 'Rimossa' 'VERIFICATO';$ok++}catch{Event $r.Name 'Installata' '?' $_.Exception.Message;$fail++}}
  OpenPage 'Debloat';UpdateLog;$status.Text="Rimosse: $ok; errori: $fail"
 }
 'Backup' {if(!$selected.Count){return};if(ConfirmDark 'Ripristino selettivo' "Ripristinare $($selected.Count) impostazioni?"){RestoreRecords @($selected.Id);RefreshRows;OpenPage 'Backup'}}
 'Diag' { $file=Join-Path $root ('extended-'+[guid]::NewGuid().ToString()+'.json');Atomic $file (ExtendedDiagnostics);$status.Text="Report locale: $file" }
 'Files' {if(!$one){return};$file=Get-Item -LiteralPath $one.Id;if($file.DirectoryName -ne $root -or $file.Length -gt 5MB){throw 'File non consentito o troppo grande'};$w.FindName('Report').Text=Get-Content -LiteralPath $file.FullName -Raw;$w.FindName('Tabs').SelectedIndex=1}
 }
}
$w.FindName('PageSearch').Add_TextChanged({PageFilter})
$w.FindName('PageGrid').Add_SelectionChanged({$r=$w.FindName('PageGrid').SelectedItem;if($r){$w.FindName('PageDetail').Text="$($r.Name) | $($r.State)"+[Environment]::NewLine+$r.Detail}})
$w.FindName('PageAction').Add_Click({Guard {InvokePageAction}})
$w.FindName('PageRefresh').Add_Click({Guard {if($script:page){OpenPage $script:page}}})
$w.FindName('PageCategory').Add_Click({ShowCategory ([string]$w.FindName('PageCategory').Tag)})
$w.FindName('CategoryList').Add_SelectionChanged({$c=$w.FindName('CategoryList').SelectedItem;if($c){ShowCategory ([string]$c)}})
$w.FindName('Grid').Add_SelectionChanged({$r=$grid.SelectedItem;if($r){$w.FindName('TweakDetail').Text="$($r.Name) | $($r.Status) | $($r.Before) -> $($r.After)"+[Environment]::NewLine+$r.Note+[Environment]::NewLine+"PWU $($r.PWU): $($r.PWUReason)"}})
$w.FindName('SelectPage').Add_Click({Guard {
 $pending=@(ReadJournal);$count=0
 foreach($r in @($grid.ItemsSource)){if($r.Status -eq 'DISPONIBILE' -and !@($pending|Where-Object {$_.Path -eq $r.Path -and $_.Key -eq $r.Key}).Count){$r.Selected=$true;$count++}}
 $grid.Items.Refresh(); if($script:stateFilter -eq 'Selected'){FilterRows};$status.Text="Selezionate $count voci visibili. Nessuna modifica applicata."
}})

foreach($id in @('PWUAll','PWULow','PWUMedium','PWUHigh')){
 $b=$w.FindName($id);$b.Tag=$id.Substring(3)
 $b.Add_Click({param($sender,$eventArgs)$script:pwuFilter=[string]$sender.Tag;UpdateFilterButtons;FilterRows})
}
foreach($id in @('StateAll','StateAvailable','StateDone','StateSelected')){
 $b=$w.FindName($id);$b.Tag=$id.Substring(5)
 $b.Add_Click({param($sender,$eventArgs)$script:stateFilter=[string]$sender.Tag;UpdateFilterButtons;FilterRows})
}
$w.FindName('ResetFilters').Add_Click({$script:pwuFilter='All';$script:stateFilter='All';$w.FindName('Filter').Text='';ShowCategory 'Tutte';UpdateFilterButtons;FilterRows})
UpdateFilterButtons
$grid.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{
 param($sender,$args)
 if($script:stateFilter -eq 'Selected' -and $args.OriginalSource -is [Windows.Controls.CheckBox]){
  $null=$w.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]{FilterRows})
 }
})
$w.FindName('Filter').Add_TextChanged({FilterRows})
$w.FindName('Export').Add_Click({Guard {ExportProfile}})
$w.FindName('Import').Add_Click({Guard {ImportProfile}})
# Network Center (same window and folder).
function NetworkDefinitions {
 @{
  '*RSS'=@('Receive Side Scaling', '1','Medium','Distribuisce ricezione tra CPU; utile per throughput elevato.')
  '*RscIPv4'=@('Receive Segment Coalescing IPv4','1','Medium','Riduce overhead CPU; possibile compromesso latenza.')
  '*RscIPv6'=@('Receive Segment Coalescing IPv6','1','Medium','Riduce overhead CPU; possibile compromesso latenza.')
  '*LsoV2IPv4'=@('Large Send Offload IPv4','1','Medium','Offload trasmissione; misura throughput e latenza prima/dopo.')
  '*LsoV2IPv6'=@('Large Send Offload IPv6','1','Medium','Offload trasmissione; misura throughput e latenza prima/dopo.')
  '*InterruptModeration'=@('Interrupt Moderation: off','0','Medium','Possibile riduzione latenza, ma aumenta carico CPU; non sempre conviene.')
  '*EEE'=@('Energy Efficient Ethernet: off','0','Low','Possibile riduzione ritardi di risveglio; aumenta consumo.')
  '*TCPChecksumOffloadIPv4'=@('TCP checksum IPv4','3','Low','Offload checksum RX/TX; beneficio dipende dal driver.')
  '*TCPChecksumOffloadIPv6'=@('TCP checksum IPv6','3','Low','Offload checksum RX/TX; beneficio dipende dal driver.')
  '*UDPChecksumOffloadIPv4'=@('UDP checksum IPv4','3','Low','Offload checksum RX/TX; beneficio dipende dal driver.')
  '*UDPChecksumOffloadIPv6'=@('UDP checksum IPv6','3','Low','Offload checksum RX/TX; beneficio dipende dal driver.')
  '*UsoIPv4'=@('UDP Segmentation Offload IPv4','1','Medium','Riduce overhead CPU per datagrammi grandi; dipende dal traffico.')
  '*UsoIPv6'=@('UDP Segmentation Offload IPv6','1','Medium','Riduce overhead CPU per datagrammi grandi; dipende dal traffico.')
  '*PacketCoalescing'=@('Packet Coalescing: off','0','Low','Possibile riduzione ritardo di aggregazione, maggiore carico CPU.')
  '*SelectiveSuspend'=@('Selective Suspend: off','0','Low','Solo desktop; evita sospensione selettiva della scheda, maggiori consumi.')
  '*IPChecksumOffloadIPv4'=@('IP checksum IPv4','3','Low','Offload checksum RX/TX; beneficio dipende dal driver.')
 }
}
function NetworkProperty($path,$key){
 $parts=$path.Split('|');$defs=NetworkDefinitions
 if($parts.Count -ne 2 -or !$defs.ContainsKey($key)){throw 'Proprieta rete non autorizzata'}
 $guid=[guid]$parts[1]
 $adapter=Get-NetAdapter -Physical -ErrorAction Stop|Where-Object {[guid]$_.InterfaceGuid -eq $guid}|Select-Object -First 1
 if(!$adapter){throw 'Scheda fisica originale non rilevata'}
 $prop=Get-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape($adapter.Name)) -RegistryKeyword $key -ErrorAction Stop|Where-Object RegistryKeyword -eq $key|Select-Object -First 1
 if(!$prop -or @($prop.RegistryValue).Count -ne 1){throw 'Proprieta non disponibile o formato non supportato'}
 [pscustomobject]@{Adapter=$adapter;Property=$prop}
}
function NetworkRead($path,$key){
 $p=(NetworkProperty $path $key).Property
 [pscustomobject]@{Exists=$true;Kind='String';Value=[string]$p.RegistryValue[0]}
}
function NetworkWrite($path,$key,$state){
 if(!(IsElevated)){throw 'Richiede PowerShell come amministratore; non viene elevato automaticamente'}
 if(!$state.Exists -or $state.Kind -ne 'String'){throw 'Stato rete non valido'}
 $p=NetworkProperty $path $key
 if([string]$state.Value -notin @($p.Property.ValidRegistryValues)){throw 'Valore non supportato dal driver'}
 Set-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape($p.Adapter.Name)) -RegistryKeyword $key -RegistryValue @([string]$state.Value) -NoRestart -ErrorAction Stop
}
function NetworkCatalog{
 $defs=NetworkDefinitions
 foreach($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)){
  if($a.Status -ne 'Up'){continue}
  foreach($p in @(Get-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape($a.Name)) -ErrorAction SilentlyContinue)){
   $key=$p.RegistryKeyword
   if(!$defs.ContainsKey($key) -or @($p.RegistryValue).Count -ne 1){continue}
   if($key -in @('*SelectiveSuspend','*PacketCoalescing') -and @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count){continue};$d=$defs[$key];if($d[1] -notin @($p.ValidRegistryValues)){continue}
   $before=[string]$p.RegistryValue[0]
   if($before -notin @($p.ValidRegistryValues)){continue}
   [pscustomobject]@{Name="$($a.Name): $($d[0])";Path="NET|$([guid]$a.InterfaceGuid)";Key=$key;Before=$before;After=$d[1];Status=$(if($before -eq $d[1]){'GIA CONFIGURATO'}else{'DISPONIBILE'});PWU=$d[2];Note=$d[3]+' | Admin richiesto; effetto dopo riavvio scheda/PC.';TargetState=[pscustomobject]@{Exists=$true;Kind='String';Value=[string]$d[1]}}
  }
 }
}
function WithNetworkJournal([scriptblock]$action){
 # Separate journal filenames in the existing backup directory: older versions can still read their own backups.
 $journal=Join-Path $backupDir 'network-active.json'
 $mirror=Join-Path $backupDir 'network-mirror.json'
 $legacyJournal=Join-Path $backupDir 'network-legacy.json'
 $initializedFlag=Join-Path $backupDir 'network-initialized.flag'
 & $action
}
function GetNetworkBackup { @(WithNetworkJournal {ReadJournal}) }
function GetNetworkRelated {
 @($script:rows|Where-Object {$_.Category -eq 'Browser' -and $_.Key -in @('BackgroundModeEnabled','StartupBoostEnabled','NetworkPredictionOptions','NewTabPagePrerenderEnabled','SearchSuggestEnabled','AlternateErrorPagesEnabled')})
}
function RefreshNetwork {
 $a=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object Status -eq 'Up')
 $w.FindName('NetLink').Text=if($a.Count){($a|ForEach-Object {"$($_.Name) | $($_.LinkSpeed)"}) -join '  /  '}else{'Nessuna interfaccia attiva'}
 $w.FindName('NetInfo').Text=(@(Get-DnsClientServerAddress -ErrorAction SilentlyContinue|Where-Object {$_.ServerAddresses -and $_.InterfaceIndex -in $a.ifIndex}|ForEach-Object {"$($_.InterfaceAlias) DNS: "+($_.ServerAddresses -join ', ')}) -join [Environment]::NewLine)
 $extra=@(Get-NetAdapterStatistics -ErrorAction SilentlyContinue|Where-Object Name -in $a.Name|ForEach-Object {"$($_.Name) | Errori RX/TX: $($_.ReceivedPacketErrors)/$($_.OutboundPacketErrors) | Scarti RX/TX: $($_.ReceivedDiscardedPackets)/$($_.OutboundDiscardedPackets)"})
 $tcp=Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue
 if($tcp){$extra+="TCP autotuning: $($tcp.AutoTuningLevelLocal) | Congestione: $($tcp.CongestionProvider)"}
 if($extra.Count){$w.FindName('NetInfo').Text+=[Environment]::NewLine+($extra -join [Environment]::NewLine)}
 $w.FindName('NetGrid').ItemsSource=@(NetworkCatalog)+@(GetNetworkRelated)
 try{$n=@(GetNetworkBackup);$w.FindName('NetBackupCount').Text="Backup rete: $($n.Count)";$w.FindName('NetRestore').IsEnabled=($n.Count -gt 0)}catch{$w.FindName('NetBackupCount').Text='BACKUP RETE: ERRORE';$w.FindName('NetRestore').IsEnabled=$false}
 $w.FindName('NetAdmin').Text=if(IsElevated){'ADMIN | modifiche driver consentite'}else{'UTENTE | test e tweak browser; driver richiede admin'}
}
function ApplyNetworkSelected{
 $r=$w.FindName('NetGrid').SelectedItem;if(!$r){return}
 if($r.Status -ne 'DISPONIBILE'){return}
 if($r.Path.StartsWith('NET|')){
  if(!(IsElevated)){throw 'Per questo tweak riapri BRABUS UTIL da PowerShell avviato come amministratore.'}
  if(!(ConfirmDark 'Modifica scheda di rete' ("$($r.Name): $($r.Before) -> $($r.After)"+[Environment]::NewLine+$r.Note+[Environment]::NewLine+'Backup prima della scrittura. Nessun riavvio automatico; riavvia il PC quando ti conviene. Non garantisce ping/FPS migliori.'))){return}
  WithNetworkJournal {ApplyValue $r}
 }else{
  if(!(ConfirmDark 'Modifica browser' ("$($r.Name): $($r.Before) -> $($r.After)"+[Environment]::NewLine+$r.Note))){return}
  ApplyValue $r
  RefreshRows
 }
 RefreshNetwork
 $status.Text='Valore scritto e verificato. Riavvio manuale del browser o PC se necessario.'
}
function RestoreNetwork{
 if(!(IsElevated)){throw 'Ripristino driver: avvia PowerShell come amministratore'}
 $records=@(GetNetworkBackup);if(!$records.Count){return}
 if(!(ConfirmDark 'Ripristino rete' ("Ripristinare tutte le $($records.Count) modifiche driver gestite? Nessun riavvio automatico."))){return}
 WithNetworkJournal {RestoreRecords @($records.Id)}
 RefreshNetwork
 $status.Text='Ripristino rete verificato; riavvio manuale necessario.'
}
function MeasureConnection([hashtable]$state,[int]$downBytes=25000000,[int]$upBytes=5000000){
 # Only random synthetic bytes and public test requests; no files or personal reports uploaded.
 $ErrorActionPreference='Stop'
 $state.Stage='LATENZA';$state.Progress=5;$cancel=$state.CancelSource;if(!$cancel){$cancel=New-Object Threading.CancellationTokenSource};$token=$cancel.Token
 $samples=@();$lost=0;$ping=New-Object Net.NetworkInformation.Ping
 try{for($i=0;$i -lt 10;$i++){$token.ThrowIfCancellationRequested();try{$r=$ping.Send('1.1.1.1',1000);if($r.Status -eq 'Success'){$samples+= [double]$r.RoundtripTime}else{$lost++}}catch{$lost++};$state.Samples=@($samples);$state.Progress=5+($i+1)*3;Start-Sleep -Milliseconds 100}}finally{$ping.Dispose()}
 $state.Loss=$lost*10
 if($samples.Count){$state.Ping=[math]::Round(($samples|Measure-Object -Average).Average,1)}
 if($samples.Count -ge 2){$delta=@(for($i=1;$i -lt $samples.Count;$i++){[math]::Abs($samples[$i]-$samples[$i-1])});$state.Jitter=[math]::Round(($delta|Measure-Object -Average).Average,1)}
 Add-Type -AssemblyName System.Net.Http
 $client=New-Object Net.Http.HttpClient
 $client.Timeout=[TimeSpan]::FromSeconds(35)
 try{
  $state.Stage='DOWNLOAD';$state.Progress=38;$cancel.CancelAfter(35000)
  $url="https://speed.cloudflare.com/__down?bytes=$downBytes&nonce=$([guid]::NewGuid().ToString('N'))"
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $resp=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$token).GetAwaiter().GetResult()
  try{
   $null=$resp.EnsureSuccessStatusCode();$stream=$resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
   try{$buf=New-Object byte[] 65536;$n=0L;while(($read=$stream.ReadAsync($buf,0,$buf.Length,$token).GetAwaiter().GetResult()) -gt 0){$n+=$read;if($n -gt $downBytes){throw 'Risposta download oltre limite'};$state.Progress=[math]::Min(70,38+32*$n/$downBytes);if($sw.Elapsed.TotalSeconds -gt 35){throw 'Timeout download'}}}finally{$stream.Dispose()}
   $sw.Stop();if($n -ne $downBytes){throw "Download incompleto: $n byte"}
   $state.Down=[math]::Round($n*8/1e6/[math]::Max(.001,$sw.Elapsed.TotalSeconds),2)
  }finally{$resp.Dispose()}
  $state.Stage='UPLOAD';$state.Progress=75;$cancel.CancelAfter(35000)
  $bytes=New-Object byte[] $upBytes
  $rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
  $content=New-Object Net.Http.ByteArrayContent -ArgumentList (,$bytes)
  try{$sw.Restart();$resp=$client.PostAsync('https://speed.cloudflare.com/__up',$content,$token).GetAwaiter().GetResult();try{$null=$resp.EnsureSuccessStatusCode();$sw.Stop();$state.Up=[math]::Round($upBytes*8/1e6/[math]::Max(.001,$sw.Elapsed.TotalSeconds),2)}finally{$resp.Dispose()}}finally{$content.Dispose()}
  $state.Stage='COMPLETATO';$state.Progress=100
 }finally{$client.Dispose()}
}
$script:netJob=$null;$script:netState=$null
function RenderNetworkTest($s){
 foreach($pair in @(@('NetDown','Down'),@('NetUp','Up'),@('NetPing','Ping'),@('NetJitter','Jitter'),@('NetLoss','Loss'))){
  $v=$s[$pair[1]];$w.FindName($pair[0]).Text=if($null -ne $v){[string]$v}else{'--'}
 }
 $w.FindName('NetProgress').Value=[double]$s.Progress
 $w.FindName('NetStage').Text=[string]$s.Stage
 $pts=New-Object Windows.Media.PointCollection
 $arr=@($s.Samples)
 if($arr.Count -gt 0){$max=[math]::Max([double]1,[double]($arr|Measure-Object -Maximum).Maximum);for($i=0;$i -lt $arr.Count;$i++){$pts.Add([Windows.Point]::new((10+280*$i/[math]::Max(1,$arr.Count-1)),(75-65*$arr[$i]/$max)))}}
 $w.FindName('NetTrace').Points=$pts
}
function StopNetworkTest {
 if($script:netJob){
  try{$script:netState.CancelSource.Cancel();$script:netJob.PS.Stop()}catch{}
  $script:netJob.PS.Dispose();if($script:netState.CancelSource){$script:netState.CancelSource.Dispose()};$script:netJob=$null
 }
 $script:netTimer.Stop();$w.FindName('NetStart').IsEnabled=$true;$w.FindName('NetCancel').IsEnabled=$false
}
function StartNetworkTest {
 if($script:netJob){return}
 if(!(ConfirmDark 'Speed test Internet' 'Test verso Cloudflare (circa 30 MB di traffico + overhead); misura una singola connessione HTTPS, non un test multi-stream. Ping ICMP separato a 1.1.1.1. Nessun dato personale inviato esplicitamente; il servizio vede IP e traffico. Avviare?')){return}
 $script:netState=[hashtable]::Synchronized(@{CancelSource=(New-Object Threading.CancellationTokenSource);Stage='AVVIO';Progress=0;Samples=@();Down=$null;Up=$null;Ping=$null;Jitter=$null;Loss=$null})
 RenderNetworkTest $script:netState
 $ps=[powershell]::Create()
 $fn=(Get-Command MeasureConnection).ScriptBlock.ToString()
 $null=$ps.AddScript($fn).AddArgument($script:netState)
 $script:netJob=@{PS=$ps;Async=$ps.BeginInvoke()}
 $w.FindName('NetStart').IsEnabled=$false;$w.FindName('NetCancel').IsEnabled=$true;$script:netTimer.Start()
}
$script:netTimer=New-Object Windows.Threading.DispatcherTimer
$script:netTimer.Interval=[TimeSpan]::FromMilliseconds(300)
$script:netTimer.Add_Tick({
 if(!$script:netJob){return}
 RenderNetworkTest $script:netState
 if($script:netJob.Async.IsCompleted){
  try{$null=$script:netJob.PS.EndInvoke($script:netJob.Async);if($script:netJob.PS.HadErrors){throw ($script:netJob.PS.Streams.Error|Out-String)};RenderNetworkTest $script:netState}catch{$w.FindName('NetStage').Text=if($script:netState.Stage -eq 'ANNULLAMENTO'){'ANNULLATO'}else{"ERRORE: $($_.Exception.Message)"}}
  $script:netJob.PS.Dispose();if($script:netState.CancelSource){$script:netState.CancelSource.Dispose()};$script:netJob=$null;$script:netTimer.Stop();$w.FindName('NetStart').IsEnabled=$true;$w.FindName('NetCancel').IsEnabled=$false
 }
})
$w.FindName('NetStart').Add_Click({Guard {StartNetworkTest}})
$w.FindName('NetCancel').Add_Click({Guard {if($script:netJob){$script:netState.Stage='ANNULLAMENTO';$script:netState.CancelSource.Cancel();$w.FindName('NetCancel').IsEnabled=$false}}})
$w.FindName('NetRefresh').Add_Click({Guard {RefreshNetwork}})
$w.FindName('NetFlushDNS').Add_Click({Guard {if(ConfirmDark 'Cache DNS' 'Svuotare la cache DNS locale? Non cambia i server DNS e non promette ping inferiore. La cache verra ricostruita automaticamente.'){Clear-DnsClientCache -ErrorAction Stop;$status.Text='Cache DNS svuotata'}}})
$w.FindName('NetApply').Add_Click({Guard {ApplyNetworkSelected}})
$w.FindName('NetRestore').Add_Click({Guard {RestoreNetwork}})
$w.FindName('NetGrid').Add_SelectionChanged({$r=$w.FindName('NetGrid').SelectedItem;if($r){$w.FindName('NetDetail').Text="$($r.Name) | $($r.Before) -> $($r.After) | PWU $($r.PWU)"+[Environment]::NewLine+$r.Note}})
$w.Add_Closed({StopNetworkTest})

foreach($id in @('Power','Storage','Graphics','GpuApp','Software','Features','Services','Diag','Updates','Audio','Apps','Debloat','Startup','Files','Backup')){
 $btn=$w.FindName($id);$btn.Tag=$id
 $btn.Add_Click({param($sender,$eventArgs) Guard {OpenPage ([string]$sender.Tag)}})
}
$w.FindName('Network').Add_Click({Guard {RefreshNetwork;$w.FindName('Tabs').SelectedIndex=4}});$w.FindName('Safe').Add_Click({SelectPreset 'Safe'})
$w.FindName('Gaming').Add_Click({SelectPreset 'Gaming'})
$w.FindName('Ultimate').Add_Click({SelectPreset 'Ultimate'})
$w.FindName('SelectAll').Add_Click({Guard {
 $null=$grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true)
 $pending=@(ReadJournal)
 $count=0
 foreach($r in $script:rows){
  $r.Selected=($r.Status -eq 'DISPONIBILE' -and !@($pending|Where-Object {$_.Path -eq $r.Path -and $_.Key -eq $r.Key}).Count)
  if($r.Selected){$count++}
 }
 $grid.Items.Refresh()
 if($script:stateFilter -eq 'Selected'){FilterRows};$status.Text="Selezionate $count modifiche disponibili. Incluse opzioni personali: controlla le conseguenze. Nessuna modifica applicata."
}})
$w.FindName('Clear').Add_Click({foreach($r in $script:rows){$r.Selected=$false};$grid.Items.Refresh();FilterRows})
$w.FindName('Scan').Add_Click({Guard {$path=SaveScan;$w.FindName('Report').Text=Get-Content $path -Raw;RefreshRows;$w.FindName('Tabs').SelectedIndex=1;$status.Text="Report: $path"}})

$w.FindName('Undo').Add_Click({Guard {if(ConfirmDark 'Ripristino completo' 'Ripristinare tutte le modifiche gestite dal programma? Le modifiche esterne non saranno sovrascritte.'){RestoreAll;RefreshRows;$status.Text='Ripristino verificato'}}})
$w.FindName('Apply').Add_Click({Guard {
 $null=$grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true);$null=$grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true)
 $sel=@($script:rows|Where-Object Selected)
 if(!$sel.Count){$status.Text='Nessuna modifica selezionata';return}
 $preview="ATTENZIONE: le opzioni personali possono limitare app, notifiche, funzioni browser e preferenze. Non tutte migliorano gli FPS. Verifica ogni voce prima di confermare."+[Environment]::NewLine+[Environment]::NewLine+(($sel|ForEach-Object {"$($_.Name): $($_.Before) -> $($_.After) | $($_.Note)"})-join [Environment]::NewLine)
 if(!(ConfirmDark 'Conferma modifiche persistenti' $preview)){return}
 $ok=0;$fail=0
 $script:activeBatch=SnapshotRecords $sel
 try{foreach($r in $sel){try{ApplyValue $r;$ok++}catch{$fail++;Event $r.Name '-' '-' $_.Exception.Message}}}finally{$script:activeBatch=$null}
 RefreshRows;$w.FindName('Tabs').SelectedIndex=2
 $status.Text="Operazioni verificate o gia configurate: $ok; errori: $fail. Puoi chiudere il programma. Alcune preferenze richiedono nuovo accesso."
}})
if($UiTest){
 $cl=$w.FindName('CategoryList')
 $cl.ItemsSource=@('Tutte','App Notifications','App Privacy','Audio','Browser','Debloat','Explorer','Gaming','Input','Notifications','Power / CPU','Privacy','Startup','Taskbar','Visual')
 $cl.SelectedItem='Tutte'
 $w.Opacity=0;$w.ShowActivated=$false;$w.ShowInTaskbar=$false;$w.Show();$w.UpdateLayout()
 foreach($sz in @(@(1280,820),@(970,650))){
  $w.Width=$sz[0];$w.Height=$sz[1]
  $w.Measure([Windows.Size]::new($sz[0],$sz[1]));$w.Arrange([Windows.Rect]::new(0,0,$sz[0],$sz[1]));$w.UpdateLayout()
  if($cl.ActualHeight -lt 1){throw 'Category layout not measured'}
  for($i=0;$i -lt $cl.Items.Count;$i++){
   $container=$cl.ItemContainerGenerator.ContainerFromIndex($i)
   if(!$container -or $container.ActualHeight -lt 1){throw "Category not laid out: $i"}
   $bounds=$container.TransformToAncestor($w).TransformBounds([Windows.Rect]::new(0,0,$container.ActualWidth,$container.ActualHeight))
   if($bounds.Bottom -gt $sz[1]){throw "Category clipped at $($sz[0])x$($sz[1]): $i"}
  }
  Write-Output ("CATEGORY LAYOUT OK: "+$sz[0]+"x"+$sz[1]+" | "+$cl.Items.Count+" visible")
 }
 # Synthetic catalog and journal in this test process only, no production settings changed.
 $script:rows=@(
  [pscustomobject]@{Name='One';Path='Software\Test';Key='one';Status='DISPONIBILE';Selected=$false},
  [pscustomobject]@{Name='Two';Path='Software\Test';Key='two';Status='DISPONIBILE';Selected=$false},
  [pscustomobject]@{Name='Already';Path='Software\Test';Key='three';Status='GIA CONFIGURATO';Selected=$false},
  [pscustomobject]@{Name='Pending';Path='Software\Test';Key='four';Status='DISPONIBILE';Selected=$false}
 )
 function ReadJournal { [pscustomobject]@{Path='Software\Test';Key='four'} }
 $script:rows[0]|Add-Member NoteProperty PWU 'High'
 $script:rows[1]|Add-Member NoteProperty PWU 'Medium'
 $script:rows[2]|Add-Member NoteProperty PWU 'Low'
 $script:rows[3]|Add-Member NoteProperty PWU 'Low'
 $grid.ItemsSource=$script:rows
 $w.FindName('SelectAll').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if(!$script:rows[0].Selected -or !$script:rows[1].Selected -or $script:rows[2].Selected -or $script:rows[3].Selected){throw 'Select all event failed'}
 $w.FindName('Clear').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if(@($script:rows|Where-Object Selected).Count){throw 'Clear event failed'}
 $script:rows[0]|Add-Member NoteProperty Category 'Gaming'
 $script:rows[1]|Add-Member NoteProperty Category 'Privacy'
 $script:rows[2]|Add-Member NoteProperty Category 'Gaming'
 $script:rows[3]|Add-Member NoteProperty Category 'Privacy'
 $w.FindName('PWUHigh').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if(@($grid.ItemsSource).Count -ne 1 -or $grid.ItemsSource[0].Name -ne 'One'){throw 'PWU High filter failed'}
 $w.FindName('StateDone').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if(@($grid.ItemsSource).Count){throw 'Combined filter failed'}
 $w.FindName('ResetFilters').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if(@($grid.ItemsSource).Count -ne 4){throw 'Reset filter failed'}
 $w.FindName('Filter').Text='One Gaming';if(@($grid.ItemsSource).Count -ne 1){throw 'Token search failed'}
 $w.FindName('Filter').Text=''
 UpdateDashboard
 if($w.FindName('Done').Text -ne '1 / 4' -or $w.FindName('Pending').Text -ne '1'){throw 'Dashboard separate counters failed'}
 ShowCategory 'Gaming';if(@($grid.ItemsSource).Count -ne 2){throw 'Category filter failed'}
 $w.FindName('SelectPage').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if(!$script:rows[0].Selected -or $script:rows[1].Selected){throw 'Visible selection failed'}
 foreach($id in @('Apps','Debloat','Startup','Power','Storage','Graphics','GpuApp','Software','Features','Services','Updates','Audio','Diag','Backup','Files')){
  $w.FindName($id).RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
  if($script:page -ne $id -or $w.FindName('Tabs').SelectedIndex -ne 3 -or $status.Text -like 'ERRORE:*'){throw "Page navigation failed: $id | $($status.Text)"}
  Write-Output ("PAGE OK: "+$id+" ("+$script:pageRows.Count+")")
 }
 $w.FindName('Network').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 if($w.FindName('Tabs').SelectedIndex -ne 4 -or $status.Text -like 'ERRORE:*'){throw "Network page failed: $($status.Text)"}
 $mock=@{Stage='TEST';Progress=100;Samples=@(10,13,12,15);Down=100.5;Up=20;Ping=12.5;Jitter=2;Loss=0}
 RenderNetworkTest $mock
 if($w.FindName('NetDown').Text -ne '100.5' -or $w.FindName('NetTrace').Points.Count -ne 4){throw 'Network HUD render failed'}
 Write-Output ("NETWORK UI OK: "+@($w.FindName('NetGrid').ItemsSource).Count+" compatible rows")
 $w.Close();Write-Output 'UI TEST OK - PWU, combined filters, token search, separate counters, category filters, select visible, all integrated pages';exit 0
}
$cpu=(Get-CimInstance Win32_Processor|Select-Object -First 1).Name
$gpu=(Get-CimInstance Win32_VideoController|ForEach-Object Name)-join ' / '
$w.FindName('Hardware').Text="Hardware rilevato: $cpu / $gpu"
RefreshRows;$status.Text='Scansione tweak completata. Nessuna modifica applicata. Seleziona un preset o singole voci.'
SetDarkChrome $w; $null=$w.ShowDialog()
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
