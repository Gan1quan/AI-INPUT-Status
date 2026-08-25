# AI-INPUT-Status

AI INPUT public status app and RootHide background poller for iOS 16.1.

## Architecture

- IPA: SwiftUI status viewer. It first calls the local daemon `127.0.0.1:17891/refresh` and consumes the daemon's cached `payload`; if the daemon is unavailable, it falls back to the public API.
- RootHide DEB: `aiinputstatusd` owns the network request, persistent state, retry, and local status API.
- SpringBoard tweak: posts the Darwin notification `com.gan1quan.aiinputstatus.refresh` after SpringBoard starts and then at a 30-second throttled interval.
- RootHide paths: no hard-coded `/var/jb`; daemon paths use the RootHide `jbroot()` API.

## Build IPA

GitHub Actions → `Build IPA` → artifact `AI-INPUT-Status-v3.3.2`.
The IPA is unsigned and needs TrollStore or another appropriate signer.

## Build RootHide DEB

GitHub Actions → `Build RootHide Background DEB` → artifact `AI-INPUT-Status-Background-v1.1.1-arm64e`.
Use the RootHide/roothide Theos package scheme. Install the DEB, respring/restart SpringBoard, then open the IPA and check Settings → Background Plugin.

## Diagnostics on device

```sh
curl -sS http://127.0.0.1:17891/status
curl -sS http://127.0.0.1:17891/refresh
cat /var/aiinputstatusd-state.json
```

`/refresh` is throttled to avoid duplicate network requests. System Background Fetch remains only a compatibility fallback and is not used as a fixed timer.
