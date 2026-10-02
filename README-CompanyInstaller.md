# Aspect Design all-in-one installer

Run `OneDriveSyncMonitor-AspectDesign-AllInOne-v1.4.3.exe` as the Windows user who works with the Design library. No tenant ID, application ID, URL, thumbprint, test-file path or yes/no configuration questions are required. Do not use **Run as a different Windows user**.

The package includes Microsoft.Graph.Authentication 2.41.0. An internet connection to Microsoft 365 is still required.

## What it does

- Stops this user's previous monitor/backup instances and preserves config, logs, certificates and backup state.
- Installs the tray app and logon startup.
- Detects the exact local Design library from verified sync mappings or an existing verified SharePoint config. Never guesses from a folder name. A missing/ambiguous mapping stops cloud setup.
- Creates or reuses a non-exportable certificate in the current user's Windows certificate store.
- If the PC has no working cloud credential, opens Microsoft sign-in for an authorized IT administrator. Enrolls only the public certificate, `Sites.Selected` app permission and `write` access to the Design site. The background worker never uses the administrator session.
- Verifies a unique small text file through Graph upload and download/hash comparison, then enables backup and checks a fresh background heartbeat. The test file is retained in the cloud as evidence; it contains only a timestamp and random nonce.
- Records a per-file baseline and uses Graph delta polling for guarded repair: local-only changes after that baseline can be pushed, cloud-only changes can be pulled, and matching native OneDrive changes are adopted without a duplicate transfer.
- Lets IT resolve one inspected historical conflict deliberately with `-Once -Repair -RelativePath 'folder\file.ext' -ResolveWith Local` or `-ResolveWith Cloud`; this is never part of the unattended worker.
- Preserves email on/off preferences. It does not send a test email or enable email that was disabled.

## Honest completion status

Read `%LOCALAPPDATA%\OneDriveSyncMonitor\company-setup-result.json` for `BackupVerified`, `SourceRoot`, `LibraryWebUrl`, `ProbeFile` and `RemoteAlerts`.

`NotConfigured` means Teams/email cannot be delivered: a fresh machine has no webhook. This public package deliberately contains no shared webhook, password, private certificate or administrator token. The existing endpoint on an already configured PC is retained. Zero-touch alerts on new PCs require a separate company-managed deployment of the endpoint.

Microsoft sign-in, MFA and tenant approval cannot be bypassed by an installer. The signing-in administrator must have sufficient Entra and SharePoint rights. Tenant policy can block this enrollment; the installer reports incomplete setup rather than claiming success. Fully silent fresh-PC authentication requires IT-managed certificate provisioning.

Run enrollment on one PC at a time. Updating an app's public certificate list is a read/merge/write operation; do not concurrently enroll machines or edit the app's certificate list. No existing credential is intentionally removed.

This package does not bulk upload the 400 GB library, download online-only placeholders, delete cloud files, or replace Microsoft OneDrive. It repairs only files with a verified prior baseline. If both copies changed, or a file exists on only one side without a baseline, it preserves both sides and reports a conflict for IT review. Existing historical sync failures require an explicit review/inventory; installation never selects a winner from timestamps alone.

If this computer only has a legacy personal/one-way cloud-backup config, the installer archives its old `cloud-backup-state.json` beside the original before writing the verified Design configuration. It does not delete that state. A complete configuration for a different verified SharePoint library is never repurposed automatically; setup stops for IT migration instead.

`OneClick-Uninstall.cmd` removes this user's app/startup entries and keeps config, logs, state and certificates. Entra certificate registration and site permissions remain until IT explicitly revokes them.

The EXE is unsigned. If company policy blocks it, use IT-approved software deployment; do not disable Defender or other security controls. The ZIP is an alternative container, not a security-policy bypass.
