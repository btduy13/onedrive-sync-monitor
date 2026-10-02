# v1.4.0 — guarded two-way repair

Added:

- Tracks remote SharePoint changes through a persisted Microsoft Graph delta cursor for files that already have a verified baseline.
- Pushes a changed local file only when the cloud ETag remains at that file's verified baseline.
- Pulls a changed cloud file only when the local signature/content remains at that file's verified baseline. Downloads land in a same-folder temporary file, are size-checked, then replace the local file atomically.
- Adopts a native OneDrive update without a second transfer when the local and cloud content already match.
- Stores SHA-256 content hashes so timestamp-only local metadata changes do not create false conflicts.
- Adds `-Once -Repair -RelativePath 'folder\\file.ext'` for a targeted guarded repair and `-Once -Repair -BaselineAll` for a safe inventory.

Safety rules:

- Timestamps never decide which side wins.
- If both local and cloud content changed, neither copy is overwritten; the file is reported for IT review.
- A local or cloud deletion is never silently recreated or propagated.
- A file present on only one side with no common verified baseline is not bulk-copied; it is reported for an explicit migration or restore decision.
- Delta polling only queues known baseline paths, so installing the tool never hydrates or copies an entire 400 GB library.
- The tool remains limited to the verified configured SharePoint library and ignores cloud-only Files On-Demand placeholders.

Validation:

- 153 offline regression assertions cover local-only push, cloud-only pull, two-sided conflict protection, native OneDrive adoption, deletion protection, legacy-state protection, unknown cloud-only protection, delta cursor persistence and explicit mode activation.
- Microsoft Graph authentication and a real Design-library repair still require acceptance testing on a machine with the verified Design mapping and its company credential.
