BRABUS UTIL - CONTROL CENTER v1.7 NETWORK BETA
Windows PowerShell 5.1 / Windows 11 tested. No AI or resident service.

NETWORK CENTER:
- Dedicated integrated speed test HUD, download/upload in Mbps, 10 ICMP pings to 1.1.1.1, mean latency, mean absolute difference between successive successful pings (jitter), ICMP loss and graph.
- Sequential HTTPS requests to Cloudflare speed.cloudflare.com with two approximately 12-second adaptive sequential HTTPS measurement phases, up to 1 GB download and 300 MB synthetic random upload; explicit confirmation, progress and cancel. Estimates are not multi-stream benchmarks. Test service sees your IP and requests; no personal files are uploaded.
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

Layout update: compact three-column categories and two-column tools/presets, one rounded sidebar scrollbar; verified 40/40 items visible at 1440x900 and reachable by scrolling at smaller sizes. Network multi-select checkboxes and select/clear-all verified; configured or backed-up entries excluded. Long speed test: 26.5 seconds on test PC, 17 completed download and 14 upload requests; server denial stops measurement and reports partial result. Data cap may shorten test. No live driver writes performed.

History update: local speed-history.json in existing state folder, last 1000 completed or partial tests, no retroactive imports; cancelled tests are not recorded. Comparison uses the latest two complete tests of the same measurement method and a local fingerprint of detected network settings, not proof of causal improvement. Tweak status is refreshed from current values and journal targets after application: verified registry or active power-plan value, driver saved/restart required, verified configured driver value after later Windows boot, browser restart required, mismatch or verification error. Driver runtime effect and actual performance gain are not established by registry readback. Tests passed: isolated real registry write, mismatch detection, rollback; simulated driver pending/post-reboot/mismatch/rollback; history persistence, duplicate handling, partial exclusion and comparison; original UI, backup and power tests. No real driver modifications performed.

Routing fix: footer Apply and sidebar Select All/Clear now use the active Settings or Network Center selection. Footer displays selected network count; non-admin driver operations are rejected before writing. Tab changes preserve network selections until explicit refresh or application. Existing backup and readback requirements remain unchanged.

Speed Lab V2 supersedes prior speed-test descriptions: two parallel HTTPS flows per direction for up to 14 seconds each, idle and loaded ICMP latency. Download counts actual bytes read; upload counts successful acknowledged requests, so final incomplete uploads are excluded. Existing 1 GB down / 300 MB up payload limits may shorten measurement. The result is an estimate, not a certified ISP test. History retains method identifiers and compares complete results of the same method only. Tested live: 31.2 seconds; UI and history regression passed. Uses documented Cloudflare test endpoints, not the official Cloudflare JavaScript library or Fast.com. No real network driver changes.
