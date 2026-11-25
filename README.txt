BRABUS UTIL - ONE-SHOT DEBLOATER v1.4 BETA
Windows PowerShell 5.1 / Windows 11 tested. No AI or background service.
Extract all files to a folder. Review the script and compare SHA256SUMS.txt with the sender.
Open PowerShell in the extracted folder, then run:
powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1
If Windows blocks a downloaded script, inspect it first and verify its hash; only if trusted, use Unblock-File -LiteralPath .\BrabusDebloater.ps1. Do not change system execution policy.

Scan, select compatible tweaks, review before/after, confirm, verify and close.
The backup engine stores snapshots, a primary journal and a mirror with SHA256 integrity checks and user ownership validation under LOCALAPPDATA\BrabusPC-Debloater-State\backup-v2. Recovery Center supports selective restore; -Undo restores managed changes from the command line. Keep local backup files. They are not a full system backup and both copies are on the same disk. App removals and external tools may not be reversible; review separate warnings before proceeding.
Power settings are opt-in, desktop AC only. Do not run concurrent optimizers. No FPS guarantees. Some settings depend on Windows build or edition. Software IDs are candidates checked live before installation. Services and Windows feature inventories are read-only/guided.
Tested on one Windows 11 PC: isolated registry rollback, selective recovery, corrupt journal fallback, conflict protection, legacy migration, six AC power settings on an inactive clone, UI loading. Actual production changes, software installs, app removals and broad compatibility remain unverified. Use as a beta, not a guaranteed stable release.
Do not share personal reports or backup files; this ZIP contains program and tests only.