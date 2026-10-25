# m-Core — MeshCore Companion App for iPhone & iPad

Product spec and build plan for a **fresh, native SwiftUI** MeshCore companion app, to ship on the public App Store.
Research: 24–25 Oct 2026. Firmware reference: MeshCore `main`, companion firmware **v1.18.0** (protocol `FIRMWARE_VER_CODE` 14, built 15 Oct 2026).

---

## 1. Summary & key decisions

**Why m-Core:** no existing iOS MeshCore app keeps the radio's position continuously accurate. m-Core does that (the **GPS Feed**: a radio with GPS uses its own; a radio without GPS gets the phone's), with a clean native iPhone/iPad UI modelled on MeshCore One, and the useful MeshCore-compatible features from the Meshtastic app.

| Topic | Decision |
|---|---|
| Name | **m-Core**: no App Store app uses this exact name (checked US/GB/DE/AU/CA/FR storefronts, 25 Oct 2026). Similar: "mCORE" (business app, LOGICAL SH.P.K.) and "mCoreHabit". Final check: reserve the name in App Store Connect |
| Codebase | **Fresh build, open source under the MIT licence, clean-room** (§6.3). MeshCore One and Meshtastic are feature references only; no code is reused |
| Distribution | Public App Store |
| Platforms | iPhone and iPad, **iOS/iPadOS 18+**; Mac via "Designed for iPad" |
| Transports | BLE (primary) and TCP (Wi‑Fi companion builds). USB/serial is out of scope |
| Headline feature | Radio always has an accurate position: **radio has GPS → use the radio's GPS; radio has no GPS → feed it the phone's GPS** (§4.1) |
| Map | MapLibre Native, **offline-first and minimal**: roads, place labels and borders only. No water, land use, topo, satellite or 3D (§4.4) |
| Offline map data | **Meshtastic method:** users draw an area, and the app extracts it on the device from the public **Protomaps daily planet build** via HTTP range requests. No map files are hosted by the project; the app uses only the public builds or files the user imports (§4.4) |
| Internet use | Optional only: map downloads, LoS elevation, link previews, Internet Map view/upload, and an observer MQTT uplink that is **off by default** (§4.8) |
| Out of scope | Canned messages, TAK, Siri/App Intents, CarPlay, widgets, Control Center controls, Live Activities, Apple Watch app, internet message relaying, USB transport |

---

## 2. Landscape

| | **Official MeshCore** (Liam Cottle) | **MeshCore One / MC1** (Avi0n) | **PommeCore** | **MeshCore Open** (zjs81) |
|---|---|---|---|---|
| Tech | Flutter, closed source, freemium | Native Swift/SwiftUI, GPL‑3.0, iOS 18+ | Native Swift | Flutter, MIT, TestFlight only |
| Platforms | iOS, Android, macOS, Win, Linux, Web | iPhone, iPad, Apple Silicon Mac | iPhone, iPad, Mac, Watch ($1.99) | iOS, Android, desktop |
| Transports | BLE, USB, Wi‑Fi | BLE, Wi‑Fi | BLE | BLE |
| Messaging | ✅ | ✅ + reactions, @mentions, link previews, inline images, blocking | ✅ | ✅ |
| Map | ✅ | ✅ OpenFreeMap/OpenTopoMap/Esri; offline via bulk tile cache | ✅ | ✅ |
| Repeater/room admin | ✅ (paid "skip wait") | ✅ + CLI terminal, telemetry charts | ✅ | ✅ |
| Diagnostics | Noise floor, LoS, coverage | RX log, noise floor, trace path, LoS with Fresnel | Packet log, freq scanner | Path trace |
| **Phone GPS → radio** | One-shot "use phone location" | **Refreshed only right before a manual advert, foreground only** | not documented | not documented |

- **The verified gap:** in MC1's source, "Auto-Update Location" calls `requestCurrentLocation()` only inside `sendSelfAdvert()`. It has no continuous feed, no background location, no movement gating, and nothing stopping the radio's own GPS from overwriting the phone's position.
- **Meshtastic (Apple), reference only:** a mature Swift app for a different mesh protocol. Its offline-map method and several node and tool features are adopted where MeshCore supports them (Appendix A).
- **Related tools:** MeshMapper and MeshCoreScanner (phone-GPS coverage mapping), MeshCore Solo (3rd-party firmware with live location sharing).

---

## 3. MeshCore firmware reference

### 3.1 Companion protocol (v14)
**Transport:**
- **BLE:** Nordic UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX/write `…0002…`, TX/notify `…0003…`. One write is one frame.
- **Encoding:** little-endian integers, UTF‑8 strings.
- **Flow:** strictly one command in flight (~5 s timeout). Push frames (≥ 0x80) can arrive at any time.
- **TCP:** Wi‑Fi builds carry the same frames over TCP.

**Commands (opcode):** APP_START 1 · SEND_TXT_MSG 2 · SEND_CHANNEL_TXT_MSG 3 · GET_CONTACTS 4 (optional `since`) · GET/SET_DEVICE_TIME 5/6 · SEND_SELF_ADVERT 7 (0 = zero-hop, 1 = flood) · SET_ADVERT_NAME 8 · ADD_UPDATE_CONTACT 9 · SYNC_NEXT_MESSAGE 10 · SET_RADIO_PARAMS 11 · SET_RADIO_TX_POWER 12 · RESET_PATH 13 · **SET_ADVERT_LATLON 14** · REMOVE/SHARE/EXPORT/IMPORT_CONTACT 15–18 · REBOOT 19 · GET_BATT_AND_STORAGE 20 · SET_TUNING_PARAMS 21 · DEVICE_QUERY 22 · EXPORT/IMPORT_PRIVATE_KEY 23/24 · SEND_RAW_DATA 25 · SEND_LOGIN 26 · SEND_STATUS_REQ 27 · HAS_CONNECTION 28 · LOGOUT 29 · GET_CONTACT_BY_KEY 30 · GET/SET_CHANNEL 31/32 · SIGN_START/DATA/FINISH 33–35 · SEND_TRACE_PATH 36 · SET_DEVICE_PIN 37 · **SET_OTHER_PARAMS 38** · SEND_TELEMETRY_REQ 39 · **GET/SET_CUSTOM_VAR(S) 40/41** · GET_ADVERT_PATH 42 · GET_TUNING_PARAMS 43 · SEND_BINARY_REQ 50 · FACTORY_RESET 51 · SEND_PATH_DISCOVERY_REQ 52 · SET_FLOOD_SCOPE_KEY 54 · SEND_CONTROL_DATA 55 · GET_STATS 56 (core/radio/packets) · SEND_ANON_REQ 57 · SET/GET_AUTOADD_CONFIG 58/59 · GET_ALLOWED_REPEAT_FREQ 60 · SET_PATH_HASH_MODE 61 · SEND_CHANNEL_DATA 62 · SET/GET_DEFAULT_FLOOD_SCOPE 63/64 · SEND_RAW_PACKET 65 · **RUN_CLI_COMMAND 66**

**Pushes:** ADVERT 0x80 · PATH_UPDATED 0x81 · SEND_CONFIRMED 0x82 · MSG_WAITING 0x83 · RAW_DATA 0x84 · LOGIN_SUCCESS/FAIL 0x85/86 · STATUS_RESPONSE 0x87 · LOG_RX_DATA 0x88 · TRACE_DATA 0x89 · NEW_ADVERT 0x8A · TELEMETRY_RESPONSE 0x8B · BINARY_RESPONSE 0x8C · PATH_DISCOVERY_RESPONSE 0x8D · CONTROL_DATA 0x8E · CONTACT_DELETED 0x8F · CONTACTS_FULL 0x90

**Local CLI on the companion (via 66):** `reboot`, `poweroff`/`shutdown`, `set/get name`, `set pin`, `set/get wifi.ssid`, `set wifi.pwd`, `set wifi.clear`, `set/get wifi.enabled`, `get wifi.status`, `get wifi.ip`, `board`, `ver`, `set/get tz.offset`.
**Remote CLI on repeaters/rooms (after login):** `neighbors`, `stats-core/radio/packets`, `gps on|off|sync|setloc|advert`, `powersaving`, `tempradio`, `region`, `sensor get|set|list`, `clock sync`, `advert`, `start ota`, `log …`, `reboot`.

### 3.2 Location internals (`examples/companion_radio/MyMesh.cpp`)
| Item | Detail | Consequence for the app |
|---|---|---|
| `SET_ADVERT_LATLON` (14) | `[0x0E][lat int32][lon int32][alt int32 optional]`, degrees × 1e6, signed, range-checked → OK / ERR(ILLEGAL_ARG) | Altitude is accepted but **ignored** ("FUTURE"). Send it anyway for forward compatibility |
| Each call runs `savePrefs()` | **Writes flash every time** | Throttle with movement and time gates; never stream at 1 Hz |
| `SELF_INFO` (reply to APP_START) | bytes 36–43 current lat/lon; byte 45 advert location policy; byte 46 telemetry modes | Read back to verify the radio holds the phone's fix |
| `advert_loc_policy` | 0 NONE, 1 SHARE; set by `SET_OTHER_PARAMS` byte 3 | Adverts carry location only when SHARE. That command also rewrites `manual_add_contacts`, telemetry modes and `multi_acks`, so read them from SELF_INFO first and resend them unchanged |
| `telemetry_mode_loc` | 0 deny · 1 per-contact flag · 2 allow all | Controls whether telemetry requests return your position |
| Onboard GPS (`ENV_INCLUDE_GPS`) | Custom vars `gps` (0/1), `gps_interval` (s); a valid fix **overwrites the position** every interval | Radios with GPS use their own; the app never writes phone positions to them (they'd be overwritten anyway) |
| Adverts | Companion never adverts on its own; only on `SEND_SELF_ADVERT` (or its button/screen) | The app owns the advert schedule |
| Device time | `SET_DEVICE_TIME` accepts forward jumps only | Sync the clock from the phone on every connect |

### 3.3 MeshCore and the internet
**The firmware has no internet transport.** MeshCore is LoRa-only, and companion firmware has no MQTT or IP uplink. Wi‑Fi builds use Wi‑Fi only to reach the app over the LAN. The ecosystem around it:

| Service | What it does | How it works |
|---|---|---|
| **map.meshcore.io** (official Internet Map) | Public map of repeaters, rooms and sensors (optionally companions): name, key, type, location, a `meshcore://contact/add` QR | Uploads come from the official app (*Add me to the Map*, *Upload to Internet Map*) or an auto-uploader bot. The bot verifies the advert signature, then POSTs to `https://map.meshcore.io/api/v1/uploader/node`, signed with the uploading companion's key. Only that key can delete an entry; nodes go stale after 20 days |
| **MQTT observers → analyzers** (LetsMesh.net, self-hosted CoreScope) | Live packet feeds, maps, path tracing, per-node analytics | A packet-logging radio plugged into a Pi running `meshcoretomqtt` publishes to `meshcore/{IATA}/{PUBKEY}/packets`. LetsMesh authenticates with a JWT signed by the device key |
| **Coverage maps** (MeshMapper, MeshCoreScanner) | Crowd-sourced coverage | GPS-tagged pings uploaded from phones |
| **Bridges** (MESH-API, MTMC Bridge, RNS-over-MeshCore) | MeshCore ⇄ Meshtastic, public-channel relays, Reticulum tunnels | Computer with radios attached; experimental |
| **Automation** (meshcore_py, meshcore.js, meshcore-cli, Home Assistant, bots) | Scripts and dashboards | Companion over USB/TCP plus a client library |
| **Web tools** | Web flasher, meshcore.nz web client | Web Serial / Web Bluetooth |

---

## 4. Feature spec

### 4.1 GPS Feed: keep the radio's position accurate (headline)
**Source rule** (automatic, per radio):
- **Radio has GPS** (`gps` appears in `GET_CUSTOM_VARS`): use the **radio's GPS**. If it's switched off (`gps:0`), offer to turn it on (`gps:1`). The app never writes phone positions to this radio.
- **Radio has no GPS:** the **phone's GPS** feeds the radio continuously (pipeline below).

The only user setting is a GPS Feed on/off switch per radio, plus the privacy options below.

**Phone feed pipeline:** `CLLocationUpdate.liveUpdates()` inside a `CLBackgroundActivitySession` → filter → gate → `SET_ADVERT_LATLON` → verify via SELF_INFO.
- **Filter:** drop fixes with `horizontalAccuracy` > 50 m (configurable), fixes older than 30 s, and invalid or zero fixes.
- **Gate** (protects flash and battery):
  - Send when the phone has moved ≥ 25 m **and** ≥ 30 s have passed since the last send.
  - Also send a heartbeat every 10 min if the radio's position has drifted.
  - Presets: Walking / Driving / Stationary / Custom.

**Shared settings:**
- **Privacy:**
  - Optional rounding of phone fixes (radios without GPS): exact, ~100 m or ~1 km.
  - Separate toggles for "share in adverts" (`advert_loc_policy`) and "share via telemetry" (`telemetry_mode_loc`).
- **Advert on move** (optional): a zero-hop or flood advert after moving ≥ X km, at most once every 15 min (default).
- **Background:** `UIBackgroundModes` = `bluetooth-central` + `location`. "When In Use" with a background activity session (blue status pill); optional "Always". Optional pause in Low Power Mode. The phone's GPS runs only for radios without GPS.
- **Status:** a header chip and the connection popover show the source and its state ("Radio GPS" with the radio's last reported position and age, or "Phone · ±8 m · synced 12 s ago"), plus last error and today's phone-write count. A notification fires if the radio connection drops while the feed is on.
- **Clock sync** from the phone on every connect.

### 4.2 Messaging
- **Direct messages:** delivery states (sent → repeated → delivered via ACK 0x82), flood retry and a path-hop view.
- **Channels:** Public, private PSK, and `#hashtag` (key = SHA-256 of the name, first 16 bytes). Channel QR codes and deep links.
- **Room servers:** login, guest/participant modes. They also fill the role of Meshtastic's store & forward.
- **Reactions, replies and @mentions:** encoded the way MC1 and the official app do, so they render for those users. Incoming markdown is rendered; there's no formatting toolbar.
- **Location pins** ("Send my location") render as map previews. **Timed live location** (15 min / 1 h) sends rate-limited pin updates.
- **Request position** from a contact (telemetry request; returns GPS only if the peer allows it).
- **Also:** reply from notifications, per-chat mute levels, search, pinned and unread chats, and a byte counter near the size limit.

### 4.3 Contacts & nodes
- **Discovery:** NEW_ADVERT, plus manual-add and auto-add config (58/59). Node types: chat, repeater, room, sensor.
- **Sharing:** QR import/export (17/18), `meshcore://` links, and share via advert. Sending your own advert (zero-hop or flood) is the equivalent of Meshtastic's "exchange positions".
- **Management:** favourites (contact flag bit 0), block, delete, local nickname, and node alerts (notify when a chosen node is heard).
- **Info shown per node:** distance and bearing from the phone, a navigate-to handoff to Apple Maps, last heard, SNR signal meter, hop count, and position history from adverts and telemetry.
- **Path tools:** reset/edit path, zero-hop ping.
- **Telemetry fetch:** CayenneLPP decode of battery and voltage, plus environment and power sensors when the node reports them. Altitude is shown when present.
- **Storage limits:** handle CONTACTS_FULL (0x90) and CONTACT_DELETED (0x8F).

### 4.4 Map & offline maps
**Engine and style:**
- MapLibre Native, chosen because maps must work with no signal and MapKit has no public offline-download API for third-party apps.
- One minimal bundled style with light and dark variants (adapted from the Protomaps flavours). It draws only `roads` (with names), `places` and `boundaries` on a plain background. Water, land use, land cover, buildings and POIs exist in the tiles but are never drawn.
- **On top of the basemap:** clustered node pins (contact, repeater, room), the phone's position and the radio-reported position, trace/path lines, contact trails, and Internet Map nodes (§4.8). Filters: type, hops, last heard.
- **Controls:** compass, locate me, fullscreen.

**Offline areas (Meshtastic method):**
- **User flow:** *Map → Offline Maps → Download area*.
  1. Search for a place or frame the area on the map.
  2. Pick **Standard** (z0–13) or **High** (z0–15).
  3. The app shows the exact download size before anything is fetched.
  4. Download runs in the background with progress and resume.
  5. Saved areas are listed with size, date and a thumbnail, and can be refreshed or deleted.
- **How it works:**
  1. Range-fetch the source PMTiles header and root directory.
  2. Enumerate the tile IDs in the bbox across the zoom range, fetching leaf directories as needed, to get exact byte ranges and size.
  3. Coalesce adjacent ranges into batched requests and copy the compressed tiles verbatim.
  4. Write a local PMTiles v3 file to `Application Support/Maps/<area-id>.pmtiles`, excluded from backup, plus a manifest (bbox, zooms, source build).
- **Rendering:** MapLibre reads the files via `pmtiles://file://…`, layered over a bundled world overview (z0–5, ~15 MB).
- **Source file** (same as Meshtastic, nothing self-hosted):
  - Extract from the public **Protomaps daily planet build** (`https://build.protomaps.com/YYYYMMDD.pmtiles`). Like Meshtastic, discover the newest available build by probing recent dates, and record each area's source build in its manifest.
  - Protomaps' docs say build URLs "may change" and discourage hotlinking in favour of copying to your own storage. Mitigations without hosting map data: keep the list of candidate source URLs in a small JSON file in the m-Core GitHub repo (the app falls back to built-in defaults); handle a missing build gracefully; keep Files import as a backup. As an open-source project, also ask Protomaps whether this use is OK.
  - The project hosts no map files, and release builds contain no custom map source URL.
- **Also supported:**
  - Files/AirDrop import of `.pmtiles`/`.mbtiles`.
  - A `#if DEBUG` custom source URL for testing from your LAN.
- **Sizes:** a city at Standard is tens of MB; a large state at High is hundreds of MB to GBs. Show the estimate, warn on cellular, and set a storage cap in Settings.
- **Attribution:** "© OpenStreetMap contributors" (ODbL) and a Protomaps credit on the map and in *About*.

### 4.5 Network tools
- **Trace path** (36 / 0x89): trace log, hop timeline, path drawn on the map, share card.
- **Path discovery** (52).
- **RX log** (0x88): packet decoding, filters, CSV export.
- **Stats and noise floor:** charts from GET_STATS (56).
- **Line of Sight:** points A / repeater / B with antenna heights; per-hop clearance with Fresnel zone and earth curvature; terrain profile chart. Elevation comes from the Open‑Meteo API, so this tool needs internet. Optional later: offline elevation download.
- **Range/coverage walk:** zero-hop pings or traces logged with phone GPS and SNR, shown as coloured points on the map, exportable to CSV/GPX.
- **Local Mesh Discovery:** cycle through radio presets (`SET_RADIO_PARAMS`) with a set dwell time, collect the adverts and SNR heard on each, then always restore the original settings (with a safeguard if the app is interrupted).
- **Route recorder** (optional): record your phone's GPS track.

### 4.6 Remote node admin
- **Access:** login (26) with admin or guest.
- **Status and telemetry:** status (27), telemetry (39/50), neighbours, and telemetry history charts.
- **CLI terminal:** local via 66; remote via the text CLI (§3.1).
- **Configuration:** radio and identity settings, reboot.

### 4.7 Companion radio settings
- **Pairing:** AccessorySetupKit with a CoreBluetooth fallback; TCP for Wi‑Fi builds; list of known radios.
- **Radio:** regional presets, frequency/BW/SF/CR/TX power (`GET_ALLOWED_REPEAT_FREQ`), tuning params, "client repeat" toggle.
- **Identity and security:** name, BLE PIN, private key backup/restore (23/24), telemetry permission modes (base/location/environment).
- **Wi‑Fi:** for Wi‑Fi builds, set SSID/password/enabled and show status and IP via the local CLI.
- **Device:** battery (OCV curve per chemistry) and storage, reboot, power off, factory reset.
- **Device profile export/import:** a bundle of preferences, channels, contacts and key.
- **Firmware:** version check with a link to the web flasher. In-app updates come post-launch.

### 4.8 Internet features (all optional; the app is fully usable offline)
- **Map areas, LoS elevation, link previews:** as described above. Link previews can be turned off.
- **Internet Map, view and import:** show map.meshcore.io nodes near you on the map, and add a repeater or room as a contact (with its radio settings) before you're in range. Results are cached for offline use.
- **Internet Map, upload (opt-in):** "Add my radio to the map" and "Upload this repeater/room". Requests are signed **on the radio** with SIGN_START/DATA/FINISH (33–35), so the private key never leaves the device. *Confirm the API accepts this signature format.*
- **Phone as observer (optional, off by default):**
  - While online, forward the RX log to the MQTT broker the user chooses (a LetsMesh preset, or a custom broker such as CoreScope) on `meshcore/{IATA}/{PUBKEY}/packets`.
  - Authentication: a device-key JWT signed on the radio.
  - Settings: broker, region code, Wi‑Fi only, pause in background.
  - Privacy note: adverts and Public-channel traffic are readable by anyone; DMs and private channels stay encrypted.
- **Not included:** relaying messages between meshes over the internet.

### 4.9 Platform & accessibility
- **Navigation:** Chats · Nodes · Map · Tools · Settings. A tab bar on iPhone; a left icon rail with `NavigationSplitView` on iPad (§5).
- **iPad:** keyboard shortcuts (⌘N, ⌘F, ⌘K command palette), multi-window, drag-and-drop, pointer hover.
- **Accessibility:** Dynamic Type, VoiceOver labels, a high-contrast theme, bundled offline help.
- **Localisation:** string catalog from day one; English at launch, more languages later.

---

## 5. UI spec (screen by screen)
Based on MeshCore One's iPad screens (meshcoreone.com). **Match** = keep MC1's pattern. **Better** = where m-Core goes further.

**App shell**
- Left icon rail (iPad) or tab bar (iPhone) with unread badges. **Match.**
- A round antenna button (green when connected) opens the connection popover. **Better:** the popover also shows **GPS Feed state** (synced 12 s ago ±8 m / paused / radio GPS), radio battery and RSSI.

**Chats list**
- Large title, search, filter chips (All · Unread · DMs · Channels · Rooms), compose button. **Match.**
- Rows: avatar (initials colour; 🔒 private channel; 🌐 Public), name, ★ favourite, 🔕 muted, `@` mention badge, unread count, time, preview. **Match.**
- **Better:** swipe actions (pin, mute, mark read), a `#hashtag` badge, and a last-heard dot for DMs.

**Conversation**
- Header: name and route ("Direct · 2 hops" / "Private Channel"), plus an ⓘ inspector. **Match.**
- Outgoing status line: "Sent" / "1 repeat · Delivered". **Match.**
- Incoming metadata: time · repeats · hop hashes (`10A3, 20B7`) or "Flood". Channel messages show the sender name above the bubble. **Match.**
- Clock-skew icon, reaction chips, highlighted @mentions, link-preview cards, inline images, jump-to-latest button. **Match.**
- Composer: ⊕ menu, a placeholder naming the target, a 🔒 indicator, send button. **Better:** the ⊕ menu has Send my location, Start live location and Request position. Also a byte counter, and long-press options Show path on map / Retry flood.

**Nodes**
- Search with count; segments Favorites · Contacts · Repeaters · Rooms; sort and ⋯ menus. **Match.**
- Rows: key-hash prefix (`0A`), name, hops, distance with bearing arrow, last heard. **Match.** **Better:** SNR bars, and a stale grey-out after 24 h.
- Detail: avatar, type, "Has Location"; actions Send Message · Telemetry · Telemetry History · Favourite · Share Contact · Share via Advert; info (nickname, name, last advert) and a mini-map. **Match.** **Better:** Trace Path · Reset Path · Ping · Block · Alert when heard · Navigate, plus a path card.

**Map**
- Typed pins with name labels, scale bar, refresh, and a floating control column (compass, locate me, fullscreen). **Match**, but without MC1's 3D and layer toggles.
- **Better:** separate phone and radio-reported pins, with a dashed line if they differ by more than the gate distance; a filter sheet; contact trails; an Offline Maps entry point.

**Line of Sight** (Tools)
- Points list (A / repeater / B) with ground elevation, share, re-pin, antenna height and remove; an Analyze button. **Match.**
- Results: Clear/Obstructed with % Fresnel clearance per hop and total distance; terrain profile chart with k-factor; RF settings. **Match.**

---

## 6. Architecture

### 6.1 Structure
```
m-Core.xcodeproj  (XcodeGen)
├── Packages/
│   ├── MeshCoreKit     ← pure Swift, no UIKit: codec, frame types, transports, session actor
│   │   ├── Protocol/   opcodes, FrameEncoder/Decoder, CayenneLPP, models (Contact, Channel, SelfInfo…)
│   │   ├── Transport/  Transport protocol; BLETransport (CoreBluetooth), TCPTransport (Network.framework), MockTransport
│   │   └── Session/    MeshSession actor: serial command queue, timeouts, push AsyncStream, reconnect
│   ├── MeshServices    ← MessageSync, ContactSync, ChannelService, GPSFeedService, AdvertScheduler,
│   │                     TelemetryService, AdminService, NotificationService, InternetMapService, ObserverUplink
│   ├── MeshMaps        ← PMTilesExtractor, OfflineMapStore, map style, ElevationService (Open‑Meteo)
│   ├── MeshStore       ← SwiftData persistence, one store per radio
│   └── MeshDesign      ← design tokens, shared components, Design Gallery
└── App/                ← SwiftUI views, AppState (@Observable)
```

### 6.2 Key decisions
- **Concurrency:** Swift 6 strict concurrency. `MeshSession` is an actor exposing `AsyncStream<Push>`; UI state uses `@Observable`.
- **Deployment target:** iOS/iPadOS 18 (AccessorySetupKit, SwiftData, `CLBackgroundActivitySession`).
- **Design system first:** the `MeshDesign` package holds the shared components, built in Phase 0: avatar, message metadata and delivery lines, path/reaction chips, badges, filter chips, status pill (GPS Feed, connection), signal bars, floating buttons and map controls.
- **Testing:** golden-frame tests with byte-exact fixtures for every opcode, cross-checked against `meshcore_py`/`meshcore.js`.
- **Charts:** Swift Charts for terrain profiles, noise floor and telemetry.
- **Hardware on the bench:** one nRF52 radio (RAK4631 or T1000-E) and one ESP32 (Heltec V3, also covering Wi‑Fi/TCP), plus a mock transport for UI work.

### 6.3 Open source, clean-room
- m-Core is **open source** (public GitHub repo) and written from scratch.
- **MeshCore One and Meshtastic are feature references only:** we use what they offer, limited to what MeshCore supports. **No code is copied or adapted** from them (both are GPL‑3.0).
- The protocol is implemented from the MeshCore firmware source and docs; the map extractor from the public PMTiles v3 spec.
- Check the licences of `meshcore_py`/`meshcore.js` before reusing their test vectors. Keep OSM/Protomaps attribution.
- **Licence: MIT** (decided). Add `LICENSE` in Phase 0. Contributions are accepted under MIT, and third-party dependencies must be MIT-compatible (MapLibre Native is BSD-2-Clause; check others as they're added).

---

## 7. Build plan

Estimates assume one developer.

| Phase | Scope | Exit criteria | Est. |
|---|---|---|---|
| **0. Setup** | Public GitHub repo with MIT `LICENSE`, XcodeGen, CI (GitHub Actions + `xcodebuild test`), SwiftLint; design-system components; bench radios flashed with v1.18 | Empty app builds and tests in CI; component gallery renders light/dark | 3–4 d |
| **1. MeshCoreKit core** | Frame codec for all opcodes/pushes, BLE + TCP transports, session queue, reconnect, APP_START / DEVICE_QUERY, clock sync | Connects to both radios over BLE and the ESP32 over TCP; golden-frame tests pass | 1.5–2 wk |
| **2. ⭐ GPS Feed** | GPSFeedService: source rule (radio GPS if present, else phone), turn-on prompt for a radio GPS that's off, phone pipeline with filter/gate presets, background location + BLE, privacy toggles, status chip, SELF_INFO verification | Radio without GPS: 2-hour drive with the phone locked, position never > 25 m / 10 min stale; flash writes logged; battery impact measured. GPS radio: no phone writes are ever sent | 1–1.5 wk |
| **3. Messaging** | Contact sync (`since`), message sync on 0x83, DMs + ACK states, channels incl. hashtag + QR, room servers, reactions/replies/mentions, location pins + live location, notifications with reply, search, persistence | Daily-driver chat parity with the official app; reactions render in MC1 | 2–3 wk |
| **4. Contacts & map** | Node list/detail, favourites, block, nickname, node alerts, signal meter, request position, position history, navigate-to, QR share, telemetry fetch; MapLibre style, clustering, phone vs radio pins; PMTilesExtractor + OfflineMapStore (Protomaps build discovery, source list in the GitHub repo), bundled world overview, Files import; Internet Map view/import | Airplane mode: basemap zooms to street level inside a downloaded area; size estimate within 5%; Internet Map repeater added as a contact | 2.5–3 wk |
| **5. Radio & admin** | Radio settings/presets, tuning, client repeat, BLE PIN, telemetry modes, key backup, Wi‑Fi setup, device profile export/import, battery/OCV, reboot/power off/factory reset; repeater/room login, status, neighbours, CLI, telemetry charts; Internet Map upload | Fully configure a radio and manage a repeater without another app | 2–2.5 wk |
| **6. Tools** | Trace (log, map, share card), path discovery, RX log with filters/export, stats/noise charts, Line of Sight, range/coverage walk, Local Mesh Discovery, observer MQTT uplink (off by default) | Each tool works on bench radios; discovery always restores settings | 2.5–3 wk |
| **7. iPad & polish** | Split view, keyboard shortcuts, multi-window, route recorder, bundled help, themes, accessibility audit | iPad feels native; VoiceOver pass | 1.5–2 wk |
| **8. Ship** | TestFlight beta (local mesh group), privacy manifest, App Review notes for background location + BLE, reserve the name in App Store Connect, licence and attribution check, App Store listing | Approved build; area downloads work from the current Protomaps build | 1 wk |
| **9. Post-launch** | In-app firmware update (nRF52 BLE DFU; repeater `start ota`), offline LoS elevation, more languages | Each ships as a point release | ongoing |

**Total:** about **15–19 weeks** to launch. A **usable build with the GPS feed and chat comes after Phases 0–3, about 5–7 weeks**.

---

## 8. Risks & mitigations
- **Flash wear from position writes.** Gate the writes, show a write counter, and keep the default heartbeat ≥ 10 min. Consider an upstream PR for a RAM-only position flag.
- **Firmware ignores altitude.** Send it anyway; consider an upstream PR.
- **iOS background limits.** Use both `bluetooth-central` and `location` modes, with state restoration (`CBCentralManagerOptionRestoreIdentifierKey`). The status chip and a disconnect notification keep users aware.
- **App Review and background location.** Make it opt-in, with a clear purpose string and a demo video in the review notes.
- **Protocol drift (frequent firmware releases).** Gate features on the `DEVICE_INFO` version code. Log unknown pushes; never crash on them.
- **Reaction/mention interoperability.** Match the MC1 and official encodings; test across apps.
- **Large offline areas.** Show the exact estimate, enforce a storage cap, warn on cellular, exclude maps from backup.
- **Protomaps build URLs change, or hotlinking is refused.** Discover builds dynamically, keep the source list updatable via the GitHub repo, handle failures gracefully, keep Files import, and ask Protomaps about the project's use. Last resort: someone hosts a planet copy (your call later).
- **Internet Map upload format.** Signing on the radio may not match what the API expects. Verify early (Phase 5 spike) or contact the maintainers.
- **Local Mesh Discovery leaves the radio on the wrong preset.** Persist the original settings before scanning, and restore them on next connect if a scan was interrupted.
- **Firmware update scope.** nRF52 BLE DFU for companions is unconfirmed, so it stays post-launch.

## 9. Open questions
None at the moment. All decisions are recorded in §1.

---

## Appendix A: Meshtastic app features → MeshCore support
Source: Meshtastic-Apple `main`, checked 25 Oct 2026 against MeshCore v1.18.
**Key:** ✅ native protocol support · 🟡 app-side convention or hardware-dependent · ❌ no MeshCore equivalent.

| Meshtastic feature | MeshCore | m-Core |
|---|---|---|
| Channel & direct messages, retry, delivery state | ✅ | §4.2 |
| Tapbacks, replies, @mentions | 🟡 text conventions (MC1-compatible) | §4.2 |
| Markdown formatting | 🟡 other clients show raw markup | Render incoming only |
| Request position | ✅ telemetry request (permission-gated) | §4.2 |
| Canned messages, alert bell | 🟡 app-side | Skip |
| Node list, filters, unheard-nodes banner | ✅ contacts + adverts | §4.3 |
| Favourite / ignore / delete / nickname / node alerts | ✅ | §4.3 |
| Exchange positions / user info | ✅ self advert, share via advert | §4.3 |
| Signal meter, local stats | ✅ SNR, GET_STATS | §4.3, §4.5 |
| Trace route (log, flyover, share card) | ✅ 36 / 0x89 | §4.5 |
| Contact QR / deep links | ✅ export/import contact, `meshcore://` | §4.3 |
| Device, environment, power metrics | ✅ / 🟡 sensor-dependent | §4.3, §4.6 |
| Position log; altitude | 🟡 positions app-side; altitude only from onboard GPS | §4.3 |
| Packet log with filters, CSV export | ✅ 0x88 | §4.5 |
| Waypoints | 🟡 no native packet → location pins | §4.2 |
| Offline maps (Protomaps bbox extract) | n/a | §4.4 |
| GeoJSON, hillshade/terrain, geofence | n/a | Skip (simple map) |
| Route recorder | n/a (phone GPS) | §4.5 (optional) |
| LoRa config, channels, BLE PIN, keys, telemetry config | ✅ | §4.7 |
| Position config | ✅ `gps`, `gps_interval`, advert policy | §4.1 |
| Wi‑Fi provisioning | 🟡 local CLI on Wi‑Fi builds | §4.7 |
| Device role | 🟡 client repeat | §4.7 |
| Reboot / shutdown / factory reset, clock/timezone | ✅ | §4.7, §4.1 |
| Device profile export/import | 🟡 app-built bundle | §4.7 |
| Neighbor info, remote admin | ✅ repeaters (status, remote CLI) | §4.6 |
| Store & forward | ❌ → room servers | §4.2 |
| Local Mesh Discovery | 🟡 preset cycling | §4.5 |
| Range test | 🟡 app equivalent | §4.5 (coverage walk) |
| Firmware update | 🟡 repeater `start ota`; nRF52 DFU unconfirmed | Post-launch |
| MQTT, display, power, audio, lighting, external notification, serial, GPIO, detection sensor, PAX, lockdown, beacons, status message | ❌ | Skip |
| Siri, CarPlay, widgets, Control Center, Live Activity, Watch, TAK, visionOS, tvOS, iMessage stickers | n/a | Skip (your call) |

---

## Sources
- MeshCore firmware: https://github.com/meshcore-dev/MeshCore (`examples/companion_radio/MyMesh.cpp`, `MyMesh.h`, `NodePrefs.h`, `src/helpers/CommonCLI.cpp`, `src/helpers/sensors/EnvironmentSensorManager.cpp`)
- Companion protocol docs: https://docs.meshcore.io/companion_protocol/ · https://wiki.eastmesh.au/meshcore/companion-protocol/
- MeshCore One: https://meshcoreone.com/ · https://github.com/Avi0n/MeshCoreOne · https://apps.apple.com/us/app/meshcore-one/id6757419477
- Meshtastic Apple: https://github.com/meshtastic/Meshtastic-Apple (`Meshtastic/Helpers/Map/PMTilesExtractor.swift`, `OfflineMapManager.swift`)
- Official app: https://apps.apple.com/app/meshcore/id6742354151
- PommeCore: https://apps.apple.com/us/app/meshcore/id6760626211 · https://github.com/mbedworth/PommeCore
- MeshCore Open: https://meshcoreopen.org/
- App comparison: https://mesh-sn.de/en/news/details/meshcore-companion-apps-at-a-glance-meshcore-meshos-and-meshcore-one-for-ios-and-android
- Internet Map: https://blog.meshcore.io/2026/04/04/meshcore-map · https://github.com/recrof/map.meshcore.io-uploader
- Observers/analyzers: https://github.com/Cisien/meshcoretomqtt · https://github.com/Saarlandpower/CoreScope · https://buymeacoffee.com/ripplebiz/meshcore-update-6
- Bridges: https://github.com/mr-tbot/mesh-api · https://sourceforge.net/projects/mtmc-bridge/
- Protomaps / PMTiles: https://docs.protomaps.com/ · https://github.com/protomaps/PMTiles
- Awesome list: https://github.com/samuk/awesome-meshcore
