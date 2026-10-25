// Help pages are prose; wrapping them mid-sentence would make them harder to edit and translate.
// swiftlint:disable line_length

extension HelpArticle {
    static let all: [HelpArticle] = [
        HelpArticle(id: "start", title: "Getting started", symbol: "antenna.radiowaves.left.and.right", body: [
            "m-Core talks to a **MeshCore companion radio** over Bluetooth or Wi-Fi. The radio does the long-range LoRa work; the app is its screen and keyboard.",
            "Tap the **antenna button** (top left) or go to **Settings → Radio** to connect. For a Bluetooth radio tap **Add radio** and pick it from the list iOS shows; for a Wi-Fi radio enter its address and port 5000.",
            "Radios you've used appear under **My radios** for one-tap reconnect. m-Core reconnects to the last radio automatically when it opens.",
            "The antenna turns **green** when connected. Its popover shows the radio's battery, firmware and GPS Feed state.",
        ]),
        HelpArticle(id: "gps", title: "GPS Feed", symbol: "location.fill", body: [
            "MeshCore radios share a position in their adverts. m-Core keeps that position accurate with one simple rule:",
            "• **The radio has GPS:** its own GPS is used. If it's switched off, m-Core offers to turn it on. Phone positions are never written to it.",
            "• **The radio has no GPS:** your phone's location is sent to the radio whenever you've moved far enough, using the movement preset you pick (Walking, Driving, Stationary or Custom).",
            "Turn on **Pause in Low Power Mode** to stop the feed while your phone saves battery. If the radio disconnects while the feed is running, m-Core lets you know.",
            "Positions are only sent after you've moved, to save the radio's flash memory and your battery. You can round positions for privacy, and choose separately whether they're shared in adverts and in telemetry.",
            "For the feed to continue with the screen locked, allow location access **While Using** (a blue pill shows when it's active in the background) or **Always**.",
        ]),
        HelpArticle(id: "chat", title: "Messages and channels", symbol: "bubble.left.and.bubble.right", body: [
            "**Direct messages** go to one contact and are confirmed with a delivery receipt. Under each sent message: *Sent* means it left your radio, *Delivered* means the contact's radio acknowledged it. m-Core retries automatically and finally floods the message if the known path fails.",
            "**Channels** are group chats. *Public* is open to everyone; a **private** channel needs its secret key; a **#hashtag** channel's key comes from its name, so anyone who knows the name can join.",
            "**Rooms** are servers that store messages for people who come back later. Log in to a room to read and post.",
            "Long-press a message to reply, react, copy, show its path on the map, or retry a failed message.",
            "Messages are limited by the radio's packet size; a counter appears in the composer as you get close.",
        ]),
        HelpArticle(id: "status", title: "Reading message details", symbol: "info.circle", body: [
            "Under each received message: the time and its route — **Flood** (it spread through every repeater) or the **hop hashes** of the repeaters it passed (for example `10, A3`). **Direct** means no repeaters were recorded.",
            "A clock icon means the sender's clock looks wrong, so their time stamp may be off.",
            "In **Nodes**, signal bars show the SNR your radio last heard from each node: higher is better, and values below 0 dB are normal on LoRa.",
        ]),
        HelpArticle(id: "nodes", title: "Nodes, repeaters and rooms", symbol: "dot.radiowaves.left.and.right", body: [
            "**Nodes** lists every contact, repeater, room and sensor your radio knows. Each row shows the key prefix, hops, distance and bearing from you, and when it was last heard.",
            "Open a node to message it, fetch its telemetry, ping or reset its path, favourite or block it, set a nickname, or get an alert when it's heard.",
            "To manage a repeater or room, open it and log in with its admin password. You can see its status and neighbours, change its name, radio settings, power, advert intervals, position and passwords under **Settings**, reboot it, or use its command line.",
            "Share a contact with a QR code or a `meshcore://` link. Drag a contact into another app to share its link.",
        ]),
        HelpArticle(id: "maps", title: "Offline maps", symbol: "map", body: [
            "The map works with no signal. A world overview is built in; for street detail, download the areas you need: **Map → Offline maps → Download area**.",
            "Search for a place or move the map, pick **Standard** (streets and towns) or **High** (every street and path), and check the exact size before downloading. Downloads can be paused and resumed.",
            "Map data is © OpenStreetMap contributors, copied from the public build made by Protomaps. m-Core only draws roads, place names, borders and coastlines.",
            "You can also import `.pmtiles` or `.mbtiles` files from Files or AirDrop.",
        ]),
        HelpArticle(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver", body: [
            "**Trace path** sends a test packet along a chosen route of repeaters and shows the signal at every hop.",
            "**Local Mesh Discovery** listens on several regional settings in turn to find which ones are used near you, then always puts your radio back on its own settings. Add your own settings if your local mesh isn't listed.",
            "**RX log** shows every packet your radio hears, decoded. **Coverage walk** pings a repeater as you move and maps where it worked. **Line of sight** draws the terrain between two points with the Fresnel zone. **Route recorder** saves your track as GPX.",
        ]),
        HelpArticle(id: "internet", title: "Internet features and privacy", symbol: "globe", body: [
            "m-Core is fully usable offline. Internet is used only for: downloading map areas, terrain for line of sight, link previews (can be turned off), the Internet Map, the suggested radio settings list, and the observer uplink.",
            "The **Internet Map** (map.meshcore.io) is downloaded only when you ask and shown only if you turn it on. Adding your radio to it is always confirmed first, and the request is signed by your radio.",
            "The **observer uplink** is off unless you turn it on. When on, packets your radio hears are forwarded to the broker you choose. Direct messages and private channels stay encrypted; adverts and Public-channel traffic are readable by anyone on the mesh anyway.",
            "m-Core has no accounts, analytics or ads, and sends nothing to its developers.",
        ]),
        HelpArticle(id: "trouble", title: "Troubleshooting", symbol: "questionmark.circle", body: [
            "**Can't find a Bluetooth radio:** make sure it isn't connected to another phone or app, and that Bluetooth is allowed for m-Core in iOS Settings. Some radios need the PIN shown on their screen.",
            "**Messages don't get through:** check you're on the same radio settings (frequency, bandwidth, SF, CR) as your local mesh. Use Trace path or Local Mesh Discovery to check.",
            "**The radio's position is wrong:** open GPS Feed. If the radio has GPS, make sure it's on and has a view of the sky; if not, check m-Core has location access.",
            "**The map is blank at street level:** download that area under Offline maps.",
        ]),
    ]
}

// swiftlint:enable line_length
