# OneDrive Sync Monitor: multiple libraries

Run `Setup-MultiLibrarySync.cmd` from the all-in-one ZIP, or open the matching EXE if company policy permits it. Setup detects business OneDrive and SharePoint libraries from this Windows account's OneDrive registry mappings. No site, folder, or machine name is hard-coded in this mode.

Double-click the tray icon, or choose **Mở bảng theo dõi**, to open the dashboard. It shows whether the alert monitor and multi-library sync supervisor are running, each library's status, tracked and pending file counts, last-cycle transfers, last check time, local/cloud paths, and errors. It refreshes every 10 seconds and never initiates a repair by merely opening the window. The tray menu **Trạng thái từng thư viện** still opens the raw `%LOCALAPPDATA%\OneDriveSyncMonitor\libraries\status.json` for IT. Each library has its own `config.json`, `permission.json`, `state.json`, `scan.json`, and `status.json` under a stable ID. `Discovered` means local mapping only. `ReadVerified_WriteNotVerified` means Graph read access works. `WriteVerified` means a unique remote test file was written and read back. `Scanning` means the initial local traversal is incomplete. `Monitoring` means at least one verified local/cloud baseline exists and the repair loop is running. `BaselineRequired`, `Pending`, `NeedsReview`, and `Blocked` are not success states.

Version 1.6 adds UI tabs for the actual pending paths, supervisor/Graph controls, IT alert settings, webhook enrollment, and the monitor log. Select a library in **Tổng quan** before inspecting **Hàng đợi**. The pending count is a work queue, not a count of failed uploads. Manual **Máy → cloud** or **Cloud → máy** actions apply only to the selected pending file, require confirmation, and temporarily pause the supervisor. They may replace the opposite copy, so inspect both versions first. The webhook is accepted through a hidden input, protected with Windows DPAPI for the current user, and never displayed again. If company policy blocks the EXE installer, use the ZIP and `Setup-MultiLibrarySync.cmd`.

Initial cloud sign-in, if needed, must run in the logged-in Windows account:

```powershell
$app = "$env:LOCALAPPDATA\OneDriveSyncMonitor\MultiLibrarySync.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -Authenticate -Once
```

Verify write access for **one selected library** by passing its ID from `status.json`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -Authenticate -VerifyWrite -LibraryId <library-id>
```

This creates one `OneDriveMonitor-PermissionProbe-*.txt` file in the selected cloud library. It does not grant permissions or upload existing production files. The verification command checks only the selected library. Other libraries continue in read-only status until independently verified. An expired Graph cache requires another foreground sign-in. The background supervisor reports `Blocked` instead of waiting indefinitely for a hidden sign-in prompt.

After write verification, a newly saved, hydrated local file (non-empty, up to 250 MB) is created in the matching cloud library using a create-only upload session. The app reads the cloud file back before recording a verified baseline. Later local-only changes are pushed, and cloud-only changes to that tracked file are pulled. Concurrent edits, independent deletions, cloud-only files with no baseline, placeholders, and different initial copies require review. The initial scan is incremental; a large library takes multiple cycles. `Scanning` means this first pass is still traversing folders, not that files were synchronized. FileSystemWatcher places newly saved local files ahead of older backlog entries, with a 60-second quiet period before repair. No bulk download or blind overwrite is performed. A `Pending` or `BaselineRequired` library is not proof that every file is synchronized; inspect its pending count, error, and most recent cycle.

When safe recovery is enabled, the alert monitor also watches the multi-library supervisor. If auto-start remains enabled but its process disappears, the monitor starts only its installed script. It respects manual stop and interactive repair, checks the exact startup command and supervisor mutex, and waits five minutes before another attempt. A running but stalled supervisor is reported, not forcibly killed.

Email remains controlled by the existing **Send mail to IT** setting. The installer preserves the current setting and never embeds a Power Automate webhook.
