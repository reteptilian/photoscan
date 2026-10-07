# PhotoScan

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

## Verification

Build both Xcode schemes. A physical iPhone is required to verify camera capture and local network discovery.

Protocol smoke test:

```sh
swiftc -parse-as-library Shared/ScanProtocol.swift Tests/ProtocolSmoke.swift -o /tmp/photoscan-protocol-smoke
/tmp/photoscan-protocol-smoke
```
