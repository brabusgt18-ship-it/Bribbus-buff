BRABUS UTIL - CONTROL CENTER v1.7 NETWORK BETA
Windows PowerShell 5.1 / Windows 11 tested. No AI or resident service.

NETWORK CENTER:
- Dedicated integrated speed test HUD, download/upload in Mbps, 10 ICMP pings to 1.1.1.1, mean latency, mean absolute difference between successive successful pings (jitter), ICMP loss and graph.
- Single HTTPS connection to Cloudflare speed.cloudflare.com with 25 MB download and 5 MB synthetic random upload; explicit confirmation, progress and cancel. Estimates are not multi-stream benchmarks. Test service sees your IP and requests; no personal files are uploaded.
- Active adapter link speeds, configured DNS, adapter error/discard counters, TCP auto-tuning status, optional DNS cache flush.
- 16 allowlisted driver-property types, where present and supported by physical active adapters: RSS, RSC, LSO, interrupt moderation, EEE, checksum offload, UDP segmentation, packet coalescing and selective suspend. Only valid driver values offered. Browser network-related tweaks from existing catalog also appear here.
- Driver changes require administrator privileges, explicit confirmation and a manual restart; no automatic restart. No guaranteed benefit; latency and throughput tradeoffs may occur. Network driver backup uses separate mirrored journal filenames in existing backup-v2 folder; restore via NETWORK CENTER / RIPRISTINA DRIVER. Previous versions and ordinary -Undo handle the original journal only.
- No automatic DNS server changes, TCP registry recipes, adapter resets, security or firewall changes.

Existing V1.7 features: PWU Low/Medium/High qualitative performance rating, combined search/category/state filters, all 15 category choices visible, separate dashboard counts, original integrated tools and recovery. Backup v2 remains compatible for original tweaks; no full system backup. Keep private reports and backups local.

Review the script and verify SHA256SUMS.txt. Run in Windows PowerShell:
powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1
For a trusted verified download, Unblock-File and process-only -ExecutionPolicy RemoteSigned if required; respect organizational policy.

Tests: 16 internal pages including Network Center navigation, simulated HUD rendering, full real speed test on one PC, separate network backup/restore with mock adapter, registry and power backup tests. Actual driver writes not tested on a live adapter; other PCs and actual performance gains not guaranteed.
Sources: https://github.com/cloudflare/speedtest ; https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapteradvancedproperty ; https://learn.microsoft.com/en-us/windows-hardware/drivers/network/standardized-inf-keywords-for-network-devices
