# PhotoScan

See [ROADMAP.md](ROADMAP.md) for planned work slices, acceptance criteria, and progress.

First slice: remotely capture a print's front on an iPhone and archive the original image on a Mac.

## Run

1. Open each Xcode project. Run PhotoScanCamera on a physical iPhone and PhotoScanDesk on the Mac.
2. Allow Camera and Local Network access. Keep the iPhone app in the foreground, preferably with both devices on the same Wi-Fi network.
3. On the Mac, choose an Archive Folder, then choose the phone from Cameras.
4. Press Capture. After transfer, the image appears on the Mac and Show in Finder opens its saved location.

Each capture creates an asset UUID folder containing front.heic (or front.jpg when HEVC is unavailable) and metadata.json. Original image bytes are preserved, including embedded camera metadata. The manifest records the actual dimensions, capture time, camera, asset ID, and side.

## Design

Shared/ScanProtocol.swift is compiled into both targets. Bonjour discovery and Network.framework TCP carry versioned, length-prefixed JSON headers followed by original binary image data, bounded to 100 MiB per message. One Mac connects at a time. Disconnects and a 60-second capture timeout clear the pending request.

Capture requests use an asset ID and a front/back role; manifests contain a dictionary of captures by role. Back capture can later reuse an existing asset ID and add a back entry. The current archive writer only creates new assets; adding back capture will also require updating an existing manifest without overwriting its front.

The iPhone uses the physical main wide-angle camera with flash off and quality prioritization, requesting the largest photo dimensions supported by the active format. Actual resolution depends on the device and capture conditions. Preview and still orientation are portrait.

## Camera Settings

After connection, the Mac shows device ISO, exposure duration, focus position (0 to 1), white balance temperature/tint, and maximum requested resolution. Readings refresh once a second. The saved image's actual dimensions appear in the bottom bar.

Lock Settings waits for autofocus, exposure, and white balance to remain settled for roughly half a second, then locks their current values. It returns an error if settling takes more than eight seconds. Unlock Settings restores continuous automatic adjustment. Capture is disabled while a settings command is pending. Locks persist until unlocked or the camera session is restarted; reconnecting reports the phone's current state.

Each capture's metadata includes a device settings snapshot around capture time, including white balance RGB gains. Separate photoISO and photoExposureSeconds fields come from the processed photo's EXIF metadata when available. These may differ from preview/device readings because the phone processes still images. Focus and white balance readings are device values, not measured from the image. Existing manifests without these optional fields remain readable.

Locking uses AVFoundation's [device configuration API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lockforconfiguration()); photo exposure readings use [capture metadata](https://developer.apple.com/documentation/avfoundation/avcapturephoto/metadata).

This prototype uses local TCP without authentication or encryption; use it on a trusted network. Pairing and retryable delivery are future work. The phone reports transfer completion, while the Mac reports success only after saving. Failed transfers or saves require a new capture.

Archive folder selection lasts for the current app session. Images are committed with their manifest by renaming a staging directory; partial writes are not reported as saved.

## Flat-Field Calibration

With the phone and lights fixed in their scanning positions, focus on a print and Lock Settings. Replace it with a blank matte neutral sheet at the same height, filling the frame. Choose the archive folder, then press Capture Flat Field. Keep the sheet below clipping: an overexposed white sheet cannot measure lighting variation. A moderately bright gray sheet works well.

Replace the sheet with a print without moving the camera or lights. With Flat-field correction enabled, Capture saves the original plus front-corrected.tiff, a 16-bit sRGB TIFF. The Original/Corrected selector switches the preview. Correction runs in the background; the original is still saved if correction fails.

References are archived under _calibrations/<profile UUID>/ with reference.heic (or .jpg) and profile.json. Each corrected scan's metadata records the profile UUID and corrected filename. The active reference lasts for the current connection and archive folder; unlocking, disconnecting, or choosing a folder clears it. Recapture after restarting either app. Existing profiles are retained as provenance; loading them is not yet implemented.

The algorithm smooths a low-resolution reference luminance field and multiplies subsequent images by its mean-normalized reciprocal in linear light using [Core Image](https://developer.apple.com/documentation/coreimage/cicontext/workingcolorspace). Gains outside 0.5 to 2 are rejected, as are dark or near-clipped reference samples. It preserves color ratios and average reference brightness; it does not calibrate white balance or replace a color-chart correction. Uneven paper, shadows, marks, changes to lighting, or moving the phone invalidate the reference even if camera settings still match.

## DKC-Pro Gray Balance

Supported chart: DGK Color Tools DKC-Pro 5 x 7 inch, with 12% and 18% neutral gray targets. This slice provides post-capture neutral white balance, not an 18-patch color matrix or a camera RAW profile. Target names record which patch was used; reflectance is not treated as an absolute output brightness.

Focus on a print and lock the settings. Place the chart at the same plane under the same lighting, then press Capture Gray Chart. In the chart window, select the 12% or 18% target name and drag a rectangle wholly inside that gray patch. Use Gray Sample saves the profile. The large neutral gray reverse side can also be used as the 18% target; this is a calibration capture, not a back scan of a print. Avoid labels, patch borders, glare, and shadows.

The original chart capture is archived as an asset, and the profile plus a reference copy are saved under _calibrations/<UUID>/gray-balance.json. Subsequent scans can enable Gray balance and Flat-field correction independently; processing applies flat field first, then gray balance, and writes one corrected TIFF. Metadata records both profile IDs when used. Unlocking, disconnecting, or changing the archive folder clears both active profiles. Capture a new chart after changing lighting or camera position.

Sampling uses the displayed oriented image's normalized top-left selection coordinates. A linear RGB sample must be sufficiently bright, below clipping, and uniform. Mean-normalized channel gains neutralize the patch while preserving its luminance; gains beyond 0.5 to 2 are rejected. The algorithm cannot establish that a selected colored patch is neutral, so correct patch selection matters. HEIC/JPEG tone mapping limits the accuracy achievable with this method.

The manufacturer describes the neutral targets in its [DKC-Pro guide](https://dgkcolor.tools/wp-content/uploads/2019/09/Complete-Guide-to-the-DKC-Pro-Color-Chart_Final.pdf). DKC-Pro reference colors are not interchangeable with a Macbeth/X-Rite ColorChecker; a future multi-patch fit must use the DKC-Pro's own reference data with a verified color-space/white-point interpretation.

## Print Cropping

After saving a scan, press Detect Print. Review a detected boundary or select Manual, then drag the four corner handles onto the print's corners. Save Crop writes a perspective-corrected 16-bit sRGB TIFF alongside the scan. Crossing corners or moving a corner outside the image is rejected. The Original / Corrected / Cropped selector compares the available versions; Show in Finder reveals the crop when Cropped is selected.

Detection uses Apple's [Vision rectangle detector](https://developer.apple.com/documentation/vision/vndetectrectanglesrequest), and rectification uses [Core Image perspective correction](https://developer.apple.com/documentation/coreimage/ciperspectivecorrection). Up to eight candidates are shown. Detection is a suggestion: internal picture frames, chart patches and background edges can also be detected, so the crop requires review. Manual handles remain available when nothing is detected.

Cropping uses the existing full-frame corrected TIFF if available, otherwise the original. It does not reapply calibration or change the original/full-frame files. Each crop has a unique filename; metadata records the latest crop per side, source filename, normalized corners, and output dimensions. Older crop files remain available. This slice crops one selected print from the latest scan; automatic multi-print extraction is future work.

Multi-patch DKC-Pro color calibration is on hold until the supplied chart reference information can be checked. Neutral gray balance remains available.

## Verification

Build both Xcode schemes. A physical iPhone is required to verify camera capture and local network discovery.

Protocol smoke test:

```sh
swiftc -parse-as-library Shared/ScanProtocol.swift Tests/ProtocolSmoke.swift -o /tmp/photoscan-protocol-smoke
/tmp/photoscan-protocol-smoke
```

Synthetic flat-field and archive tests:

```sh
swiftc -parse-as-library Shared/ScanProtocol.swift PhotoScanDesk/PhotoScanDesk/FlatField.swift PhotoScanDesk/PhotoScanDesk/GrayBalance.swift PhotoScanDesk/PhotoScanDesk/ScanArchive.swift Tests/FlatFieldSmoke.swift -o /tmp/photoscan-flatfield-smoke
/tmp/photoscan-flatfield-smoke
```

DKC-Pro neutral sample and combined processing tests:

```sh
swiftc -parse-as-library Shared/ScanProtocol.swift PhotoScanDesk/PhotoScanDesk/FlatField.swift PhotoScanDesk/PhotoScanDesk/GrayBalance.swift PhotoScanDesk/PhotoScanDesk/ScanArchive.swift Tests/GrayBalanceSmoke.swift -o /tmp/photoscan-gray-smoke
/tmp/photoscan-gray-smoke
```

Print detection and crop tests:

```sh
swiftc -parse-as-library Shared/ScanProtocol.swift PhotoScanDesk/PhotoScanDesk/FlatField.swift PhotoScanDesk/PhotoScanDesk/GrayBalance.swift PhotoScanDesk/PhotoScanDesk/ScanArchive.swift PhotoScanDesk/PhotoScanDesk/PrintCrop.swift Tests/PrintCropSmoke.swift -o /tmp/photoscan-crop-smoke
/tmp/photoscan-crop-smoke
```
