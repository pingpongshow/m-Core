# m-Core

A native iPhone and iPad companion app for [MeshCore](https://github.com/meshcore-dev/MeshCore) LoRa mesh radios.
Its headline feature keeps the radio's position accurate: a radio with GPS uses its own, and a radio without GPS is fed the phone's location.

Status: **feature complete for a beta; not yet tested on real radios.** See [PLAN.md](PLAN.md) for the full spec, build plan and progress.

What's in it:

- **GPS Feed:** the radio's own GPS when it has one, otherwise the phone's location, with movement presets, background updates, an optional pause in Low Power Mode, and an alert if the radio drops while feeding.
- **Chat:** direct messages with delivery status and retries, public, private and hashtag channels, room servers, replies, reactions, mentions, formatted text, link previews and inline images (can be turned off), location pins, timed live location, request position, mute levels, and notifications with reply.
- **Nodes:** contacts, repeaters, rooms and sensors with telemetry history, paths, trace, favourites, blocking, alerts and QR/link sharing (drag a node out to share it).
- **Offline maps:** frame or search an area and m-Core copies just those tiles from the public Protomaps OpenStreetMap build (exact size first, pause/resume, refresh, thumbnails, storage limit), or import `.pmtiles`/`.mbtiles` files. Roads, place names, borders and coastlines only. A world overview is built in. Pins cluster, route lines show a contact's or message's path.
- **Radio and admin:** AccessorySetupKit pairing and a list of your radios, MeshCore's suggested regional settings plus your own, tuning, Wi-Fi, battery % by chemistry, key and profile backup; repeater and room login, status, neighbours, a settings screen and the command line.
- **Tools:** trace path (on a map, shareable card), Local Mesh Discovery, RX log with packet decoding and CSV export, stats and noise floor, coverage walk, line of sight, and a route recorder (GPX).
- **Optional internet features:** the MeshCore Internet Map (browse, add as contact, add your radio) and a phone-as-observer MQTT uplink (LetsMesh or your own broker). Both are off until you use them.
- **iPhone and iPad:** multi-window on iPad, ⌘1–5 / ⌘F / ⌘K command palette, light/dark/high-contrast appearance, VoiceOver labels, built-in help, and a string catalog ready for translation.

To try it: Settings → Radio → Add radio for a Bluetooth radio, or enter a Wi‑Fi radio's address (port 5000).

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
| `make strings` | Sync `App/Resources/Localizable.xcstrings` with the strings in code |

## Layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI app target (shell, screens) |
| `Packages/MeshCoreKit` | Companion protocol: frame codec, BLE/TCP transports, session, reconnect; a simulated radio used only by the tests |
| `Packages/MeshServices` | Sync, GPS Feed, telemetry, admin, Internet Map, observer uplink |
| `Packages/MeshMaps` | Offline map extraction and storage (PMTiles) |
| `Packages/MeshStore` | Persistence (SwiftData) |
| `Packages/MeshDesign` | Design tokens, components and the Design Gallery |
| `Packages/MeshTools` | Packet decoding, MQTT client and observer format, line of sight, coverage export |
| `App/Maps/world-overview.pmtiles` | Bundled z0–5 world overview, extracted from the Protomaps build |
| `App/Glyphs` | Noto Sans glyphs for map labels (SIL Open Font License) |

The app reads its list of map sources from [`Maps/sources.json`](Maps/sources.json) on `main` (cached for a day, falling back to build.protomaps.com). Editing that file moves every installed copy to new map sources without an app update.

### Bluetooth pairing

Bluetooth radios are added through the AccessorySetupKit picker (Settings → Radio → **Add radio**). Setting
`MCORE_ACCESSORY_SETUP_KIT = NO` in `Config/Local.xcconfig` — or `make build MCORE_ACCESSORY_SETUP_KIT=NO` for one
build — drops the two `NSAccessorySetupKit*` keys from the generated `Info.plist` and falls back to plain
CoreBluetooth: the standard Bluetooth permission prompt, and **Scan for radios** in place of the picker. The app reads
those keys at launch and switches over on its own, so nothing in the Swift code changes.

Reach for the fallback when a radio pairs in iOS Settings but the app still can't connect. Under AccessorySetupKit
CoreBluetooth reports `poweredOn` only once an authorized accessory is reachable, and
[iOS 18 had a bug](https://developer.apple.com/forums/thread/811101) where it never did. `Info.plist` is generated, so
after switching, build once with `make` before going back to building from Xcode.

In debug builds, the Design Gallery (Settings → Developer → Design Gallery) shows every component in the current appearance,
and `-MCStartTab map` (or `chats`, `nodes`, `tools`, `settings`) opens the app on that tab.

## Licence

[MIT](LICENSE). m-Core is a clean-room implementation and contains no code from other MeshCore or Meshtastic apps.
Map data © OpenStreetMap contributors, extracted from [Protomaps](https://protomaps.com) builds. Map label font: Noto Sans (SIL OFL 1.1).
