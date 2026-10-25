# m-Core

A native iPhone and iPad companion app for [MeshCore](https://github.com/meshcore-dev/MeshCore) LoRa mesh radios.
Its headline feature keeps the radio's position accurate: a radio with GPS uses its own, and a radio without GPS is fed the phone's location.

Status: **Phase 0** (project setup and design system). See [PLAN.md](PLAN.md) for the full spec and build plan.

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
| `Packages/MeshCoreKit` | Companion protocol: codec, transports, session |
| `Packages/MeshServices` | Sync, GPS Feed, telemetry, admin, Internet Map, observer uplink |
| `Packages/MeshMaps` | Offline map extraction and storage (PMTiles) |
| `Packages/MeshStore` | Persistence (SwiftData) |
| `Packages/MeshDesign` | Design tokens, components and the Design Gallery |

The Design Gallery (Settings → Developer → Design Gallery) shows every component in the current appearance.

## Licence

[MIT](LICENSE). m-Core is a clean-room implementation and contains no code from other MeshCore or Meshtastic apps.
Map data © OpenStreetMap contributors.
