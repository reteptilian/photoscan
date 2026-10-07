# PhotoScan Work Slices

Living specification and progress tracker. Last updated: 2026-10-07.

## How to Maintain This Document

- Refine a slice's scope and acceptance criteria before implementation.
- Update its status, checkboxes, verification evidence, and remaining issues as work proceeds.
- Mark a slice done only when its acceptance criteria are verified. Distinguish automated checks from physical-device validation.
- Add links to relevant commits, tests, or supporting documents when available.
- Reorder or split slices as we learn; keep slice IDs stable so references remain useful.

Statuses: **Planned**, **Ready**, **In Progress**, **Waiting**, **Done**.

## Current Baseline

Implemented capabilities, with physical validation still incomplete:

- iPhone main-camera preview and full-resolution capture triggered from the Mac.
- Bonjour discovery, connection, image transfer, and front-only asset archives.
- Remote focus, exposure, and white-balance locking with settings recorded in metadata.
- Flat-field calibration and DKC-Pro neutral gray balance, with corrected TIFFs alongside originals.
- Print detection, manual corner adjustment, and perspective-corrected cropping.
- Synthetic protocol, calibration, crop, and archive tests.

User-confirmed: discovery and connection work after selecting the phone from the Cameras menu; a real image was captured and saved. Calibration accuracy and cropping on real prints remain unverified. Full multi-patch color calibration is deferred until the DKC-Pro charts arrive and their reference information can be checked.

See [README.md](README.md) for the current workflow, limitations, and test commands.

## Slice Tracker

| ID | Slice | Status | Dependencies / Notes |
| --- | --- | --- | --- |
| S01 | Validate the current workflow | Ready | Next priority; physical iPhone and real prints |
| S02 | Persistent calibration profiles | Planned | Build on S01 findings |
| S03 | DKC-Pro multi-patch color correction | Waiting | Charts and verified reference data |
| S04 | Multi-print extraction | Planned | Reliable crop workflow from S01 |
| S05 | Efficient batch scanning | Planned | S04; archive/session decisions |
| S06 | Metadata and OCR | Planned | Stable per-print assets |
| S07 | Archive browsing and export | Planned | Metadata contract from S06 |
| S08 | Front/back pairing | Planned | Optional; S04 and S05 for batch matching |
| S09 | Reliability and packaging | Planned | Incremental fixes throughout; final release checks |
| O01 | Live Mac preview | Planned | Optional; prioritize if phone positioning is cumbersome |

The order is a default, not a strict dependency chain. S03 can proceed when its reference information is available. Reliability fixes should happen when needed rather than wait for S09.

## Slice Specifications

### S01: Validate the Current Workflow

Goal: make the existing single-print workflow dependable and understandable with real hardware.

- [ ] Test repeated captures, locking/unlocking, and calibration with real prints on the iPhone 17 Pro.
- [ ] Check crop boundaries, orientation, perspective correction, and saved image dimensions against real examples.
- [ ] Make discovery, connection, processing, and failure states clear; verify reconnect behavior.
- [ ] Document the tested hardware setup, results, and unresolved issues.

Verification / progress: basic real capture confirmed; calibration and crop checks pending.

### S02: Persistent Calibration Profiles

Goal: reuse a scanning setup across sessions without accidentally applying an unsuitable profile.

- [ ] Load saved flat-field and gray-balance profiles and show the active profile identity.
- [ ] Check camera/settings compatibility and require confirmation that lighting and physical setup are unchanged.
- [ ] Remember the archive folder across launches with appropriate macOS access handling.
- [ ] Verify profile loading, missing references, incompatible settings, and app restart behavior.

Verification / progress: not started. Existing reference images and profiles are archived, but active profiles are currently session-only.

### S03: DKC-Pro Multi-Patch Color Correction

Goal: correct broader color errors using the user's DKC-Pro 5 x 7 inch charts.

- [ ] Verify the chart's own patch values, numbering, reference white point, and applicable revision.
- [ ] Provide patch selection and sampling with rejection of unusable or clipped samples.
- [ ] Fit and save a color matrix with reference provenance and fit-quality information.
- [ ] Support before/after review and integration with flat-field correction without double-applying gray balance.
- [ ] Verify synthetic behavior and results with the physical chart; preserve originals on failure.

Verification / progress: waiting for chart arrival and reference verification. Neutral gray balance is already implemented. Do not substitute Macbeth/X-Rite ColorChecker values or silently assume an unspecified white point.

### S04: Multi-Print Extraction

Goal: turn one capture containing several prints into individual archive assets.

- [ ] Review, add, adjust, and remove detected print boundaries before extraction.
- [ ] Save each accepted print as a separate asset linked to the original frame and calibration provenance.
- [ ] Verify missed detections, overlapping candidates, extraction failures, and preservation of the source frame.

Verification / progress: not started. Current cropping saves one reviewed crop under an existing asset.

### S05: Efficient Batch Scanning

Goal: scan a stack efficiently while keeping corrections and retakes organized.

- [ ] Provide a session view with thumbnails, progress, and predictable asset naming.
- [ ] Support retakes and rotation with an explicit policy for preserving or replacing prior versions.
- [ ] Verify a complete multi-capture session, including recovery from a failed capture.

Verification / progress: not started.

### S06: Metadata and OCR

Goal: make scanned assets searchable and understandable without losing uncertain information.

- [ ] Add editable titles, dates, people, and notes to a versioned metadata contract.
- [ ] Recognize text while retaining the source and allowing correction of uncertain OCR.
- [ ] Verify metadata persistence, older-record compatibility, and OCR editing.

Verification / progress: not started. Define representations for approximate dates and unknown values before implementation.

### S07: Archive Browsing and Export

Goal: browse existing work and create useful viewing copies outside PhotoScan.

- [ ] Open archives, browse assets, and distinguish originals from processed versions.
- [ ] Export viewing copies with selected metadata embedded where supported.
- [ ] Verify exports suitable for Apple Photos, including orientation, color, dates, and supported metadata.

Verification / progress: not started. Exact export formats and metadata mappings remain to be specified.

### S08: Front/Back Pairing

Goal: attach back images and their information to the correct front asset when needed.

- [ ] Add back capture without breaking existing front-only records.
- [ ] Support spatial pairing for batches flipped in place and manual correction of matches.
- [ ] Verify missing backs, changed layouts, retakes, and export behavior.

Verification / progress: not started; optional priority. Capture requests already carry an asset ID and front/back role, but the current writer creates new assets rather than updating existing ones.

### S09: Reliability and Packaging

Goal: make the apps trustworthy for sustained use and straightforward to install.

- [ ] Add device pairing and define the connection authentication/security model.
- [ ] Add acknowledged delivery and interrupted-transfer recovery, preventing duplicate or lost assets.
- [ ] Verify permission denial, disconnects, insufficient storage, and recovery across app restarts.
- [ ] Produce installable builds and document supported versions and release verification.

Verification / progress: not started. Current transfer is local TCP with no authentication; failures require a new capture. Address concrete reliability issues in earlier slices as they arise.

### O01: Live Mac Preview

Goal: frame and position prints while looking at the Mac.

- [ ] Stream a bounded-resolution preview without compromising full-resolution still capture.
- [ ] Show preview connection state and handle interruption/reconnection.
- [ ] Verify latency, orientation, and capture behavior on the physical devices.

Verification / progress: optional; a natural fit between S02 and S04 if positioning becomes a bottleneck.

## New Slice Template

Copy this section when adding future work:

```markdown
### SXX: Slice Name

Status: Planned
Goal:
Dependencies:
Scope:
Deferred work:

Acceptance criteria:
- [ ] Observable outcome
- [ ] Relevant failure/recovery behavior
- [ ] Verification completed

Verification / progress:
Open decisions / remaining issues:
Links to commits, tests, or supporting documents:
```

## Decision Log

| Date | Decision |
| --- | --- |
| 2026-10-07 | Preserve original captures; save processing outputs alongside them with provenance. |
| 2026-10-07 | Use DKC-Pro-specific references for future color fitting; keep neutral gray balance separate. |
| 2026-10-07 | Hold multi-patch color fitting pending reference verification; implement reviewed print cropping first. |
| 2026-10-07 | Prioritize physical validation, then persistent profiles. |
