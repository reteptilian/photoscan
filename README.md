# PhotoScan

See [ROADMAP.md](ROADMAP.md) for work slices, acceptance criteria, and progress.

PhotoScan remotely captures one or several prints on an iPhone, preserves the camera source on a Mac, and publishes a finished scan after crop review.

## Run

1. Open each Xcode project. Run PhotoScanCamera on a physical iPhone and PhotoScanDesk on the Mac.
2. Allow Camera and Local Network access. Keep the iPhone app in the foreground with both devices on the same Wi-Fi network.
3. On the Mac, choose an Archive Folder, then choose the phone from Cameras.
4. Press Capture. The source is saved first and print boundary review opens automatically. Review every numbered suggestion, select a print to adjust its corners, Add Print for missed detections, and Remove false suggestions. Extract Prints saves each accepted boundary as an individual asset; overlapping boundaries must be adjusted or removed first. Explicit Skip Crop publishes the full frame. Cancel leaves the frame pending; Review Prints reopens review, and Skip Crop Review publishes the full frame.
5. After extraction, use the Print picker to select an individual finished scan. Review Prints adjusts that print’s existing crop. Metadata, rotation, preview, Finder, and exports apply to the selected print.
6. Edit Metadata to add the original document date, title, description, labels, and people. Rotate Right changes the finished orientation. Accepted changes regenerate the finished image from the source.
7. Finished is the default preview. Source explicitly compares the untouched camera image. Show in Finder always reveals the finished HEIC; Reveal Source opens the camera source. Export offers JPEG and 16-bit TIFF without replacing existing files.

A pending scan has no finished preview or finished Finder action. If processing fails, the source remains saved. If regeneration fails, the previous finished preview, filename, and manifest remain valid. A pending scan cannot currently be reopened after app restart through the UI; archive browsing is S07.

## Archive and Names

```text
<archive>/
  .archive.lock
  .next-index.json
  <asset UUID>/
    unknown-date_000001.heic
    metadata.json
    sources/
      capture.heic              # capture.jpg for actual JPEG sources
  <extracted print UUID>/
    unknown-date_000002.heic
    metadata.json               # sourceAssetID references the captured UUID above
  _calibrations/
    <profile UUID>/
      reference.heic            # or reference.jpg
      profile.json             # flat field
      gray-balance.json         # gray balance, in its own profile directory
```

The UUID is the asset identity. Source bytes, including their camera metadata, remain exactly as received. HEIC is the default finished output; there are no separate corrected or cropped TIFF artifacts. A pending asset contains only sources/ and metadata.json.

Names use the original document date's actual precision: `1956-07-12_000042.heic`, `1956-07_000042.heic`, `1956_000042.heic`, or `unknown-date_000042.heic`. Indices start at 1, are padded to at least six digits, and remain stable through date edits. Approximate dates use the same token and retain their qualifier in metadata. Unknown dates never use the scan date. Gregorian dates are validated, including leap days; optional original time uses `HH:mm:ss` and requires an exact full day.

An archive-wide advisory process lock serializes writers. The allocator persists its next index before saving and checks existing asset manifests as well, so restarts and imported higher indices do not reuse an index. Failed saves may leave gaps. Duplicate asset IDs, indices, and destination filenames block writes. Indices are unique within an archive, not globally across independent archives. There is no import UI yet; manually introducing conflicting records will prevent their regeneration. Keep unrelated files outside asset directories.

Schema 2 metadata.json is authoritative. It records the UUID, stable index, capture/scan timestamp and camera settings, relative source relationship, document fields (including partial/uncertain dates and people), accepted recipe, complete calibration profiles with reference provenance, crop corners, quarter-turn rotation, and finished dimensions/revision/filename. The recipe keeps the calibration used at capture time; clearing or replacing an active calibration affects subsequent captures. Extracted prints carry sourceAssetID pointing to the captured UUID directory, with sourceFile relative to that shared frame. The frame records extractedAssetIDs and retains the camera bytes once; children have their own UUIDs, indices, metadata, recipes, and finished HEICs, with no sources/ copies. Keep the shared frame directory with its children. Its reserved index is not used for a finished print after extraction.

Supported embedded metadata: IPTC ObjectName (title), CaptionAbstract (description/notes), Keywords (labels). EXIF DateTimeOriginal is written only when both an exact original day and original time are supplied. Day-only, partial, and approximate dates remain in metadata.json without an invented midnight. ImageIO dropped standalone IPTC DateCreated in the HEIC readback test, so this field is not treated as a supported embedding. No camera scan datetime is copied into the finished image's original-date fields. People and uncertainty remain in JSON. Metadata is read back and verified before publication, including removal of a previously supplied original datetime.

Processing decodes the oriented source into a floating-point linear-light pipeline, applies flat field, gray balance, perspective crop/edge trim, and rotation, then rasterizes once at 16-bit precision and encodes once per revision. The tested macOS HEIC encoder produces **10-bit** output from this input; JPEG is a lossy compatibility export and TIFF retains 16 bits. Exports also render from the source and accepted recipe rather than recompressing the finished HEIC.

Regeneration copies the asset into a hidden staging directory, renders and verifies the image and metadata there, then atomically swaps the entire asset directory with macOS `RENAME_SWAP`. The previous directory is removed only after a successful swap. Readers see a complete previous or new revision; failure leaves the previous directory intact. This requires a filesystem supporting atomic directory exchange (verified on the local filesystem; external/network archive volumes are unverified). A failed exchange preserves the previous revision. Interrupted staging directories may remain hidden; crash cleanup and power-loss durability are future reliability work. Do not modify an archive concurrently using software that ignores its lock.

Prototype archives are unsupported. Use a new archive folder; there is no migration, compatibility reader, or deletion of old user files.

## Capture and Camera Settings

Shared/ScanProtocol.swift is compiled into both targets. Bonjour discovery on the shared LAN and Network.framework TCP carry versioned, length-prefixed JSON headers followed by original image data, bounded to 100 MiB per message. Both apps exchange a `hello` before enabling capture, including app/build numbers, protocol version, and capabilities. App versions may differ; both must support protocol 1 and `capture.front`. Optional `capture.progress` reports phone capture/transfer stages; the Mac also shows incoming image progress and includes the last stage in capture timeouts. Optional `settings.lock` and `capture.settings` capabilities enable settings controls and calibration respectively (calibration requires both). Missing or incompatible handshakes close the connection with an update message; connection establishment (including Bonjour resolution) times out after 20 seconds, and the handshake times out after 10 seconds once TCP is ready. The Mac shows Connecting to camera, Checking camera compatibility, then Waiting for camera readiness; the final readiness message also has a 10-second deadline. A timeout leaves Capture disabled with a reconnect message rather than waiting indefinitely. Builds from before this handshake was introduced must be updated on both devices. Keep protocol 1 for backward-compatible optional fields/capabilities; increment it when commands, required fields, or their meaning change incompatibly. App/build numbers are shown in the Desk connection status tooltip for diagnostics. Peer-to-peer AWDL networking is disabled: both devices must use the same LAN (the Mac may use Ethernet). TCP keepalives and a 20-second retransmission deadline help release broken connections and the phone’s single-client slot. These changes are a mitigation for observed network-flow setup failures, not verified recovery from an iOS network subsystem failure. One Mac connects at a time. Disconnects and a 60-second capture timeout clear pending requests. Capture requests carry a frame ID and front/back role; reviewed front boundaries produce individual assets linked to that frame. Pairing is future work.

The iPhone uses the physical main wide-angle camera with flash off and quality prioritization, requesting the largest photo dimensions supported by the active format. Actual resolution depends on device and conditions. Preview and still orientation are portrait.

The Mac shows ISO, exposure, focus, white balance temperature/tint, and requested maximum dimensions. Lock Settings waits for autofocus, exposure, and white balance to settle for roughly half a second, then locks them. Settling times out after eight seconds. Unlock Settings restores automatic adjustment. Capture is disabled while a command is pending. Reconnecting reports the phone's current lock state.

Capture metadata records a device settings snapshot, including white balance gains. Optional photoISO and photoExposureSeconds come from the processed photo's EXIF and can differ from preview readings. Focus and white balance are device values. Locking uses AVFoundation's [device configuration API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lockforconfiguration/); exposure readings use [capture metadata](https://developer.apple.com/documentation/avfoundation/avcapturephoto/metadata).

Local TCP has no authentication or encryption; use a trusted network. Pairing and retryable delivery are future work. Folder selection lasts for the app session. A physical iPhone is required for capture/discovery validation.

For wireless testing after USB installation, stop the iPhone run in Xcode, unplug, launch PhotoScanCamera from the Home Screen, and then select it on the Mac. Start a fresh PhotoScan connection after changing network routes. The app uses TCP/Bonjour independently of Xcode’s debugger. Repeated `NECP_CLIENT_ACTION_ADD_FLOW [17: File exists]` / `Failed to create connection from listener` messages indicate an OS-level network-flow setup failure; the logs alone do not establish its cause. Both ordinary Wi-Fi and AWDL failures were observed during physical testing. If a fresh standalone launch still has those errors, restarting the phone is a useful way to test whether stale OS network state is involved.

Diagnostics are persisted without Xcode. The Mac **Logs** button reveals `diagnostics.log` in its sandbox Library/Logs/PhotoScan directory, normally `~/Library/Containers/name.esbensen.PhotoScanDesk/Data/Library/Logs/PhotoScan/diagnostics.log`. This file is directly readable by Codex during debugging; no console copy/paste is required for app diagnostics. Each log rotates at 2 MiB, retaining one `diagnostics.previous.log`. The phone stores its own log under Documents/Diagnostics and relays recent history (up to 64 KiB) plus live transport events to the Mac when `diagnostics.relay` is supported. Disconnected phone events remain local; **Prepare/Refresh Diagnostics**, then **Share Diagnostics** exports a stable snapshot for sharing to the Mac. App error messages are logged locally; failed file logging does not interrupt networking or capture. Apple’s internal Fig/Network framework messages are not copied into these files and still require system-console access.

Transport diagnostics also use the `PhotoScan` logging subsystem / `Transport` category, with a short connection ID. They record connection states, available interfaces and active interface types, viability changes, command receipt, camera completion, frame sizes, incoming progress in 5% steps, and TCP send completion. TCP send completion does not prove receipt by the remote app. Crop diagnostics record the reviewed asset ID, detector, raw confidence, normalized corners, and retained/discarded outcome. No image pixels or document metadata are logged. Hover over the Mac connection status to see the current path summary. Filter Xcode or Console output for PhotoScan to separate these events from framework messages.

## Calibration

With phone and lights fixed, focus on a print and Lock Settings. Replace it with a blank matte neutral sheet at the same height filling the frame, then Capture Flat Field. Avoid clipping; a moderately bright gray sheet works well. References are archived under _calibrations/. Replace the sheet with the print without moving the camera/lights. Enable Flat-field correction for subsequent captures.

Flat field smooths a low-resolution reference luminance grid and applies its mean-normalized reciprocal in linear light. Gains outside 0.25 to 4 and dark/clipped samples are rejected. It preserves color ratios and average reference brightness. Strong gains amplify noise and cannot recover clipped highlights; uneven paper, shadows, setup changes, or phone movement invalidate the reference even if settings match.

For DGK Color Tools DKC-Pro 5 x 7 inch gray balance, lock settings and Capture Gray Chart. Select the 12% or 18% target and drag a rectangle wholly inside that neutral patch. Use Gray Sample archives the original chart reference and profile. The chart capture is held for selection rather than creating a finished print asset. Avoid labels, patch borders, glare, and shadows. The neutral reverse side may serve as the 18% target; this is calibration, not back pairing.

Sampling uses oriented, normalized top-left coordinates. It rejects dark, clipped, or uneven samples and gains beyond 0.5 to 2. Mean-normalized RGB gains neutralize the selected patch while preserving measured luminance; reflectance labels do not force absolute brightness. Correct selection matters because the algorithm cannot establish that a colored patch is neutral. HEIC/JPEG tone mapping limits accuracy. Combined processing applies flat field first, then gray balance.

Active profiles last for the current connection and archive folder. Unlocking, disconnecting, or changing folders clears them; archived profiles and the recipes of existing scans remain intact. Loading profiles across sessions is S02. The manufacturer describes neutral targets in its [DKC-Pro guide](https://dgkcolor.tools/wp-content/uploads/2019/09/Complete-Guide-to-the-DKC-Pro-Color-Chart_Final.pdf). Multi-patch calibration awaits verified DKC-Pro reference information; do not substitute ColorChecker values.

## Print Review

Detection combines [Vision document segmentation](https://developer.apple.com/documentation/vision/vndetectdocumentsegmentationrequest) with [rectangle detection](https://developer.apple.com/documentation/vision/vndetectrectanglesrequest), showing up to eight suggestions after consolidation. Substantially smaller candidates (area below 75% of an enclosing candidate) at least 90% contained within a larger boundary are suppressed as interior details. Near-duplicate rectangles (intersection over union at least 75%) compete by Vision confidence; ties retain detector order, with document segmentation considered first. Confidence is a heuristic, not a calibrated probability of print-edge accuracy, especially across different detectors. Ambiguous partial overlaps remain for review. Frames, chart patches, or background edges may still be detected; review is required. With no detection, the manual starting box is explicitly identified. All suggestions are shown together; select a numbered print or use the picker to drag its four handles. Add Print supplies manual starting handles for a missed detection. Remove discards a false suggestion. Empty, invalid, or overlapping selections block extraction; touching edges are allowed.

The cached 1,600-pixel review image includes the accepted calibration but no crop or rotation. Acceptance renders the full-resolution source through the same calibration recipe and [perspective correction](https://developer.apple.com/documentation/coreimage/ciperspectivecorrection). Each edge trims inward by 2.5% of the shorter rectified side, rounded up, favoring a small loss of print over visible background/shadows. Recorded corners describe the boundary before trim. Crossed or out-of-image corners are rejected. Each reviewed boundary produces a separate finished print linked to the shared full-resolution frame. Extraction stages and verifies every output before publishing under the archive lock; a failed render or write rolls back the batch and leaves review open for retry. Repeated extraction of a completed frame is rejected. After extraction, the Print picker selects each result for individual editing. Batch publication is not atomic across all child directories: process termination during publication can leave orphan children; crash recovery remains S09. Results from earlier captures and cancelled reviews cannot yet be reopened after restart in the UI (S07).

## Verification

Build both schemes (camera: generic iOS device, desk: macOS). DiagnosticsSmoke verifies file persistence, bounded rotation, immutable share snapshots, failed writes and recovery. ConnectionSmoke verifies diagnostic relaying without recursion and additionally verifies two consecutive 4 MiB image frames with a settings message between them and partial/completed transfer progress using the production TCP options. Synthetic tests require macOS image/Vision services; a restricted execution sandbox may block them. Use a writable Swift module cache if the default cache is unavailable.

```sh
swiftc -module-cache-path /tmp/photoscan-module-cache -parse-as-library Shared/ScanProtocol.swift Tests/ProtocolSmoke.swift -o /tmp/photoscan-protocol-smoke

# Local loopback TCP handshake and timeout checks (requires network access).
swiftc -module-cache-path /tmp/photoscan-module-cache -parse-as-library Shared/ScanProtocol.swift Tests/ConnectionSmoke.swift -o /tmp/photoscan-connection-smoke
/tmp/photoscan-connection-smoke
/tmp/photoscan-protocol-smoke

# Local loopback TCP handshake and timeout checks (requires network access).
swiftc -module-cache-path /tmp/photoscan-module-cache -parse-as-library Shared/ScanProtocol.swift Tests/ConnectionSmoke.swift -o /tmp/photoscan-connection-smoke
/tmp/photoscan-connection-smoke

# Repeat with FlatFieldSmoke, GrayBalanceSmoke, PrintCropSmoke, MultiPrintSmoke, or FinishedOutputSmoke.
swiftc -module-cache-path /tmp/photoscan-module-cache -parse-as-library Shared/ScanProtocol.swift PhotoScanDesk/PhotoScanDesk/{FlatField,GrayBalance,PrintCrop,ScanArchive}.swift Tests/FinishedOutputSmoke.swift -o /tmp/photoscan-finished-smoke
/tmp/photoscan-finished-smoke
```

MultiPrintSmoke covers two-print detection, confidence selection between near duplicates, interior suppression including rotated prints, ambiguous-overlap preservation, manual selection, overlapping/duplicate/contained boundaries, shared source preservation and calibration provenance, independent child regeneration/export, repeated extraction rejection, and failed second-crop rendering with retry.

FinishedOutputSmoke covers pending publication, JPEG/HEIC source preservation, embedded metadata readback/removal, unknown/partial/approximate/exact dates, repeated date changes, rotation, invalid recipes, blocked writes, existing-name rejection, duplicate indices/IDs, concurrent allocation in fresh processes, JPEG export, and 16-bit TIFF export. Calibration/crop tests cover combined processing, perspective dimensions, orientation, trim, and failed revision preservation.

Physical iPhone capture, real-print crop accuracy, calibration accuracy, and Apple Photos import of finished metadata remain S01 validation work. Both apps build and synthetic checks pass; this is distinct from physical verification.
