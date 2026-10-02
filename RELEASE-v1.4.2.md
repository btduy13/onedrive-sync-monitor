# v1.4.2 — guarded repair package

This is the company installer release for guarded two-way repair:

- A verified per-file baseline permits unattended local-to-cloud push or cloud-to-local pull when only one side changed.
- Microsoft Graph delta polling detects remote updates for known baseline files.
- Two-sided changes, deletion/rename cases and historical mismatches remain conflicts; timestamps never choose a winner.
- IT can deliberately resolve one inspected path with `-Once -Repair -RelativePath 'folder\file.ext' -ResolveWith Local` or `-ResolveWith Cloud`. This command cannot run in the unattended worker or against a folder/bulk selection.
- Pulls are temporary-file, size-checked and atomic; legacy one-way state is not trusted as a verified baseline.

Validation: all 156 offline regression assertions pass, the all-in-one package preflight completes without system or tenant changes, the EXE hash matches its manifest, and the installed monitor/tray completed a real local monitor cycle. Live Graph repair remains to be accepted on the machine with the verified Design library mapping and company certificate.

The installer is unsigned. Company policy may block it; use an IT-approved deployment channel rather than disabling security controls.
