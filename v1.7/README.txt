BRABUS UTIL - CONTROL CENTER v1.7 BETA
Windows PowerShell 5.1 / Windows 11 tested. No AI or resident service.

New in v1.7:
- PWU (potential performance impact) per tweak: Low, Medium, High, with an explanation. These are qualitative estimates, not measured FPS gains. High is conditional on a material CPU power limit in the current configuration; it may be absent on an already optimized PC.
- Combined category, text, PWU and state filters, visible result count, reset, sortable PWU column. Selection is not application: review and confirm before applying.
- Section 02 category buttons use a fixed two-column layout, with no internal scrolling. Section 03 tools remain scrollable.
- Dashboard separates configured/compatible totals from pending backup records; the two previous counts were unrelated.

The 16 integrated pages from v1.6 are retained. System features, services, storage and Windows Update inventories are read-only; optional app removal and software installation require confirmation. External installers may open their own windows. Defender, firewall, UAC and Windows Update protections are not disabled automatically.
Backup v2 remains compatible with prior versions. Mirrored journal, snapshots and verified writeback are not a full system image. Keep personal reports and backups private. App removals may not be reversible.

Inspect the script and compare SHA256SUMS.txt before running. Windows PowerShell:
powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1
If a trusted verified download is blocked, use Unblock-File and process-only -ExecutionPolicy RemoteSigned. Respect organizational policy.

Passed on one Windows 11 PC: synthetic UI selection/filter and dashboard tests, 15 categories laid out at 1280x820 and 970x650, navigation of all 16 integrated pages, PWU ranking checks, registry backup/rollback and 9 power settings on inactive clone. Actual performance gains, other PCs and external installers are not guaranteed.
