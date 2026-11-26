$ErrorActionPreference='Stop'
$p=Join-Path $PSScriptRoot 'BrabusDebloater.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if($e){throw 'Parser errors'}
foreach($n in @('BackupHash','ProfileId','PortableProfileId','NewPortableProfile','ResolvePortableProfile','IsApplyChoice','IsRestoreChoice','CaptureChoices','RestoreChoices')){
 $fn=$ast.Find({param($x)$x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n},$true)
 if(!$fn){throw "Missing $n"};. ([scriptblock]::Create($fn.Extent.Text))
}
function Row($path,$key,$kind,$value,$cat='Test'){
 [pscustomobject]@{Path=$path;Key=$key;Category=$cat;Name=$key;TargetState=[pscustomobject]@{Exists=$true;Kind=$kind;Value=$value};Selected=$true;CanApply=$true;CanRestore=$false;Status='DISPONIBILE'}
}
$src=@((Row 'POWER|source-plan|subgroup' 'setting' 'DWord' 100 'Power / CPU'),(Row 'NET|source-adapter' '*RSS' 'String' '1' 'Network'),(Row 'Software\BrabusTest' 'Example' 'DWord' 0),(Row 'Software\Personal' 'PrivateApp' 'DWord' 1 'App Notifications'))
$doc=NewPortableProfile @($src[0],$src[2],$src[3]) @($src[1]) $true
if($doc.Selections.Count -ne 3){throw 'Private identifiers not excluded'}
$dest=@((Row 'POWER|other-plan|subgroup' 'setting' 'DWord' 100 'Power / CPU'),(Row 'NET|other-adapter' '*RSS' 'String' '1' 'Network'),(Row 'Software\BrabusTest' 'Example' 'DWord' 0))
$r=ResolvePortableProfile $doc @($dest[0],$dest[2]) @($dest[1])
if($r.Eligible.Count -ne 3 -or $r.Unknown -or $r.Ambiguous){throw 'Portable matching failed'}
$changed=Row 'Software\BrabusTest' 'Example' 'DWord' 1
$duplicate=Row 'NET|second-adapter' '*RSS' 'String' '1' 'Network'
$r=ResolvePortableProfile $doc @($dest[0],$changed) @($dest[1],$duplicate)
if($r.Eligible.Count -ne 1 -or $r.Unknown -ne 1 -or $r.Ambiguous -ne 1){throw 'Changed target or ambiguity not blocked'}
$legacy=@{Format='BrabusPreset';Version=1;Selections=@((ProfileId $dest[2]))}
if((ResolvePortableProfile $legacy @($dest[2]) @()).Eligible.Count -ne 1){throw 'Legacy compatibility failed'}
$bad=@{Format='BrabusPreset';Version=2;Selections=@('Write-Host arbitrary')}
$rejected=$false;try{$null=ResolvePortableProfile $bad @() @()}catch{$rejected=$true}
if(!$rejected){throw 'Malformed profile accepted'}
$map=CaptureChoices $dest
$dest[0].CanApply=$false;$dest[0].CanRestore=$true
RestoreChoices $dest $map
if($dest[0].Selected -or !$dest[1].Selected -or !$dest[2].Selected){throw 'Pending selection not preserved safely'}
'PASS: portable power and adapter IDs, target binding, private category exclusion, legacy imports, ambiguous device rejection, pending selections'
