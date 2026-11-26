BRABUS UTIL - CONTROL CENTER v1.6 BETA
Windows PowerShell 5.1 / Windows 11 tested. No AI or resident service.

New integrated main-window pages: installed apps, optional app removal, startup, power plans, storage, graphics, per-game GPU profiles, software center, Windows features, services, updates, audio, network/DNS, diagnostics, backup/recovery, logs/reports. Each has search, item count, current values, details, and contextual actions when available. Tweak categories and individual detail panels share the original catalog and backup system. Select visible and select all do not apply changes; explicit confirmation is required.

Windows services, system features, storage and Windows Update inventories are read-only for safety. Power, graphics, startup and notification preferences link to the relevant tweak category. Software installation and GPU executable selection can open native installer/file dialogs. Uninstalling optional apps requires confirmation; data and reinstall are not guaranteed. No automatic Defender, firewall, UAC or Windows Update changes.

Inspect the script and compare its SHA256 before running. On a personal computer, use Windows PowerShell 5.1:
powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1
After reviewing and verifying a trusted downloaded script, use Unblock-File if necessary and launch with process-only -ExecutionPolicy RemoteSigned. Respect organizational Group Policy.

Backup v2 is unchanged and compatible with v1.4/v1.5. Local snapshots, mirrored journal and verified registry/power writeback are not a full system image. Keep personal reports and backups private. Not every setting improves performance.

Passed on one Windows 11 PC: actual click handlers for category filtering, selection controls, all 16 internal pages populated/navigated, isolated registry rollback, duplicate catalog keys, mirrored backup recovery, conflict protection, migration, and 9 AC power settings tested on inactive cloned plan. No production tweaks applied by tests. App removals, software installs and real GPU changes were not exercised; compatibility on other PCs is unverified.
