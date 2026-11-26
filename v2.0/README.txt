BRABUS UTIL - CONTROL CENTER v2.0 BETA
Windows PowerShell 5.1 / Windows 11. No AI, resident service or auto-applied tweaks.
Public beta. Review the source and hash before running. Previous v1.7 remains available.

FEATURES
- Device-aware catalog, PWU (qualitative impact, not measured FPS), combined filters, responsive sidebar and internal pages.
- Network Center: two parallel HTTPS transfers per direction for up to 14 seconds each; idle and loaded ICMP ping; jitter, loss and local history. Up to 1 GB download + 300 MB upload and overhead. Server errors or cap may shorten a test.
- Separate apply/restore selection, per-item readback, verified mirrored backup and selective rollback. Full GUI restore includes driver and user/power journals. Conflicting external values are not overwritten.
- Integrity page: reads current values against original/target backup values, reports restart requirements and conflicts.
- Portable profile v2: exports catalog targets actually detected, or imports legacy v1. IDs bind the target semantics; no raw registry values, adapter GUIDs, executable paths, backups or history. App-specific notifications and per-game GPU profiles excluded. Ambiguous or unsupported targets skipped. Import only selects compatible rows: apply general and network selections separately after review. Pending selections survive refresh after applying the other tab.
- Driver writes require administrator privileges and a manual restart. Registry/power readback is not proof of runtime effect. Some settings are preferences rather than optimizations. No automatic changes to Defender, firewall, UAC or Windows Update.
- Services/features/Windows Update inventories are read-only. App removal and installers are separate confirmed actions; app data recovery not guaranteed.

LAUNCH
Close any previous BRABUS UTIL window.
powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1
If needed, review and verify a trusted download before Unblock-File; use process-only -ExecutionPolicy RemoteSigned. Respect organizational policy.
-ReleaseCheck produces a local read-only summary. -ExportCurrentProfile requires a new output path. -Undo restores the original user/power journal only; use GUI for network restoration.
Backups and speed history remain in the existing local state folder. Keep them private; they are not full system images.

TEST SCOPE
Parser, registry isolated writes and rollback, simulated driver writes and rollback, actual readback audit on one Windows 11 PC, inactive power-plan tests, portable profile matching including simulated hardware differences, UI navigation and checkbox selection, history and filters. Actual live driver changes, independent PCs, FPS gains and installer execution are not certified. This is a beta, not a claim of universal 100% functionality.
