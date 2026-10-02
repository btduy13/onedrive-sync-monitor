# v1.4.1 — guarded two-way repair and explicit historical resolution

This release provides two safe paths for OneDrive/SharePoint repair:

- **Unattended guarded repair:** after the tool has recorded a verified local/cloud baseline, a local-only change is pushed and a cloud-only change is pulled. A Graph delta cursor detects remote changes even without a local Windows event.
- **One-file IT resolution:** after inspecting a historical mismatch, IT can explicitly choose the source for exactly one path:

  ```powershell
  & "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveCloudBackup.ps1" `
    -Once -Repair -RelativePath 'folder\file.ext' -ResolveWith Local

  # Or use the cloud copy as the selected source:
  & "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveCloudBackup.ps1" `
    -Once -Repair -RelativePath 'folder\file.ext' -ResolveWith Cloud
  ```

`-ResolveWith` never runs in the watcher, requires exactly one relative path and records a new verified baseline after a successful transfer.

Safety behavior:

- No automatic decision is made from timestamps.
- Both-sided changes, one-sided files without a baseline, legacy one-way state, deletes and renames remain conflicts unless IT makes an explicit one-file decision.
- Pulls use a same-folder temporary file, Graph-size verification, a second local signature check and an atomic replacement.
- Historical state written by older releases is not trusted as proof that two copies matched.
- The worker never bulk downloads, hydrates cloud-only placeholders, or copies the 400 GB library on installation.

Validation: 156 offline regression assertions pass. The installer package was preflight-tested without system or tenant changes; real Graph repair still requires acceptance testing on the computer with the verified Design library mapping and its certificate credential.
