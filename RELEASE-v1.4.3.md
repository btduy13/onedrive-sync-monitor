# v1.4.3 — safe legacy-state migration

The all-in-one Design installer now recognizes an incomplete legacy personal/one-way backup configuration. If that legacy configuration has a `cloud-backup-state.json`, it moves the state to a uniquely named `.before-company-...bak` archive before saving the verified Design configuration. Nothing is deleted.

A complete configuration for another verified SharePoint library is still never repurposed automatically; setup stops and leaves its state intact for IT migration.

This release retains guarded two-way repair: known verified files are pushed or pulled only when exactly one side changed; two-sided changes require review. IT can make an explicit one-file decision with `-ResolveWith Local` or `-ResolveWith Cloud`.

Validation: 159 offline regression assertions, installer preflight/hash verification, and a real local monitor/tray run. The installer remains unsigned and needs an IT-approved deployment channel if Windows policy blocks it.
