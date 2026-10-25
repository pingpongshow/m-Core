# m-Core

A native iPhone and iPad companion app for [MeshCore](https://github.com/meshcore-dev/MeshCore) LoRa mesh radios.
Its headline feature keeps the radio's position accurate: a radio with GPS uses its own, and a radio without GPS is fed the phone's location.

Status: **Phase 1** (companion protocol, BLE/TCP transports, connection). See [PLAN.md](PLAN.md) for the full spec and build plan.

To try it: Settings → Radio → scan for a Bluetooth radio, enter a Wi‑Fi radio's address (port 5000), or, in debug builds, connect to the simulated radio.

## Requirements

- Xcode 26 or later (iOS/iPadOS 18+ deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Optional: [SwiftLint](https://github.com/realm/SwiftLint): `brew install swiftlint`

## Getting started

```sh
make generate   # creates mCore.xcodeproj from project.yml
open mCore.xcodeproj
```

The Xcode project is generated and not committed; edit `project.yml` instead.
To run on a device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your bundle ID and team.

| Command | What it does |
|---|---|
| `make build` | Build the app for the first available iPhone simulator |
| `make test` | Run app and package tests in the simulator |
| `make test-packages` | Run each Swift package's tests on macOS |
| `make lint` | SwiftLint (skipped if not installed) |

## Layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI app target (shell, screens) |
| `Packages/MeshCoreKit` | Companion protocol: frame codec, BLE/TCP/mock transports, session, reconnect, simulated radio |
| `Packages/MeshServices` | Sync, GPS Feed, telemetry, admin, Internet Map, observer uplink |
| `Packages/MeshMaps` | Offline map extraction and storage (PMTiles) |
| `Packages/MeshStore` | Persistence (SwiftData) |
| `Packages/MeshDesign` | Design tokens, components and the Design Gallery |

The Design Gallery (Settings → Developer → Design Gallery) shows every component in the current appearance.

## Licence

[MIT](LICENSE). m-Core is a clean-room implementation and contains no code from other MeshCore or Meshtastic apps.
Map data © OpenStreetMap contributors.
