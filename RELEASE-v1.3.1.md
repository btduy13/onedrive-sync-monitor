# v1.3.1 — audit remediation, partial readiness

Fixed:
- Reconcile locally available files on watcher startup, every five minutes and after lost watcher events. Cloud-only placeholders are not hydrated.
- Process directory events; reject file links and linked ancestors.
- Compare remote content before adopting an ETag change. Never silently adopt a different remote file when the baseline ETag is empty. Unknown/different cloud content remains a conflict, not an automatic overwrite.
- Keep authentication failures visible until authentication succeeds. Monitor checks backup failure and successful-cycle time, not just heartbeat.
- Unreadable/incomplete diagnostics cannot report Healthy.
- Increasing error counters respect the reminder interval. Offline alerts coalesce to current state. Cloud failure alerts are limited to one attempt per hour.
- Tray shows stopped/stale status and identifies monitor instances by exact script path and current-user SID.
- Safe recovery starts a trusted Microsoft-signed OneDrive executable when stopped, with persistent 30-minute cooldown. No reset, forced restart, unlink or file deletion. Set SafeRecoveryEnabled=false in config.json to disable.
- Company setup disables unsigned automatic updates before workers start and explicitly reports OverallReady=false until remaining deployment checks are fulfilled.

Important limitations:
- No code-signing certificate is available. This unsigned installer may still be blocked by company policy. No security-policy bypass is supplied.
- Certificate-mode automatic updates remain disabled pending trusted signed-update infrastructure.
- A new computer still requires authorized certificate enrollment and a provisioned alert endpoint. No shared private key, administrator credential or webhook secret is embedded.
- The watcher runs independently after enablement, with a one-minute quiet period for file events; it is not a replacement bidirectional sync client. Genuine conflicts require review; remote deletions are not propagated.
- Existing records from old manual baselines are not retroactively proof of content equality. Large-file equality above the comparison limit fails closed and may require conflict review.
- Installation's probe verifies the Graph upload path and worker heartbeat, not full end-to-end watcher upload or email arrival. Actual acceptance testing on AES-VN-LOCALSER is still required.
- Tray test-alert feedback, full backup controls, desktop shortcut and graceful restart of stalled (still-running) OneDrive remain follow-up work.

Validation: offline regression suites and Windows PowerShell 5.1 compilation. No production upload, email, certificate enrollment, live install or uninstall performed during this fix.
