# Walkie Talkie (Flutter, Android + iPhone)

Push-to-talk voice between phones that works **with or without internet**.
Each phone runs every link it can at the same time and, per peer, sends over
the best one that is alive right now:

| Priority | Link | Works when | Range | Notes |
|---|---|---|---|---|
| 1 | **LAN** (UDP) | Same Wi-Fi, or one phone's **hotspot**, internet not needed | Wi-Fi range (~50-100 m+) | mDNS/Bonjour + UDP broadcast discovery, unicast UDP audio |
| 2 | **Bluetooth LE** (GATT) | No network at all | ~30-100 m line of sight | The only no-network link that works Android <-> iPhone |
| 3 | **Internet** (WebSocket relay) | Both phones have any internet (Wi-Fi or mobile data) | Unlimited | Needs a relay server you run (included) |

## Architecture

```
lib/
  core/
    frame.dart              12-byte wire header shared by every transport (+ JSON control msgs)
    fragmenter.dart         split/reassemble frames for small BLE MTUs
    transport.dart          abstract Transport interface + TransportKind priorities
    transport_manager.dart  runs all transports, learns peers, best-link routing, failover, de-dup
    peer.dart
  transports/
    lan_transport.dart      UDP socket :47474, broadcast beacons, unicast audio
    mdns_discovery.dart     Bonjour/NSD advertise + browse "_walkietalkie._udp" (bonsoir)
    ble_transport.dart      peripheral (advertise + GATT server) AND central (scan/connect) at once
    relay_transport.dart    WebSocket client to the relay
  relay/relay_server.dart   tiny dart:io relay (fan-out per channel)
  audio/
    pcm_chunker.dart        mic bytes -> exact 20 ms frames
    voice_pipeline.dart     Opus encode / per-peer decode with packet-loss concealment
    opus_voice_codec.dart   libopus via opus_codec (16 kHz mono, 12 kbps, VOIP, in-band FEC)
    audio_engine.dart       record (mic PCM stream) + flutter_pcm_sound (playback) + audio_session
  messaging/                ring/beep (ringer), voice messages (voice_clip, voice_transfer,
                            outbox = store-and-forward, inbox, messenger), storage
  platform/background_bridge.dart  Android service / notifications channel ("walkie/bg")
  app/walkie_controller.dart  glue: permissions, PTT, rings, messages, background service
  app/call_signs.dart       default call signs
  ui/home_page.dart         hold-to-talk, ring/beep/record buttons, peer list, settings
  ui/inbox_page.dart        received + queued voice messages
tool/relay_server.dart      `dart run tool/relay_server.dart [port]`
```

**Transport interface.** A transport only has to: start/stop, deliver every
valid `Frame` it receives, and `send(bytes, peerIds)` (null = everyone it can
reach). Discovery is implicit: the manager learns peers from the sender id in
any frame (hello beacons go out every 2 s on every running transport). A link
is alive if that peer was heard on it in the last 6 s; the highest-priority
alive link wins, so traffic fails over automatically (e.g. walk out of Wi-Fi
range -> continues over BLE -> continues over the internet relay). The same
frame arriving over two links is de-duplicated by (sender, seq).

**Wire format** (`core/frame.dart`): `'W' 'T' | ver | type | sender u32 |
channel u16 | seq u16 | payload`. Audio payload = one 20 ms Opus packet
(~30 B at 12 kbps). Control payload = tiny JSON (`hello` with name,
`talkStart`, `talkEnd`).

**Channels.** 1-16. Everyone on the same channel hears each other. Peers on
other channels are still listed (so you can see who's around) but not sent
audio. The relay scopes by channel server-side.

## How each link works

### LAN (Wi-Fi or hotspot, no internet needed)
* One UDP socket on port 47474 for beacons and audio.
* Discovery: hello frames go to `255.255.255.255` and the /24 directed
  broadcast of each interface, plus unicast to every address found via
  **mDNS/Bonjour** (`_walkietalkie._udp`, via `bonsoir`).
* Once a frame is received, the sender's IP:port is remembered and audio is
  unicast to it.
* **Hotspot fallback:** if there's no Wi-Fi, one phone turns on its personal
  hotspot and the others join it. That is just a LAN with no internet, and
  gives better range/quality than BLE. iPhone hotspot clients and Android
  hotspot clients can mix.
* iOS: sending/receiving *broadcast* needs Apple's restricted
  `com.apple.developer.networking.multicast` entitlement (request it from
  Apple). Without it, iPhones still work on LAN via Bonjour discovery +
  unicast, which needs only the Local Network permission and
  `NSBonjourServices` (both configured).

### Bluetooth LE (no network at all)
* Every phone is **both** a peripheral (`flutter_ble_peripheral`: advertises
  service `a7e1c0de-5741-4c4b-9e1e-77616c6b6965` and serves a GATT service
  with a notify TX and a write-without-response RX characteristic) **and** a
  central (`flutter_blue_plus`: scans for that service, connects to up to 4
  phones, subscribes to TX, writes to RX).
* Budget: 12 kbps Opus, 20 ms packets -> ~44 B per packet incl. headers,
  50 packets/s (~17 kbps on air). One BLE packet once MTU >= 47 (Android
  requests 512, iOS negotiates ~185). On the 23 B default MTU frames are
  split into 3 chunks by `Fragmenter` (works, but near the practical limit).
* Peer id is learned from the first frame on each link (no room for it in a
  31 B advertisement next to a 128-bit UUID).

### Internet (relay)
* Each phone opens a WebSocket to `RELAY_URL?ch=<channel>&id=<node>`; the
  relay forwards every binary frame to the other phones in the same channel.
  Works across NATs and mobile data because both sides dial out.
* Run the relay anywhere with a public address:
  `dart run tool/relay_server.dart 8080` (or `PORT=8080`). Put it behind TLS
  (Caddy/nginx -> `wss://`) for iOS App Transport Security, and add a shared
  secret before exposing it publicly (there is no auth in v1).
* Configure: `flutter run --dart-define=RELAY_URL=wss://relay.example.com/`
  or paste the URL in the in-app Settings sheet.
* Why not WebRTC in v1: a relay has one moving part and no STUN/TURN; PTT
  audio is only ~2-3 KB/s per talker. `flutter_webrtc` data channels can be
  added later as another `Transport` (the relay would then carry signaling,
  and you'd still need TURN for symmetric NATs).

## Rings, beeps, voice messages and staying reachable (v1.2)

### Stay reachable when the app is closed (Android)
* `ListenService.kt` is a foreground service (type `connectedDevice`, no
  time limit, allowed to start after boot) with a low-priority
  "Walkie Talkie is listening on CH n" notification (tap = open, **Stop** =
  stop listening; with the app closed Stop quits the app completely).
* The Flutter engine is owned by the process (`EngineHolder.kt`), not the
  Activity: closing the app or swiping it from recents only detaches the
  screen, so the Dart side (LAN + BLE + relay links, discovery, rings,
  voice messages, live audio) keeps running. Platform channels
  (`walkie/net`, `walkie/update`, `walkie/bg`) are engine-scoped too.
* A partial wake lock keeps beacons and audio going with the screen off.
* Settings: **Stay reachable when app is closed** (default on) and **Start
  listening after phone restarts** (default off; `BootReceiver.kt`, also
  restarts after an app update). With "stay reachable" off, closing the
  app stops everything like before.
* First run asks for notifications (Android 13+) and explains battery
  optimization, with a Samsung-specific hint (Settings > Battery >
  Background usage limits > **Never sleeping apps**).
* Live push-to-talk received in the background takes audio focus (ducks
  music) and shows "X is talking".

### Ring / Beep
* Per person: ring button (and Ring / Beep in the menu). **Ring all** and
  **Beep** ring everyone on your channel.
* Control messages `ring` / `beep` / `ringAck` (`core/frame.dart`), resent
  every second until acknowledged (max 6 tries), de-duplicated by id
  (`messaging/ringer.dart`).
* The receiver shows a high-priority call-style notification (full-screen
  over the lock screen when allowed) and plays `res/raw/ring.wav` (a
  synthesized two-tone warble, ring volume) with vibration for 15 s, with
  **Answer** (opens the app on that channel) and **Dismiss**. The sender's
  list shows Ringing... / Ring answered / Ring declined / no answer /
  could not reach. Beep plays `res/raw/chirp.wav` (roger chirp).

### Voice messages (store-and-forward)
* Hold **Hold: message** (whole channel), or long-press a person / menu >
  Voice message, record up to 30 s (Opus, same codec as live talk).
* Sent as `FrameType.data` frames: 150 B chunks on Bluetooth (one BLE
  packet), 1000 B on Wi-Fi/internet; selective acks (lowest missing +
  32-chunk bitmap), sliding window and retransmit timeout per link type
  (`messaging/voice_transfer.dart`).
* Not reachable? It stays in the outbox (`messaging/outbox.dart`, saved to
  disk) and is retried whenever that phone is seen again, for up to 24 h.
  Channel messages with nobody around go to the first phones that show up
  on that channel.
* The receiver stores it (`messaging/inbox.dart`), notifies "Voice message
  from X (0:12)" with **Play**, and lists it in the inbox (envelope icon)
  to replay or delete.

### Call signs
* No custom name -> a stable call sign from the phone's permanent id
  (`app/call_signs.dart`, ~120 CB / aviation / NATO / silly ones). The
  dice button in Settings picks another; typing a name overrides it. Old
  "Phone 38EA" style names are replaced automatically.

### What can't work
* A phone that is off, has the app force-stopped, or is put to sleep by
  battery management (Samsung "Deep sleeping apps") can't be reached.
* There is no push server: when the phones can't reach each other (no
  shared Wi-Fi, out of Bluetooth range, no relay), rings fail and voice
  messages wait in the outbox.
* Older (1.1.x) phones ignore rings and voice messages.

## Private groups and the internet relay (v1.3)

*Words used in the app (v2.1.1):* **Open channel** = CH 1-16, anyone on the number can hear; **Private group** = a channel locked with a passcode; **Direct chat** = one friend, only the two of you. "Privately" only ever means a Direct chat.

**Private groups** (a channel locked with a passcode). Tap the lock next to the channel picker, type a passcode
(6+ characters) and tap *Make private*. Others join by picking the same channel
number, tapping the lock and typing the same passcode (shown as text + QR code,
with a short "check code" that matches on every phone with the right passcode).

* Key: PBKDF2-HMAC-SHA256, 120k rounds, salt `WalkieTalkie/private-channel/v1/ch=<n>`,
  then HMAC sub-keys for AES-256-GCM and a 16-bit tag (`lib/core/channel_crypto.dart`).
* Every frame (audio, hello/presence, ping, ring/beep/ack, voice-message chunks/acks)
  becomes a `FrameType.sealed` frame: 12-byte header (channel field = tag,
  authenticated as AAD) + 12-byte random nonce + ciphertext + 16-byte GCM tag
  (29 bytes overhead incl. the inner type byte). BLE voice chunks shrink to
  121 bytes so a sealed chunk still fits one 185-MTU packet.
* Frames that fail to decrypt are dropped silently; private phones ignore plain
  frames and public phones ignore sealed ones (v1.2 phones do not know type 4).
* Voice messages recorded on a private group are only sent while on that
  same private group.

**Relay.** `relay/` is a standalone pure-Dart server (Dockerfile, `PORT` env,
`GET /healthz`, WebSocket on `/ws?ch=<room>&id=<hex>`), deployed on Render via
`render.yaml` (`brion-walkie-relay`). It also runs in Synology Container
Manager unchanged. Limits: 4 KB max message, ~150 msg/s and 64 KB/s per socket,
silent sockets dropped after 3 min, max 64 per room. Private groups use room
`p<tag>`, so the relay only ever sees ciphertext.

The app keeps an ordered list of relays (default since v1.8.8: the home relay
`wss://walkie-relay.tail1700cf.ts.net/ws`, then the backup
`wss://brion-walkie-relay.onrender.com/ws`; Settings accepts a comma separated
list, empty = default, `off` = none), connects to all of them in parallel, sends
every frame to each connected relay and de-duplicates on receive. Reconnects
with 2 s..60 s backoff, 75 s first-connect timeout (Render cold start), text
`ping` every 25 s.

## Replay, hardware talk buttons, urgent rings, battery saver (v1.4)

### Replay missed talk
Every transmission on the current channel (other people's and your own,
marked "You") is kept on the phone as Opus packets: the last 50 per
channel, nothing older than 24 h, at most 20 MB in total
(`lib/history/talk_history.dart`). A transmission ends at talk-end or after
1.5 s of silence; blips under 0.4 s are dropped. Anything that was not
played live with the app open (app closed, you were talking) counts as
"not heard" and is badged. The home screen shows a "recent" strip (tap to
play / pause, "Missed" plays all unheard oldest first); History has
1x / 1.5x / 2x (pitch kept, WSOLA in `lib/audio/time_stretch.dart`),
play all missed, swipe to delete, mark all heard, clear. Private groups
are stored under their own scope and only show while on that private
channel. Limitation: stored unencrypted in app-private storage.

### Hardware talk buttons (Android)
* Tap-to-talk (toggle) mode for the on-screen button; latched talk stops
  after 2 minutes.
* Volume-down as talk button (hold; in toggle mode a tap latches). Works
  with the app open. With the optional accessibility service
  (`PttAccessibilityService`, key events only, no screen content) it also
  works while another app is open and the screen is on. Android does not
  deliver volume keys to apps with the screen off. Sideloaded apps on
  Android 13+ must first "Allow restricted settings" in App info.
* Headset play/pause / hook: a MediaSession active while the listening
  service runs. Tap = toggle, hold = talk while held. If another app plays
  media afterwards it takes the button back until Walkie Talkie is opened.
* "Talk" toggle on the listening notification (lock screen too).
* Background talk needs the listening service to hold the microphone
  foreground-service type, which Android only grants while the app is on
  screen: open the app once after boot.

### Urgent ring
Long-press a person > Urgent ring. The `ring` control message carries
`"u":1` (older phones ignore it and ring normally for 15 s). The receiver
rings for up to 60 s on the alarm stream (sounds in silent mode, alarm
volume raised to at least 70 % while ringing and restored after) with a
strong vibration pattern. With Do Not Disturb access granted, DND is
switched off while an urgent ring sounds and restored afterwards. The
sender keeps retrying an urgent ring for a minute if the phone is out of
reach.

### Battery saver
Hello beacons every 2.5 s instead of 1 s (announced as `"iv"` in the hello
so newer phones wait longer before dropping us; older phones keep seeing
us because they ping every second and we answer), no RTT pings, Bluetooth
scanning in 8 s bursts every 30 s (90 s while linked) with balanced
connection priority, Wi-Fi subnet sweeps every 2 min, relay keep-alive
every 50 s. Talk and rings still arrive; discovery and failover are slower.
The 20-35 % saving shown in Settings is an estimate.

## Friends, chat, photos, location, channel names, moderation (v1.5)

### Friends and Direct chat (1:1 talk)
* **Add a friend** two ways: long-press someone on the main screen >
  *Add friend* (they get an Accept/Decline prompt), or in *Friends* one phone
  taps *Show my code* and the other *Scan a code* (QR, valid 10 minutes;
  works across networks as long as both are online).
* Adding by request uses an X25519 key exchange over the channel link; both
  phones show a **safety code** that should match. The QR route carries the
  secret in the code itself, so it is safe against an eavesdropper.
* Each pair of friends shares a random 256-bit **pair key**. Everything between
  them (presence, talk, voice messages, chat) is sealed with it (AES-256-GCM),
  on any channel, over Wi-Fi, Bluetooth or the internet. Over the internet both
  phones join their own relay room named from a hash of the pair key, so the
  relay only sees encrypted frames.
* *Friends* lists everyone with an online dot (heard within 15 s) and the path
  (Wi-Fi / Bluetooth / Internet). Open a friend: **Hold to talk** talks to
  just them, **Hold: voice msg** records a message delivered when they are
  back (24 h, same store-and-forward as v1.2).

### Chat, photos and location
* Chat bubble icon in the top bar = chat for the current channel; each friend
  has a Direct chat. Unread counts show as badges.
* Text, **photos** (gallery or camera, recompressed to <= 150 KB; over
  Bluetooth only a ~160 px preview is sent and marked as such) and
  **location**: one pin, or *live* for 15/30/60 min (updates every 30 s; tap
  a pin to open Google Maps).
* Chats use the voice-message machinery: chunked, acknowledged, retried and
  stored for up to 24 h for phones not in reach. "waiting" / "delivered"
  shows under your messages.

### Channel names, mute, block, admin
* Tap the lock: give the channel a **name and emoji**; it is shared with
  everyone on the channel via presence (newest wins; on private groups
  only the admin's name is accepted).
* Long-press a person: **Mute** (their live talk is not played here) or
  **Block** (nothing from them at all: talk, rings, messages, chats, friend
  traffic). Unblock in Settings > Blocked.
* Private groups have an **admin**: tick *I'm setting up this channel* when
  making it private (or *Become admin* if nobody is). The admin can
  **Remove from channel** (everyone else gets a new random passcode,
  encrypted with the old one, and moves automatically) and turn on
  **announcement mode** (only the admin can talk; others' talk buttons are
  disabled and their audio is ignored).

### Compatibility
Phones announce feature level 15 in their hello. Chats, names and friend
features are only sent to phones that announce it; 1.4 and older phones keep
working for talk, rings and voice messages and silently ignore the new
messages (unknown control kinds and the extra hello fields are dropped by
their decoders; sealed friend frames are dropped like any frame they cannot
decrypt).

### Limitations (honest list)
* Request-based friend adding has no protection against an active
  man-in-the-middle on the link unless you compare the safety codes. QR is
  safe.
* Each friend uses one extra relay connection per configured relay (since
  v1.8.8 home + backup); many friends = more sockets and battery.
* Admin is trust-on-first-use: the first phone that claims admin on a
  private group is accepted by the others. Anyone who knows the passcode
  could claim it first if nobody has.
* Remove-from-channel is simple: phones out of reach at that moment (or on
  app 1.4) are not moved; give them the new passcode by hand. The removed
  person keeps the old passcode, so they can still decrypt anything
  recorded earlier on the old key, and nothing stops them from joining
  again if someone tells them the new passcode.
* Announcement mode is enforced by the members' apps, not by the network.
* Live location updates only while the app is running; Android may pause
  it in the background. Location and "open in Maps" are Android-only for now.
* Chats and photos are stored unencrypted in the app's private storage
  (at most 300 per conversation); friend keys are in app preferences.
* Direct chat talk to a friend is not saved in the replay history.
* 1.4 and older phones do not see chats, names, friends or moderation.

## v1.8.9: direct phone-to-phone links over the internet

* **What:** two phones on the same channel but on different networks (cell,
  another Wi-Fi) try a direct UDP link and send talk straight to each other.
  It's a small pure-Dart version of what WebRTC's ICE does
  (`lib/transports/direct_links.dart`, `stun.dart`), with no native
  library, no APK growth and no TURN server.
* **How:** each phone asks free public STUN servers (Google, Cloudflare) for
  its public UDP address and lists its local IPv4 / IPv6 addresses. The
  phones swap these candidates and a random per-link token through the
  relays as normal room frames (`ControlKind.dx`, sealed on private
  channels; the lower phone id offers). Then both send small probes to each
  other's candidates for 8 s (hole punching). The first probe that gets
  through opens the link. Every packet carries the receiver's token, so
  nobody else can inject traffic. Frames are the same bytes the relay gets
  (sealed on private groups).
* **Never slower:** frames go over the direct link first and through the
  relays as always; the receiver keeps the first copy (dedupe by sender +
  seq). Talk never waits for a direct link and nothing breaks when one fails
  or dies. If both relays drop, the direct link alone keeps talk going.
* **When:** only for phones on v1.8.9+ that are heard over the internet and
  have no Wi-Fi / Wi-Fi Direct / Bluetooth link (those stay the fast paths).
  A failed attempt is retried after 30 s, 2 min, 5 min, then every 10 min,
  and right away after a network change. Keepalive: a 16-byte ping every
  15 s (25 s with Battery saver); the link closes after 40 s of silence.
  Offline power save turns it off with the relays.
* **Shown:** "via Direct (internet)" on the person's card, "Direct to N" in
  the Internet sheet and status line, a "Direct links" row in the connection
  test (what STUN says about this network, IPv4 / IPv6 path), and link
  up / down / failed events in the debug log.
* **Limits:** strict carrier NATs (CGNAT, symmetric NAT) often block direct
  IPv4 links; IPv6 (common on US carriers) usually works. No TURN, so then
  the relays carry the talk as before. On Android, a phone bound to a Wi-Fi
  without internet skips direct links (the relay's native sockets still work).

## v1.8.8: home relay first, Render as backup

* **Home relay:** the default relay list is now the Synology NAS (the same
  `relay/` server in Docker, public through Tailscale Funnel:
  `wss://walkie-relay.tail1700cf.ts.net/ws`) first and the Render relay
  second. Same protocol on both (`/ws?ch=<room>&id=<hex>`). A saved relay
  setting that is just the old default (the Render URL alone) counts as the
  default; any other custom list is used exactly as typed.
* **Failover design ("both doors open, home preferred"):** the relays do not
  talk to each other, so the app stays connected to every relay in the list
  and sends each frame to all connected relays; receivers drop duplicates by
  (sender, seq) and play the first copy. Two phones therefore always meet if
  they share at least one working relay, so a room never splits when one
  phone cannot reach home. The home relay connects with a 4.5 s timeout and
  one immediate second try (a first TLS handshake through Funnel sometimes
  fails); the backup keeps the 75 s timeout for Render's cold start. While
  the backup carries the traffic, home is retried with backoff up to 2.5 min,
  right away on a network change, when the app comes back on screen, and
  when the backup drops.
* **Which relay:** the internet status line, the Internet icon's sheet and
  the connection test (which now probes every relay) say "Home relay" or
  "Backup relay"; the debug log records every switch and lists each relay's
  state.
* **Warm before talking:** when the app comes back on screen it reconnects
  any relay that is down and pings the open ones, so a socket that died in
  the background is replaced before the next push-to-talk. Keep-alive pings
  every 25 s as before. Friend rooms also use every relay now.

## v1.8.7: setup wizard, connection test, invites, debug log

* **Why nobody shows up:** when the people list is empty, a card under it
  says why. The reasons are: Offline power save is on, the relay is off in
  Settings, the app is still connecting, the relay is not connected (with
  the error and the cell state, plus a button to the right phone settings),
  or the relay works and the other phone must be online on the same channel
  and passcode. A **Connection test** button sits under it.
* **First-run setup wizard** (fresh installs only, skippable at every step).
  The steps are:
  1. Call sign or your own name.
  2. Permissions (microphone, Nearby devices / Bluetooth, location,
     notifications), each with what it is for. The wizard asks instead of the
     usual start-up prompts.
  3. Mobile data / background data check, with **Open App info**.
  4. The battery exemption request, plus steps for your phone maker.
  5. Pick or join a channel: public, or private with a passcode, or scan an
     invite.
  6. Optional Meshtastic radio pairing.

  Re-open it any time from **Settings > Help & setup > Setup wizard**. People
  who update from an older version are never forced through it. They get a
  one-time **Run setup check?** prompt instead.
* **Connection test** (Settings > Help & setup, every connection status
  sheet, and the empty people list). It has one row each for:
  * **Wi-Fi / LAN:** link state.
  * **Wi-Fi Direct:** link state.
  * **Bluetooth:** adapter and permission.
  * **Cell:** same logic as the Cell icon.
  * **Internet:** an HTTPS request to a 204 page, with time.
  * **Relay:** a separate connection to your channel's relay room over the
    app's own network path, a text ping, and the round trip in ms. Nothing
    is sent to people in the room.
  * **Radio:** optional.
  * **Permissions**.
  * **Background / battery**.

  Rows are green, yellow or red, each with a fix button. Grey rows are off
  on purpose (Offline power save, relay "off", Stay reachable off). The test
  runs again when you come back from a settings screen.
* **Background reliability:**
  * The app asks Android to ignore battery optimizations (the system
    "Allow" dialog, with an explanation first).
  * It detects Samsung, Xiaomi / Redmi / POCO, OnePlus, Oppo / Realme,
    Huawei / Honor and Pixel and shows that maker's steps. For example,
    Samsung: Never sleeping apps and Battery "Unrestricted"; Xiaomi:
    Autostart and "No restrictions". Where a known maker screen exists, a
    button opens it, falling back to App info.
  * The listening foreground service now also holds a Wi-Fi lock, so LAN and
    the relay over Wi-Fi stay up with the screen off.
* **Invite link / QR** (Settings > Invite, or the lock / channel sheet). It
  shares your channel (public CH, or private with its passcode) and / or a
  friend add, valid for 1 hour, as a QR code and a share link:
  * `walkietalkie://join?v=1&ch=3&p=...&n=...&f=...` opens the app directly.
  * `https://github.com/Brionwickstrom/walkie-talkie/releases/latest#wt-join?...`
    lands phones without the app on the download page. The parameters are in
    the URL fragment, which is never sent to GitHub.
  * Scanning in the app (Settings > Join with a code, Friends > Scan) or
    opening the link shows a confirm dialog before anything changes.
  * Private-channel QR codes and links contain the passcode, and the app
    warns before showing them.
  * The Meshtastic radio channel key (PSK) is never included.
  * The old private-channel QR text still scans.
* **Send debug log** (Settings > Help & setup, and the connection test). The
  app keeps a rolling log of link, network, cell, channel, people, service
  and test events: 1,500 lines in memory plus a 256 KB file that rotates
  once.
  * The report starts with the app version, phone model, Android version and
    every link's state.
  * Passcodes, friend codes, key-like tokens, private / friend relay rooms
    and precise coordinates (rounded to 0.1 degree) are removed by default.
    Call signs stay.
  * **Share** opens the Android share sheet with the text file (email,
    Drive...). **Copy** puts it on the clipboard.
* Android 11 and older no longer report a missing "Nearby devices"
  permission, because it doesn't exist there.

## v1.8.6: Cell / mobile data icon

* A **Cell** icon now sits next to the Internet icon in the connection icons
  at the top left. It shows:
  * **green bars:** the internet relay is connected over mobile data;
  * **blue-grey bars:** mobile data is available but the app is on Wi-Fi
    (or no relay is set);
  * **orange "no internet" bars:** there is cell service and no Wi-Fi, but
    the relay cannot be reached. Mobile data is probably off or restricted
    for this app (or the relay itself is down);
  * **grey crossed-out icon:** no service, no SIM, airplane mode, or Offline
    power save, like the other icons.
* Bars come from Android's signal level (0-4) and the technology (5G / LTE /
  3G / 2G) from the cell signal types, via
  `TelephonyManager.getSignalStrength()` (Android 9+, details on 10+). That
  needs no new permission. The app never asks for READ_PHONE_STATE. Cellular
  data networks, airplane mode and Data Saver come from ConnectivityManager.
  The app checks every 5 s and again when you open the sheet.
* Tapping the icon opens the same status sheet as the other connection
  icons. **Open phone settings** goes to this app's App info page (Mobile
  data, Background data, Unrestricted data). **Mobile network settings**
  opens the phone's mobile network page (`ACTION_DATA_ROAMING_SETTINGS`,
  falling back to `ACTION_WIRELESS_SETTINGS`).
* iOS shows a basic grey icon. Its button opens the app's settings page.
* The Internet icon is unchanged.

## v1.8.5: pull to refresh (who's here?) and connection settings

* **Pull down** on the Talk screen people list or on Who's where, or tap the
  small **refresh** button next to the list header, to ask everyone "who's
  here?" right now instead of waiting for the next beacon.
* One tiny probe (`LobbyProbe`, a lobby frame starting with `0x50`, 18 bytes)
  goes out on every fast path at once: Wi-Fi / LAN broadcast + multicast and
  a one-off subnet sweep, Wi-Fi Direct (a 20 s discovery burst), a Bluetooth
  scan burst, the relay channel room and the relay lobby room (a dropped
  relay is reconnected first), and the phone mesh, which passes it on up to
  the probe's TTL (3 hops) with its own per-phone limit (once per 5 s).
* Phones that hear it answer straight away with their presence hello and
  Who's where beacon, after a random 0-500 ms delay so they do not all talk
  at once, and at most once per 5 s per asking phone. "Show me in Who's
  where" off: only the channel presence answers, as before.
* The spinner stops when answers stop arriving (or after about 3 s) and a
  toast says "Found N people".
* **LoRa radio:** never on a normal refresh. Hold the refresh button, or tap
  "Also ask over radio (slow)" in the toast (shown while a radio is
  connected), to send the probe over the radio too: at most once per
  2 minutes, and phones answer a radio probe over the radio at most once
  per 2 minutes. Radio answers can take a minute.
* **Offline power save:** no relay (nothing is sent to or reconnected on the
  internet) and no subnet sweep; Wi-Fi / Bluetooth / Wi-Fi Direct / mesh
  still get the probe.
* Older versions ignore the probe (it is not a valid lobby beacon), so they
  just show up on their normal schedule.
* **Connection icons open their settings.** Tap a connection icon at the
  top left (or the "Internet: ..." line) to see that connection's status
  (Connected / Off / Not working / Bluetooth permission missing) and one
  button: Internet -> this app's App info page (Android
  `ACTION_APPLICATION_DETAILS_SETTINGS`: Mobile data, Background data,
  Unrestricted data, Battery); Wi-Fi and Wi-Fi Direct -> Wi-Fi settings;
  Bluetooth -> Bluetooth settings, or "Allow Bluetooth" first when the
  Nearby devices permission is missing; LoRa radio -> the in-app radio
  pairing. Nothing opens until you tap the button. On iOS the button opens
  the app's page in Settings.
* **"Allow mobile data"** appears next to the internet status when the
  phone is on mobile data, a relay is set and it cannot be reached (not in
  Offline power save); it opens the internet sheet above.
* **Settings > Battery: "Phone settings for this app (mobile data,
  battery)"** opens App info directly.

## v1.8.4: map search (find trail maps online, search offline)

* **Search button on the Trip map** (also in full screen). Typing searches
  everything already on the phone, live and with no network: imported trail
  names and waypoints, peaks / lakes / trailheads / springs / campsites /
  shelters saved by map search, my pins, shared pins, people on the map,
  recorded and shared trails, downloaded map areas and imported MBTiles
  maps. Exact and prefix matches rank first, closer things win ties.
  Tapping a result centers the map and highlights it (yellow line or ring,
  20 s). Imported layers are indexed when they are imported or loaded
  (`lib/trip/search/offline_search.dart`).
* **Find maps online** (press search): places come from OpenStreetMap's
  Nominatim, following its usage policy: identifying User-Agent, at most one
  request per second app-wide (`RateLimiter`), results cached for 6 h, no
  search-as-you-type, attribution under the results. Picking a place zooms
  there and offers:
  * **Get trails for this area**: one Overpass API request for named
    paths / footways / tracks / bridleways, hiking route relations,
    trailheads, peaks, lakes, springs, drinking water, campsites and
    shelters inside the place's outline (falls back to its box), capped to
    40 km a side, 30 s server timeout, 12 MB answer cap, one busy-server
    retry. Ways of the same trail are joined; ways in a hiking route are
    drawn once as the route. Saved as an offline trail layer with
    "© OpenStreetMap contributors, ODbL" shown in Map layers and on the map.
    "Get trails for the area on screen instead" uses the visible map.
  * **Download topo map for offline**: opens the existing OpenTopoMap area
    download for the place (same estimate, detail slider and 3000-tile cap).
* **No signal** (or Offline power save on): online search says "Search
  needs signal; offline search below" and offline results still show.

Limits: online search needs signal; OSM trail data is only as complete as
OpenStreetMap (unnamed paths are skipped; check official maps and
closures); the public Overpass server can be slow (up to a minute) or busy;
very large places are trimmed to their middle 40 km.

## v1.8.3: friends over LoRa, read receipts, battery, map imports

* **Friend chat over the Meshtastic radio.** When a friend can be reached
  no other way, 1:1 texts, locations, rings and short Codec2 voice clips
  (8 s max) go over LoRa, still end-to-end encrypted with the per-pair
  friend key, chunked to fit, sent to the friend's radio node when it is
  known (broadcast otherwise). Photos wait for a faster link. Messages show
  "via radio". Friend packets relayed by the phone mesh or LoRa are
  accepted (checked by key, not by path) and de-duplicated.
* **Friend chat header.** It now follows the real path:
  "Connected privately via Wi-Fi / Bluetooth / phone mesh (N hops) / radio
  (slow)", "… last heard 40 s ago, reconnecting" for 2 min, and only then
  "Not connected privately". Before, it only counted a private hello heard
  in the last 15 s on a direct link, so lossy Bluetooth or a re-scan
  flipped it to "Not connected yet" while messages were being delivered.
* **LoRa extras.** Check-ins and lost-contact alerts work radio-only;
  map pins (camp, water, meet-up, custom label) are one ~15-30 byte
  packet; read receipts (Settings > Send read receipts) batch up to 8 ids
  in one tiny packet (20 s batching over the radio) and show "seen";
  phone battery rides in presence hellos, check-ins and lobby beacons and
  shows on people cards and in Who's where; a very rare Who's where lobby
  beacon goes over LoRa every 15 min (public channel or just "private" +
  call sign, kept 45 min); Trip settings > trail summary over the radio:
  Off / 5 / 10 / 15 min while recording.
* **Map imports (Trip tab, layers button or Map style > Import).**
  * GPX, KML and KMZ from AllTrails, CalTopo, Gaia GPS, Google My Maps
    (file picker, or "Open with" / "Share" to Walkie Talkie): tracks and
    routes as lines (routes dashed), waypoints as pins. Layer list to show
    / hide, rename, recolour, delete, show on map.
  * Share an imported route with the group: compressed (delta + zlib)
    over the fast links and the phone mesh; over LoRa only a 16-point
    Douglas-Peucker outline if it stays within 150 m of the real line,
    otherwise nothing.
  * MBTiles (raster PNG/JPG) as an offline base map, stored on the phone.
  * A park map picture or PDF (page 1 drawn as an image) as an overlay:
    place it by dragging / pinching / twisting it into place, or with 2-3
    control points (tap the picture, then the map); opacity slider.
  * Storage: imported layers may use 2 GB (MBTiles up to 1.5 GB each,
    images 40 MB, PDFs 60 MB, GPX/KML 20 MB); sizes shown per layer.

## v1.8.2: Who's where

A people/compass button (with a badge counting people on *other* channels)
on the "N on CH x" header of the Talk screen opens **Who's where**: everyone
this phone can see, grouped by channel. Tap a channel's **Go** to switch
there, tap a person for details (the full person card for people in the
people list).

* **What it shows.** Public channels: number, name/emoji and the people on
  it with their path icons (Wi-Fi, Wi-Fi Direct, Bluetooth, internet, "N
  hops" through the phone mesh). Everyone on a private group is listed
  only under one **Private** group with their call sign: no channel number,
  name, emoji or key tag. Your own channel is first (marked private if it
  is; only you see that). Friends show with a star and the name you gave
  them; friends online but not in the lobby go under **Friends**.
* **How it is discovered** (`core/lobby.dart`, `app/whos_where.dart`):
  normal presence stays inside a channel (separate relay rooms, sealed
  hellos on private groups), so v1.8.2 adds a small public **lobby
  beacon** (frame type 7, ~30-70 bytes): call sign/name + public channel
  (+ its name/emoji), or just "private" + the call sign. It goes out every
  10 s on the local links (20 s battery saver, 60 s offline power save;
  the phone mesh passes it on, at most once per phone per 8 s) and, while
  online, every 30 s (60 s saver) in a shared relay room `ch=lobby` on each
  configured relay. Only lobby frames are read from that room. Never over
  LoRa. Entries expire after 3x the sender's interval (min 25 s); inbound
  beacons are rate limited (20/s, one per phone per path per 2 s) and
  capped at 256 phones.
* **Settings > Show me in Who's where** (on by default): off sends no lobby
  beacon and adds `hw: 0` to hellos so v1.8.2 phones do not list you under
  other channels (you still show on your own channel as before).
* **Power save.** Offline power save: no relay lobby, local beacons every
  60 s. Battery saver: relay lobby only while the app is on screen.
* **Older phones** (before 1.8.2) send no lobby beacon: they show only when
  nearby on a public channel (their plain hellos) or on your channel.
* **Relay server:** no change needed (the existing relay accepts any room
  name; `lobby` is just another room, max 64 phones per room).

## v1.8.0: Trip tab (map, SOS, check-ins, trails, weather)

A new **Trip** tab (bottom bar: Talk / Trip) works online and offline. Every
Trip message goes over whatever path reaches the person: internet relay,
LAN, Wi-Fi Direct, Bluetooth, the phone mesh, and the Meshtastic radio
only as the last resort, with the same fastest-path routing as talk. Trip
packets are frame type 6 (older phones ignore them) and are sealed on
private groups like everything else. Radio, relay and base camp options
stay in **Settings > Off-grid**.

**Map.** `flutter_map` with OpenTopoMap (default) or OpenStreetMap, with
attribution shown. People appear as dots with name, age of their fix and a
path icon (Wi-Fi, Bluetooth, mesh, radio). Long-press to drop a shared pin
(camp, water, trailhead, meet-up, danger, car or custom).
*Offline maps:* "Download area" saves the visible area for chosen zooms,
shows the tile count and size first, and has a progress bar and cancel.
Downloads use OpenTopoMap or a custom tile server only, are throttled (2
connections, short pauses) and capped at 3000 tiles per area, because the
OpenStreetMap tile policy forbids bulk/offline downloading; OSM tiles you
have viewed are still cached for offline use. The cache is capped at
500 MB (oldest non-downloaded tiles are trimmed) and keeps tiles at least
7 days, re-checking with ETag/Last-Modified.

**SOS.** Hold the SOS button for 3 s (or tap and confirm). It is sent to
everyone on every path including LoRa at the highest radio priority, and
repeats (fast links every 10 s, radio every 30 s, at most 20 radio copies
to respect duty limits) until someone acknowledges, then once a minute.
Receivers get a loud alarm and full-screen alert even when the app is muted
(SOS from any public channel is accepted), with Acknowledge / Silence /
Show on map. The sender sees who acknowledged and can cancel; a cancel stops
the alarm on every phone.

**Check-ins and lost contact.** With trip mode on, your position is sent
on fast links every 15-60 s and a check-in every 5 min (configurable, also
by radio if "check-ins over radio" is on). If someone has not been heard
for 20 min (configurable) you get a lost-contact alert with their last
known location and time.

**Distance and bearing** ("0.8 mi NE") with a compass arrow on people cards
and the map; the arrow uses the phone's compass (accelerometer +
magnetometer). Miles/feet or km/m.

**Network map.** The Trip tab shows a graph of who you hear and how:
direct links (green), relayed hops (orange) and radio (purple dashed),
with RTT, RSSI, LoRa SNR and last heard.

**Quick messages.** One-tap canned messages ("On my way", "Need help", "At
camp" ...) are 5-byte coded packets; custom ones are editable and short.

**Trails.** Record a breadcrumb trail (battery aware: 5 s while moving,
backing off to 60 s when still, at least 20 s in battery saver; bad fixes
and tiny moves are skipped). Trails show on the map, can be shared
(delta-compressed chunks on fast links; over LoRa only a thinned 16-point
summary), have a **Backtrack** view (distance back along the trail) and
export as GPX 1.1.

**Base camp mode** (Settings > Off-grid). A phone left at camp stores Trip
messages (check-ins, SOS, acks, quick messages, pins, trail summaries) for
people out of range and hands them over when they come back, over any path
including the radio. Messages expire after 6 h, the store is capped at 300
items / 64 KB, and copies are de-duplicated by mesh packet ids. Turning it
on also turns on relaying.

**Weather and daylight.** Open-Meteo forecast (no key) for your position,
cached and shown offline with its age; sunrise/sunset are also calculated
on the phone, so daylight works with no internet at all.

**Limits (honest list).**
* Background location only works when the app started its background
  service while in the foreground with location allowed ("Allow all the
  time" helps); otherwise positions update while the app is open.
* The SOS alarm bypasses Do Not Disturb only if DND access was granted; it
  plays on the alarm stream so silent/vibrate mode does not mute it.
* No offline downloads of OpenStreetMap tiles (policy); topo areas are
  limited to 3000 tiles each.
* The compass needs calibration (figure-8) and assumes portrait.
* Base camp stores Trip messages only (not chat or voice, which already
  have their own store-and-forward).
* Weather needs internet once; iPhone builds have no Trip location bridge yet.
* LoRa duty limits apply: live positions and full trails never use the radio.

## v1.7.0: long-range radio (Meshtastic LoRa)

Pair a Meshtastic radio (RAK WisMesh Pocket V2, SenseCAP T1000-E, or any
Meshtastic node with Bluetooth) in **Settings > Long-range radio
(Meshtastic)**. The phone talks to it over the official Meshtastic BLE API
(service `6ba1b218-15a8-461f-9fa8-5dcae273eafd`, ToRadio / FromRadio /
FromNum, `want_config` handshake) and sends app frames on port
`PRIVATE_APP` (256), so stock Meshtastic nodes on the same channel relay
them without showing them as chat.

**Pairing PIN:** screenless radios (T1000-E) use the fixed PIN `123456`.
Radios with a screen (WisMesh Pocket) show a 6-digit PIN on their screen
during pairing. Only one phone app can use a radio at a time: close or
disconnect the official Meshtastic app first.

**What goes over LoRa:** text chat, location (live location at most every
5 min), urgent rings (once per 20 s while ringing), a small presence hello
about every 5 min, and voice messages up to 8 s as Codec 2 700C clips
(28 bits per 40 ms: an 8 s clip is about 700 bytes, sent as 5-6 chunks of
140 bytes and reassembled). Live push-to-talk audio, photos, long voice
messages and friend (1:1 private) chats wait for a faster link.

**Routing:** the fastest path wins and LoRa is only used when nothing else
(Wi-Fi, Wi-Fi Direct, Bluetooth, the phone mesh, internet) reaches the
person; local paths are never delayed by it. LoRa frames carry the same
mesh ids, so a copy arriving over both LoRa and Bluetooth is delivered once,
and frames heard over LoRa are never relayed again by the phone mesh (no
double relay). Private groups stay end-to-end encrypted: the radio only
carries sealed frames. A token bucket (4 packets, then one per 8 s) and a
priority queue (urgent > chat > voice > presence, expiring after 3 min)
keep the channel usable.

**Set the radios up first (official Meshtastic app):**
- Region: `US` (915 MHz) on every radio, same modem preset (`LongFast`).
- A shared **private** primary channel with a random key; share it to the
  other radios by QR code. The default public channel works but everyone
  nearby can see packet metadata.
- Hop limit 3 (or more for big groups), transmit enabled.
- Bluetooth on (PIN mode: fixed `123456` on the T1000-E).

Codec 2 is vendored from `drowe67/codec2` (LGPL-2.1, see
`android/app/src/main/cpp/codec2/COPYING`) and built as `libcodec2.so`.

## v1.6.0: off-grid range (mesh relay + Wi-Fi Direct)

For hikes with no internet or cell signal.

**Mesh relay ("Relay for others", Settings, on by default).** Phones pass
talk on for each other so a group strung out along a trail can still talk
(up to 4 radio hops). See `lib/core/mesh.dart`.

- The original sender is unchanged: plain frames on the best direct link,
  no extra header, no delay. Phones close together never relay anything.
- Packet id = 64-bit hash of the origin's encoded frame (sender + seq +
  payload, plus the random nonce on private groups), so the direct copy
  and all relayed copies share one id. A seen-id cache (30 s, 4096 ids)
  drops duplicates; each phone relays a packet at most once, and the
  receiver keeps playing the first copy (existing per-sender dedupe).
- Relayed copies travel in a new frame type 5 envelope: hops, max hops
  (TTL, default 4), destination (0 = all) and the origin's bytes unchanged.
  Private-channel and friend frames stay sealed end to end; relays cannot
  read them.
- Phones beacon (type 5, every 2 s and right away when a new phone shows
  up) the ids they hear directly. A packet is relayed only to mesh
  neighbours that did not hear the source directly and are not already
  covered by the previous hop; targets are re-checked after a 2-12 ms
  random jitter (relayed hops only). Pings are never relayed, presence
  (hello) at most every 3 s per phone, everything capped at 100 packets/s
  and 12 KB/s to protect Bluetooth. Nothing heard over the internet relay
  goes into the mesh, and mesh frames never go to the internet relay.
- People cards show "via 2 hops" for phones reached only through others;
  Missed / History show the hop count. Rings, voice messages and chat to
  those phones also travel over the mesh (paced like Bluetooth).
- v1.5.x phones drop type 5: they are never relay targets, but their own
  talk is still relayed by v1.6 phones.

**Wi-Fi Direct (Android, Settings switch, on by default).** Wi-Fi P2P
service discovery (`_walkietalkie._udp`, node id in TXT) finds nearby app
phones; when there is no shared network with one, the phone with the larger
id asks to join / form a group (`WifiDirectBridge.kt`, policy in
`lib/transports/wifi_direct_transport.dart`). Frames then travel as UDP on
port 47475 inside the group (owner 192.168.49.1 + group broadcast). Needs
"Nearby devices" (Android 13+) or location (older). iPhones have no public
Wi-Fi Direct API: the transport is not created there; they use Bluetooth or
a hotspot.

**Priority:** Wi-Fi/LAN > Wi-Fi Direct > Bluetooth > internet; frames to a
peer go on the best live link (plus the runner-up while it looks stale), so
the fastest path wins and duplicates are dropped.

Limits: Android may show "accept connection" on the other phone for Wi-Fi
Direct; a phone only relays while the app runs (Android background service
is fine, iPhones may stop relaying when the screen is off for a while); each
hop adds a few ms plus radio latency, and Bluetooth carries about one voice
at a time across a hop.

## v1.5.4: private talk heard by everyone (the real cause)

Report: "If I create a private chat it plays on just the person's phone. But
when they talk it plays on all phones" (all phones on 1.5.3, over the
internet).

**Cause: the reply, not the encryption.** Private talk from a friend plays on
the home screen, and the "is talking" notification opened the channel. The
friend then answered with the big HOLD TO TALK button (or a talk key /
toggle / the notification), and that button always goes to the whole
channel (`WalkieController.pushToTalk`). Private frames themselves never
leaked: they are sealed with the pair key, sent only to the friend's own
relay room (`FriendLinks.send` -> `_relays[key.room]`, room = "f" + 16 hex,
never the channel room), and a phone without the pair key cannot open them
(the channel key only opens its own tag; unknown sealed frames are dropped).
`test/private_relay_test.dart` checks this over the relay only, both ways,
after accept and after QR add, with a 3rd phone on the channel (and even
inside the friend room): it hears nothing, and the channel room carries no
extra frame.

Fix:

* **Reply on the home screen.** For 30 s after private talk / a voice
  message from a friend (renewed by each reply), a purple banner
  "🔒 Private from Ann: Hold here to reply privately" sits above the big
  button, and the big button itself becomes "HOLD TO REPLY" with a lock,
  "Reply privately to Ann". Talk keys and tap-to-talk follow the same rule
  (`MainTalkRouter`, `lib/app/private_reply.dart`). "Talk to channel
  instead" switches back. A refused private talk never falls back to the
  channel.
* **Who hears it.** The big button says "Talk to CH 1 (3 people)".
* **Notifications.** "🔒 Ann is talking to you privately" and friend voice
  messages open that friend's chat, not the channel.
* **Version gate.** Presence now carries feature level 16. Private talk to a
  friend whose app announces less (1.5.0-1.5.3 all send 15) is blocked with
  "Ann needs to update to talk privately" (voice messages still work), so an
  old app can't answer through the channel button.

## v1.5.3: saved messages looping (the real cause)

Saved voice messages and History replays kept playing over and over. The
cause was in `AudioEngine.playClip` (lib/audio/audio_engine.dart), present
since v1.4.0. It fed the decoded clip to the speaker in 20 ms pieces made
with `Int16List.sublistView(samples, i, end)` and wrapped each piece as
`PcmArrayInt16(bytes: chunk.buffer.asByteData(offset, length))`. But
`FlutterPcmSound.feed` sends `buffer.bytes.buffer.asUint8List()`, the
whole backing buffer, ignoring the view. So every 20 ms piece queued the
entire clip again in the native player: a 10 s message was queued 500 times
(83 minutes). Stop only stopped feeding, not the copies already queued, so
it only ended when the app's process died (phone restart).

* `exactPcm` (lib/audio/clip_player.dart) copies exactly the samples of a
  view; every feed (saved clips and live talk) goes through it.
* `ClipPump` feeds a clip in real time and ends exactly once: at the end
  plus 300 ms, or at the latest after the clip's length plus 1 s (hard cap).
* When a clip ends or is stopped, the native player's queue is flushed
  (release + setup), so nothing keeps playing. Stop also flushes it.
* Leaving the Voice messages or History screen stops saved playback.
* `test/clip_playback_test.dart` feeds through a fake speaker that behaves
  like the plugin: the old code queues the clip 500 times, and the new one
  plays each sample once at 1x/1.5x/2x and for "play all" over 3 items.
  It also covers Stop and the hard cap.

## v1.5.2: loops from older phones, clean slate

Still looping on 1.5.1 with every other phone on 1.5.0 or older: voice
messages never play by themselves (no build ever auto-played them), so the
loop was live audio. An older phone with its mic stuck on (the v1.5.0 race)
re-broadcasts everything its speaker plays; with two of them, an old message
bounces between them forever, AGC keeping it loud, and every phone in the
channel played that stream. A 1.5.1 phone can't turn the other phones' mics
off, so 1.5.2 refuses to play it:

* `LiveAudioGate`: live audio plays only while the sender says it is
  talking (talkStart). After talkEnd only a 1 s tail plays; a stream with no
  talk signal at all plays at most 30 s; non-stop talk is capped at 3 min;
  an Opus packet identical to one from the same sender in the last 30 s is
  dropped (late copy over another transport). Blocked audio isn't kept for
  "Missed" either.
* Stop silences every live stream (channel and 1:1) until that phone talks
  again, and also stops voice messages, replays and "Play all missed".
* First launch of 1.5.2: the outbox (voice and chat queues) is cleared, so
  this phone never re-sends an old message; every received message is marked
  played and seen; every missed-talk take is marked heard.
* Voice messages now carry their send time (a trailer older apps ignore).
  Received: older than 25 h dropped (still acked); older than 10 min or
  from an older app (no time) filed quietly as played, no notification.
* The loop also happens with only new phones *playing*: one phone with a
  mic left on, in the same room, hears every other phone's speaker and
  sends it back (speaker -> its mic -> their speaker...). A message sent
  after the update then loops on 1.5.1 phones too; `test/room_loop_test`
  reproduces that through the real TransportManager (endless on 1.5.1,
  cut after the 1 s tail on 1.5.2).
* Settings > Messages > "Auto-play incoming talk" (on by default). When
  it's off, nothing plays by itself: talk goes to Missed and voice
  messages wait in Voice messages.
* Talk keys (headset, volume-down, notification) can't start talking while
  something plays or for 2 s after. Bluetooth devices send play/pause by
  themselves when audio starts or stops.
* Checked: the app runs in a single Flutter engine (`EngineHolder`, shared
  by the activity and the listening service), so one isolate owns
  playback. Seen ids are one file (`seen.json`) per messenger, written by
  that isolate; nothing uses a SharedPreferences cache for them.
* Edge to edge (Android 15+): Settings and every other bottom sheet open
  below the status bar and keep their last row above the navigation bar
  (`showAppSheet`). The home screen keeps the talk button above the nav bar
  (`SafeArea` in `HomeBody`), and History's list pads for the nav bar.
  `test/insets_test` covers this with a 24 px status bar and 48 px nav bar.
* Settings > Messages: "Playback log" (what played, from whom, via which
  link, and why audio was blocked; also in Details) and "Clear all messages
  and queues".
* Checked and not loop sources: flutter_pcm_sound (Android blocks on its
  queue, iOS fills silence on underrun, neither repeats a buffer), loss
  concealment (max 3 frames, never re-decodes a packet), one Flutter engine
  shared by the service and the UI (one player). "Play all missed" builds
  its queue once and marks each take heard as it starts. A notification
  "Play" plays that message once and never restarts it if it's already
  playing.

## v1.5.1: endless replay fix
Root cause: a quick tap on a talk / record button (or the headset key) could
stop the mic while it was still opening; the stop did nothing and the mic
then stayed on in the background service until the phone restarted. That
phone kept sending whatever its speaker played (other people's talk and
voice messages), so everyone heard the same audio over and over, and two
phones in that state echoed each other endlessly. Fixes: mic start/stop are
serialized (`MicGate`), late mic audio after a stop is dropped, a 1 s
watchdog turns off a mic nobody is using, "Stop audio" on the notifications
and a Stop banner in the app stop all playback/talk/recording, closing the
app or "Stop" on the notification stops all audio. Voice messages are also
remembered by id across restarts (shown/announced once, every copy acked),
and senders give up on a phone after 30 unanswered attempts.

Private talk heard by everyone (same root cause): with the mic stuck on for
the channel, "Hold to talk" to a friend found the mic "already on" and did
not re-route it, so the voice kept going to the whole channel. Now a new
talk session always restarts the mic for its own destination, channel audio
is never sent while talking privately, and 1:1 talk is refused ("Not
connected privately yet") unless the friend is paired and heard on a
pair-key-sealed link; there is no channel fallback.

## Android <-> iPhone limits (important)
* **No shared Wi-Fi Direct.** Android's Wi-Fi Direct / Wi-Fi Aware and
  Apple's AWDL / MultipeerConnectivity do not interoperate. Google Nearby
  Connections is Android-only for its high-bandwidth modes. So:
* **BLE is the only cross-platform link with zero network.** Short range,
  low bandwidth, but enough for compressed voice.
* **Hotspot is the range fallback.** One phone's hotspot = LAN with no
  internet; works across platforms with full quality.
* iOS background: BLE scanning/advertising is heavily throttled when the app
  is backgrounded (service UUID moves to the "overflow area", other iPhones
  in background may not see it). Keep the app in the foreground for v1.

## Permissions configured
* **Android** (`AndroidManifest.xml`): RECORD_AUDIO, MODIFY_AUDIO_SETTINGS,
  INTERNET, ACCESS_NETWORK_STATE/WIFI_STATE, CHANGE_WIFI_MULTICAST_STATE,
  NEARBY_WIFI_DEVICES, BLUETOOTH_SCAN/CONNECT/ADVERTISE (12+), legacy
  BLUETOOTH/ADMIN (<= 11), ACCESS_FINE/COARSE_LOCATION (BLE on <= 11 and
  location sharing), CAMERA (QR scan / photos, from mobile_scanner), WAKE_LOCK, FOREGROUND_SERVICE(+MIC,
  CONNECTED_DEVICE), POST_NOTIFICATIONS, USE_FULL_SCREEN_INTENT, VIBRATE,
  RECEIVE_BOOT_COMPLETED, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS. minSdk 24.
* **iOS** (`Info.plist`): NSMicrophoneUsageDescription,
  NSBluetoothAlwaysUsageDescription, NSLocalNetworkUsageDescription,
  NSBonjourServices (`_walkietalkie._udp`), UIBackgroundModes (audio,
  bluetooth-central, bluetooth-peripheral). `ios/Podfile` sets iOS 15 and the
  permission_handler macros (microphone, bluetooth).

## Packages
| Need | Package | Why |
|---|---|---|
| BLE central | `flutter_blue_plus` 2.x | Most used/maintained BLE central plugin for Android+iOS. **License:** free for personal/non-profit use; for-profit use requires a commercial license (`BleTransport.fbpLicense`). |
| BLE peripheral + GATT server | `flutter_ble_peripheral` 3.1 | Maintained (Sep 2026), now serves GATT characteristics + notify on Android and iOS. (`ble_peripheral` was last released Dec 2024.) |
| mDNS | `bonsoir` 7.1.5 | Uses native NSD/Bonjour, so it works on iOS without the multicast entitlement. Pinned below 7.1.6 because its Linux plugin conflicts with flutter_blue_plus's `dbus` (Linux only). |
| Opus | `opus_codec` + `opus_codec_dart` 3.0.5 | Maintained successor of `opus_flutter`/`opus_dart` (those are stuck on Dart < 3). Ships libopus for Android and iOS. |
| Mic PCM | `record` 7 | `startStream` with raw PCM16, echo cancel/noise suppression. |
| Playback | `flutter_pcm_sound` | Low-latency raw PCM16 feeding on both platforms. |
| Audio session | `audio_session` | playAndRecord / voiceChat, speaker by default. |
| Relay client | `web_socket_channel` | Standard. |
| Permissions | `permission_handler` | Runtime permissions. |

## Status of v1
Tested on the build box (no devices): `flutter analyze` clean; 94 unit tests
pass, covering framing, BLE fragmentation, PCM chunking, the voice pipeline
(loss concealment, late-packet drop), the TransportManager (best-link
preference, failover, routing, de-dup, channels, hello), the LAN transport
over real loopback UDP sockets, and the relay server + client end-to-end.

**Not yet run on real phones** — the following are written against the
plugin APIs but unverified:
* BLE transport (advertise + GATT, scan/connect, MTU, notify throughput).
* Opus encode/decode via the native lib, mic capture and playback, iOS audio
  session interplay between `record` and `flutter_pcm_sound`.
* mDNS discovery and the permissions flow.
* No iOS or Android build has been run yet (no Android SDK / Xcode on the box).

**Stubbed / simplified:**
* Relay has no auth/TLS (put it behind a TLS proxy); no WebRTC yet.
* iOS has no background service (Android only).
* No floor control: two people can talk at once; incoming audio is muted
  while you transmit.
* Both phones may connect to each other as BLE centrals (2 links); harmless
  (de-duplicated) but wasteful.

## Next steps: testing on real devices
1. `flutter pub get`, then `flutter run` on two Android phones on the same
   Wi-Fi: check both appear with the Wi-Fi icon and voice works.
2. Turn Wi-Fi off on both: they should fail over to Bluetooth (icon changes
   within ~6 s). Check audio quality/latency at 5, 20, 50 m.
3. Add an iPhone (open `ios/Runner.xcworkspace`, set the signing team, run
   on device). Accept the Local Network and Bluetooth prompts. Test
   iPhone <-> Android on Wi-Fi, then BLE only.
4. Hotspot: phone A hotspot on, others join it with mobile data off.
5. Internet: deploy the relay, set `RELAY_URL`, put one phone on mobile data
   and one on a different Wi-Fi.
6. Then: Android foreground service, iOS background behaviour, persist
   settings, relay auth, optional WebRTC transport, BLE single-link
   negotiation, adaptive bitrate (higher on LAN).

## Commands
```
flutter pub get
flutter analyze
flutter test
dart run tool/relay_server.dart 8080
flutter run --dart-define=RELAY_URL=ws://<your-ip>:8080/
```

## In-app updates (GitHub Releases)

The Android app updates itself from the public repo
[Brionwickstrom/walkie-talkie](https://github.com/Brionwickstrom/walkie-talkie/releases).

- A few seconds after start, and when you tap **Settings → Check for
  updates**, the app calls
  `https://api.github.com/repos/Brionwickstrom/walkie-talkie/releases/latest`.
- The release tag (`v1.2.0` or `v1.2.0+4`) is compared with the running
  version from `package_info_plus` (`lib/update/app_version.dart`; build
  numbers are compared modulo 1000 because arm64 split APKs report
  `2000 + build` as their versionCode).
- If newer, a dialog shows the release notes. **Update** downloads the
  `WalkieTalkie.apk` asset with a progress bar into the app cache and opens
  the Android installer through a `FileProvider` (`walkie/update` platform
  channel in `NetUpdateBridge.kt`, `REQUEST_INSTALL_PACKAGES` permission).
- The first time, Android asks to allow **Install unknown apps** for Walkie
  Talkie; the app explains this and opens that settings page.
- **Later** hides the startup prompt for that version until the next launch.
- iOS: no-op (Settings shows the version only).

The settings sheet shows the current version, e.g. `1.1.0 (2003)`.

### Releasing an update

1. On the Windows PC (the only machine with the Android SDK):
   `powershell -ExecutionPolicy Bypass -File tool\release.ps1 -Version 1.2.0 -Build 4`
   (the build number must go up every time). This bumps `pubspec.yaml`, runs
   analyze + tests and builds `dist\WalkieTalkie.apk`.
2. Copy `dist\WalkieTalkie.apk` and the changed `pubspec.yaml` to the Linux box
   (the PC has no `gh` login), commit, push, then:
   `gh release create v1.2.0 WalkieTalkie.apk --repo Brionwickstrom/walkie-talkie --title "Walkie Talkie 1.2.0" --notes "What changed, in plain words"`
3. Phones pick it up the next time the app starts.

The asset must be an `.apk` (preferably named `WalkieTalkie.apk`) and the tag
must look like `vX.Y.Z`; drafts and pre-releases are ignored by
`releases/latest`.

### Signing (later step)

Release APKs are currently signed with the PC's Android **debug** keystore
(`~/.android/debug.keystore`), so builds from that PC update the installed app
in place. Android only accepts an update signed with the same key, so do not
build releases on another machine or change keys casually. Moving to a
dedicated release keystore (`key.properties` + `.jks`, never committed) is a
planned later step and will require one manual uninstall/reinstall on each
phone.

## v1.8.1: full-screen map, guarded SOS, Offline power save

* **Full-screen map:** the Trip map is bigger by default (60% of the
  screen) and the new full-screen button (top right) opens it edge to edge,
  hiding the panel, app bar and tab bar while keeping clear of the status
  and navigation bars. Recenter, map style, offline maps, pins and zoom
  stay on the map; the exit button or the back gesture leaves full screen.
* **Smaller SOS that is hard to press by accident:** a small red SOS
  button in the map's bottom-left corner (also in full screen). Slide it
  right to arm, then keep holding 3 s while a ring fills; haptics on arm
  and send. A tap only shows "Slide and hold to send SOS"; pocket touches
  do nothing. While an SOS is on, the corner shows "SOS ON" (tap for who
  answered and Cancel); the panel still shows the full SOS card.
* **Offline power save** (Settings > Off-grid, or the leaf chip / switch
  on the Trip tab), for when you know there is no internet: the internet
  relay and friend relay rooms close (no reconnects on network changes),
  LAN subnet sweeps stop, Wi-Fi Direct discovery runs only on "Look for
  nearby phones now", Bluetooth scans in short low-power bursts, hellos /
  mesh beacons every 4 s, friend presence every 7 s, GPS every 90 s in the
  background (15 s on the Trip tab), check-ins doubled (max 15 min), live
  location and map / weather downloads off, and the app turns dark and
  dimmed (no screen-on lock). Push-to-talk, receiving, the phone mesh
  relay, the Meshtastic radio, SOS (full speed and priority) and quick
  messages keep working. Stacks with Battery saver. Rough effect: about
  1.5-2x the standby time of Normal (estimate, varies by phone).

## v1.9.0: ready-made maps (one tap, no files to find)

* **Trip map → file button (Imported trails and maps) → Ready-made maps**, or
  the one-time banner on the Trip map ("Silver Star & Trapper Creek maps are
  ready" → **Add maps**), or Map style → **Ready-made maps**.
* **Silver Star Mountain:** trails (GPX, bundled in the APK) + USGS topo
  offline base map (MBTiles, 24 MB download).
* **Trapper Creek Wilderness:** trails (GPX, bundled) + USGS topo picture
  (7.7 MB), placed on the map automatically from its bounds.
* Files download straight from the GitHub `maps-*` prereleases into the app's
  map storage, every file is SHA-256 checked, progress and size are shown,
  Cancel / retry resumes with only the missing files, added packs show
  **Added** with **Show on map** and **Remove**.
* The list is `map_packs.json` (bundled copy, replaced by the latest from
  `raw.githubusercontent.com/.../main/map_packs.json` and cached), so packs can
  be added without an app update.
* After any import or pack add the map moves to the new layer; the first
  offline MBTiles map becomes the base map automatically.
* Big park map pictures are decoded at most 4096 px a side (memory).
* **Copies already on the phone:** before adding a pack file the app looks
  for the same map already imported by hand (same SHA-256; or GPX of the same
  size / same trails from KML by their extent; MBTiles of the same size or
  name over the same area; a picture with the same name and size). It is
  used instead (marked **Already added**, shown on the map), not copied.
* **Remove duplicate maps:** Map layers (and Ready-made maps) show a card
  when byte-identical layers were imported more than once; one tap keeps one
  of each (the pack copy, else the base map, else a visible one, else the
  oldest) and the base map keeps working. Shared routes are left alone.

## v1.9.1: more map styles, overlays, offline trail navigation

**Map style** (Trip tab, layers button) now lists, each marked *Can be saved
offline (Download area)* or *Online only*:

| Style | Source | Offline | Max zoom |
|---|---|---|---|
| USGS Topo | USGS The National Map (public domain) | yes | 16 |
| Topo (OpenTopoMap) | OpenTopoMap (CC-BY-SA) | yes | 17 |
| USGS Satellite | USGS Imagery Only | yes | 16 |
| USGS Satellite + Topo | USGS Imagery Topo | yes | 16 |
| USGS Hillshade | USGS Shaded Relief | yes | 16 |
| Street (OpenStreetMap) | OpenStreetMap | view only (OSM tile policy forbids bulk download) | 19 |

**Overlays** (tick any number, drawn over the base):

| Overlay | Source | Offline |
|---|---|---|
| Land ownership | BLM Surface Management Agency (BLM/USFS/NPS/state/...) | yes, to z14 |
| Wilderness areas | USFS EDW Wilderness | yes |
| USFS trails | USFS EDW National Forest System trails | yes, z10+ |
| USFS roads | USFS EDW roads | yes, z10+ |
| Slope angle | computed on the phone from AWS Terrain Tiles (Terrarium DEM): yellow 27-30 deg, orange 30-35, red 35-45, purple 45+ | yes, z11-14 |
| Wildfire perimeters | NIFC WFIGS current perimeters (vector) | **online only** |

Download area saves the chosen base plus every offline-capable overlay that
is on, plus the elevation tiles used for slope and elevation profiles.
`LIVE_MAPS=1 flutter test test/live_map_sources_test.dart` checks every URL.

**Navigation** (works offline): long-press anywhere on the map, or tap a
waypoint, trailhead, peak, pin or search result, then **Navigate here**
(shortest path along the trail layers on the phone, ends and crossings
snapped) or **Compass to here** (straight line). The map shows the route
in purple and a card with distance left, Naismith time, climb/descent and a
heading arrow, with **Follow** and **Stop**. **Follow** opens the follow
screen: next junction ("Turn left onto ..."), big arrow, elevation profile
(DEM, else GPX elevations), **Re-route**, **Share route** (sent like any
shared route) and **Stop**. More than 40 m off the route the phone vibrates
and shows an arrow back; far off it re-routes by itself. GPS runs every 2 s
while navigating (5 s with Battery saver, 10 s with Offline power save).
Code: `lib/trip/nav/` (trail_graph, navigator, nav_session), `lib/ui/nav_page.dart`.

## v1.9.2: offline driving directions

Car routing on the phone with no signal, from saved OpenStreetMap roads.

**Get roads** (Trip tab, *Offline roads* map button or the panel button):

- *Ready-made maps* → **Portland to Gifford Pinchot roads** → Add
  (8.9 MB; 40,155 km of road from Portland/Vancouver to Mount St. Helens,
  Trapper Creek, the Gorge and Mount Adams; box 45.40,-122.95 to 46.65,-121.35).
- *Save roads for an area* → drag the corners (or the middle) of the box, or
  *Use current view* → the size is shown first ("About N roads · X on the
  phone (Y to download)") → *Save roads (X)*. Up to 1 x 1 degree per area;
  big areas download in pieces from Overpass (several mirrors are tried).
- Each saved area has a menu: *Show on map*, *Update* (download again /
  newer pack), *Rename*, *Delete*. All saved areas are joined for routing,
  so a route can cross from one area into another.

**Drive**: long-press the map (or tap a waypoint/pin) → *Drive here*, or
*Drive to trailhead, then hike* (picks the best trailhead waypoint within
25 km, drives there, then starts *Navigate here* on the trail by itself).
The drive card shows distance, time and warnings; *Follow* opens the follow
screen (next turn arrow and distance, heading-up map that re-centres,
spoken directions with mute, *Re-route*, *Steps*, *Stop*). Going off route
re-routes by itself. At a trailhead, *Navigate here* continues on foot.

**Roads rules** (from OSM tags): `access`/`motor_vehicle`/`motorcar` no,
private, forestry, agricultural are avoided (destination = only if needed);
`oneway`, roundabouts (exit counting); locked gates / bollards are avoided
(only used, with a warning, when there is no other way); open gates are
warned. Roughness: `4wd_only`, `smoothness=horrible`, `tracktype=grade5` →
*high clearance / 4WD*; `smoothness=bad`, grade3-4, dirt → *rough*; gravel /
grade2 / tracks → *gravel / unpaved*; each slows the estimate and is shown on
the route (dashed / coloured) and in the warnings. Seasonal closures from
`*:conditional = no @ (Nov 15-Apr 30)` are avoided while closed and warned
otherwise. Not modelled: turn restrictions, traffic, live closures.

**Voice**: Android text-to-speech (works offline with the phone's voice
data). Driving: "In half a mile, turn left onto Silverstar Road (FR 4109)",
then at the turn; trail navigation can speak too (*Voice on/off* on the
trail follow screen, off by default). GPS while driving: 1 s, 2 s with
battery saver, 3 s in Offline power save (saving roads is off there).

Pack building: `tool/build_roads.dart` turns an `osmium cat -f opl` extract
(Geofabrik, highway=motorway..track) into the `.wtr` file (gzip, typed
arrays, ~42 bytes a road piece).

## v1.9.3: one offline save, online driving with offline fallback

**Offline areas** (Trip tab: the *Offline areas* map button, or the panel
button; replaces the separate *Offline maps* and *Offline roads*):

- **Save this area offline** → drag the box corners (or the middle), or
  *Use current view* → pick the map styles (any base map or overlay that may
  be saved: Topo, USGS Topo / Satellite / Hybrid / Hillshade, land ownership,
  wilderness, USFS trails / roads, slope) and the detail (zoom range) →
  switches for *Roads for offline driving*, *Trails and places* and
  *Elevation* → the size is shown first (map tiles now, roads after asking
  Overpass) → *Save this area (~X MB)*. Map tiles, elevation, trails and road
  data are saved together as one area; a part that fails is reported and the
  rest is kept.
- Limits: up to 3000 tiles per style; road data up to 1 square degree per
  piece, a bigger box (up to 2° x 2°) is saved as up to 4 road pieces; beyond
  that the map and trails still save and it says roads need a smaller box.
- Duplicate check: a box about the same as a saved area shows *Already
  saved: … Update it*; tiles already on the phone are never downloaded again.
- One list: each area (and each ready-made pack: Silver Star, Trapper Creek,
  Portland to Gifford Pinchot roads) has ⋮ *Show on map*, *Update* (re-check
  tiles, new roads and trails; untick a style or a part to remove it),
  *Rename* (names its roads / trails too) and *Delete* (everything in it).
- Migration: v1.9.1 downloads (one region per style, same name and box) and
  v1.9.2 road areas are grouped into areas the first time (a road area joins
  the map area of the same place). Stored in `offline_areas.json`; tile
  regions and layers carry the area id.

**Driving** (Trip tab: the car **Directions** map button or panel button →
*Search for a place to drive to* / *The middle of the map* / a pin, with
*Drive to the trailhead, then hike*; or long-press the map → *Drive here*;
a search result's sheet also has *Drive here*):

- With signal the route comes from the free OSRM car router on the FOSSGIS
  server (`routing.openstreetmap.de/routed-car`, then
  `router.project-osrm.org`), at most one request a second, with the app's
  User-Agent; 7 s timeout in all, then the on-phone router over the saved
  roads. Also offline when the server fails, says there is no route, or the
  start / destination is more than 3 km from a road it knows.
- Online routes are checked against the saved roads: rough / 4WD stretches,
  seasonal closures, fords, local-only roads and gates are warned the same as
  offline; a route through a locked gate in the saved roads switches to the
  offline route. Where no roads are saved it says gates and road surface
  were not checked.
- The active route is kept on the phone (`drive_active.json`, up to 12 h,
  also across an app restart), so guidance and voice carry on with no
  signal. Off route: re-routed online with signal, else offline from the
  saved roads; with neither it says "Off route. No signal and no saved roads
  here, so I cannot re-route."
- The card, follow screen and steps show *Online route* / *Offline route*.
  Attribution and a *fix the map* link are on the steps sheet. No live
  traffic: times come from road speeds.

Code: `lib/trip/offline_areas.dart`, `lib/trip/drive/online_router.dart`,
`RoadGraph.check` in `road_router.dart`, `lib/ui/offline_areas_page.dart`.
Tests: `test/v193_offline_area_drive_test.dart` (`ONLINE=1` also calls the
real router).

## v1.9.4: private groups hardened, one place for them

Open channels (CH 1-16 without a passcode) work exactly as before. Private
channels get these fixes, and everything stays compatible with older app
versions and older relays (old phones keep working, no new steps):

* **Where private groups live.** Tap the channel name in the top bar
  ("CH 3 ▾"): the picker shows **Private groups** (lock icon, with their
  names) at the top, with **New private group** and **Join with a code or
  QR** right there, and **Open channels** below. Before 1.9.4 there was one
  dropdown CH 1-16 with a small lock on private numbers, and a channel was
  made private with the lock button next to it (that still works).
* **New private group** fills in a strong generated passcode (12 letters
  and digits, no look-alikes), picks a free channel number (CH 16 down),
  makes you admin and opens the invite QR. A passcode you type for a NEW
  channel needs 10+ characters with 5+ different ones (no runs like
  1234567890). Joining a channel and channels already saved keep accepting
  6+ characters. Key stretching (PBKDF2, 120k) is unchanged: a different
  setting would give older phones a different key from the same passcode.
* **Unknown listener.** Relay 1.4.0 sends a room roster (who is connected:
  claimed id, seconds idle, seconds connected) every 5 s, only to sockets
  that ask (`&r=1`; older apps never ask and ignore text anyway). The app
  compares it with the people it hears and shows **Unknown listener (n)** on
  a private group (and a quiet "n more connected without showing up" on
  an open one). Rules (`core/listeners.dart`): connected 8 s+, and either an
  unheard id that is active, a second socket using a heard id, or silent
  for over 60 s (the relay closes dead sockets well before that). Smoothed
  over two rosters. Needs relay 1.4.0; with an older relay nothing shows.
* **Silent sockets in private rooms (relay 1.4.0).** A socket gets a private
  room's frames for its first 10 s, then only while it keeps sending binary
  frames (every app version sends a hello every 1-4 s); 90 s without one
  and it stops receiving until it sends again. Text pings alone do not
  count. Open rooms, friend rooms and the lobby are unchanged.
* **Join alert.** Settings > Privacy (and the lock sheet): "Alert when
  someone joins" a private group (on by default) / an open channel (off).
  A short tone (app on screen) and a note with the name; not for phones
  that were already there, came back within 30 s, or were announced in the
  last 10 min.
* **Real kick.** Every phone now announces a per-app-start X25519 key in
  its hellos (`x.kx`, feature level 21, `core/peer_box.dart`). When the
  admin removes someone, each remaining phone gets the new passcode sealed
  for it alone (`core/rekey.dart`): with the friend pair key if they are
  friends, else to its own key. The removed phone still sees the rekey
  frames (it knows the old passcode) but cannot open the passcode. Members
  accept a sealed rekey only from the admin's own announced key. If two
  different keys claim to be one phone (someone fakes its hellos), nothing
  is sent to it and the admin is told. **Fallback:** phones older than
  1.9.4 only understand the old clear copy, so they get exactly what they
  got before (no worse than today); the admin's note names them, because
  the removed phone could read that copy.
* **Direct link setup.** On private groups it was already sealed with the
  channel key (checked). Now offers/answers are also sealed to the other
  phone's own key when it has one, so a hidden listener on an open channel
  (or a removed member) does not learn addresses or link tokens; older
  phones get the plain message. Offers are only answered for phones whose
  hello we have heard.
* **Bluetooth.** Broadcast audio is only notified on our GATT server after
  some phone has written to it (every app version writes hellos). Android
  cannot notify one subscriber only, so once one real phone is connected,
  every subscriber gets the notifications (private groups are encrypted
  anyway).

Limits: this protects against listening, not against a phone that has the
passcode and actively fakes another phone's hellos (it shows as a key
conflict). The join tone plays only while the app is on screen.

## v1.9.5: LoRa gateway, hold-to-mute, quiet hours

* **LoRa gateway (`gateway/`, `lib/gateway/`, `core/gateway_protocol.dart`).**
  An always-on container on the Synology (`walkie-gateway`) joins the home
  relay's rooms and talks to any number of Meshtastic radios (USB serial,
  or Wi-Fi / Ethernet radios over TCP 4403). Phones on the internet and
  people who only have a radio can now reach each other: rings, chat,
  voice clips, rekeys, Trip messages and the rare presence hello. Never
  live talk. New frame type 8 (gateway envelope, internet only; older apps
  drop it): `fromRadio` (a radio frame brought in), `toRadio` (a phone asks
  gateways to transmit a frame it already decided may use the radio, sealed
  on private groups) and `announce` ("Home gateway", radios up). Dedupe
  and loop prevention by the inner frame's hash across every radio, room
  and gateway; only `toRadio` ever goes on the air, and nothing heard on
  the air goes back on it. Airtime: per-radio token bucket (4, then 1 per
  8 s), priority queue, 12 requests/min per phone, presence once per 4 min
  per phone. Private groups: the gateway only sees ciphertext and joins a
  private room (`p` + tag) for 30 min after LoRa traffic for it is heard.
  Status: `http://<nas>:47481/healthz`.
* **Phones sharing their radio.** A phone with a paired radio and internet
  does the same for its own channel (Settings → Long-range radio → *Share
  my radio with phones on the internet*, on by default), after a short
  random wait so the Home gateway (or another phone) that heard the same
  packet goes first and the phone stays quiet.
* **In the app:** people only a gateway reaches show *via Home gateway
  (LoRa)*; Settings → Long-range radio lists the LoRa gateways on the
  channel. Gateways are not counted as unknown listeners (1.9.4 phones may
  show "1 more connected" until they update).
* **Mute.** *Mute* next to Ring all / Beep on the Talk screen: hold about
  a second (a ring fills up) to mute, a tap alone only says *Hold to mute*.
  Then pick 30 min, 1 h, 2 h or *Until I turn it off* (the default if you
  close the sheet). One tap on *Muted · tap to unmute* (or *Unmute* on the
  banner) turns sound back on.
* **Quiet hours.** Settings → Mute & quiet hours → *Add quiet hours*: from,
  until (overnight works, e.g. 10:00 PM–7:00 AM), days (the nights it
  starts on). Several schedules, each with an on/off switch.
* **While muted or in quiet hours** live talk is not played (kept in
  Missed), rings, beeps, join tones and the voice message notification
  sound stay silent, rings and voice messages are kept. A banner shows
  *Muted until 3:45 PM* / *Quiet hours until 7:00 AM* and so does the
  listening notification. *Let urgent rings through* (on by default): an
  urgent ring or SOS, a second ring from the same person within 2 minutes,
  or someone marked *Always allow rings* (tap the person) still rings.
  Everything is saved across app restarts (`app/quiet.dart`).

Tests: `test/v195_gateway_test.dart`, `test/v195_quiet_test.dart`.

## v1.9.6: tablet layout and the Windows desktop app

* **Tablets (and wide windows):** from 700 dp wide (with at least 560 dp
  of height, or 1000 dp wide) Talk and the Trip map sit side by side: the
  Talk pane (people, rings, recent talk, the big Talk button) keeps a
  phone-like width (40%, 340–460 dp) on the left, the map and Trip panel
  get the rest. No bottom tabs there. The map's full-screen button still
  covers the whole screen. Phones, also in landscape, keep the two tabs.
  Works in both orientations (`isTwoPane` / `TwoPaneHome` in
  `lib/ui/adaptive_layout.dart`).
* **Space bar push-to-talk:** hold Space to talk (tap it when "Tap to
  talk" is on), on desktop and on tablets with a keyboard. Ignored while
  typing and under dialogs / other screens (`PushToTalkKeys`).
* **Windows app** (`windows/`, `WalkieTalkie-Windows.zip` on the release
  next to `WalkieTalkie.apk`): internet relays, direct UDP links, the
  local network (Wi-Fi LAN + mDNS), chat, friends, private groups, voice
  messages, rings, Trip map / offline areas / map packs, driving and trail
  directions with spoken turns (Windows voices), the error log in
  `%APPDATA%\Walkie Talkie\Walkie Talkie\logs`. Audio: mic through
  `record` (Windows Media Foundation), speaker through the Windows waveOut
  API (`lib/audio/pcm_speaker.dart`, flutter_pcm_sound has no Windows
  version), Opus as on phones.
  * **Meshtastic radio:** USB cable (COM port, `lib/lora/win_serial.dart`,
    kernel32 directly) or Wi-Fi (TCP 4403), same stream framing as the
    Synology gateway (`StreamWire`). Settings > Long-range radio: **Find
    USB radio** or **Wi-Fi radio** (type its address). Saved as
    `serial:COM3` / `tcp:host:4403`.
  * **Not on desktop** (`PlatformCaps`): Bluetooth phone links and
    Bluetooth radios, Wi-Fi Direct, camera QR scanning (paste the code or
    invite link instead) and taking photos (pick a file instead), GPS and
    compass (the map has no "you are here"), the background listening
    service and notifications, battery settings, the in-app installer
    (the update check opens the zip download in the browser instead),
    voice messages over the LoRa radio (no Codec 2 library for Windows).
  * Build: `tool\release.ps1` first (version, analyze, tests, APK), then
    `tool\release_windows.ps1` (needs Visual Studio's C++ workload and
    `C:\src\nuget\nuget.exe` for flutter_tts), then on the box
    `gh release upload vX.Y.Z WalkieTalkie-Windows.zip`.
  * The exe is not signed: SmartScreen says "Windows protected your PC"
    the first time (More info > Run anyway), and Windows Firewall asks to
    allow network access (allow it, or phones on the same Wi-Fi cannot
    reach the PC directly; the internet relays work either way).
* The Android updater only ever picks `.apk` assets
  (`ReleaseInfo.fromGitHubJson`), so the zip next to it changes nothing for
  phones; `releases/latest/download/WalkieTalkie.apk` (and is.gd/getwalkie)
  keep working.

## v1.9.7: Meshtastic channels, on/off mute

* **Import a Meshtastic channel** (Settings → Long-range radio →
  *Meshtastic channels* → *Import channel QR or link*, or *Share with
  Meshtastic* in the channel picker). Scan the QR from the Meshtastic app
  (camera on Android) or paste the `https://meshtastic.org/e/#...` link
  (Windows, or Android via *Paste*). Accepted: with or without `www`,
  `/e/`, `/e`, `/d/`, `/channel/e/`, `?add=true`, with or without base64
  padding (`lib/lora/meshtastic_channels.dart`).
  * The preview shows each channel's name, its modem preset and region
    (when the link has them) and the kind of key: *Custom key*, *Default
    public key* or *No encryption*. **The key itself is never shown,
    logged, stored by Walkie Talkie or put in the debug export** (links in
    log lines become `meshtastic.org/e/#[redacted]`). Warnings: a default
    / public key (anyone with a Meshtastic radio can listen) and MQTT
    uplink (the channel may be copied to an internet server).
  * **Add to my radio** writes the channel as a SECONDARY channel in the
    first free slot 1–7 with Meshtastic admin messages (session key from
    get_config, begin_edit, set_channel, commit_edit;
    `lib/lora/meshtastic_admin.dart`), waits for the radio to restart and
    reconnect, then reads the channels back and checks name and hash. The
    primary channel and the LoRa settings are left alone. If the link's
    preset or region differ from the radio's, a warning shows and
    *Advanced → Also apply radio settings* (off by default, asks again)
    changes only preset / bandwidth / spreading / coding rate / frequency
    slot and region. A channel the radio already has (same name and hash)
    is just linked; a secondary channel already on the radio can be linked
    with *Link*.
  * **Link to a Walkie channel:** a new open channel (named after the
    Meshtastic one) or an existing open channel. It shows the mesh badge
    *Shared with Meshtastic · name* and the note "anyone with that
    Meshtastic QR can listen; removing someone needs a new QR". Private
    Walkie channels can not be linked. Links are saved as name + channel
    hash (never a key or slot number) and resolved on whichever radio is
    connected, so a radio with the channel in another slot works and a
    radio without it falls back to its primary channel. Walkie traffic
    stays on PRIVATE_APP (256) on that Meshtastic channel.
  * **Unlink:** ⋮ → *Unlink*, optionally *Also remove it from my radio*.
  * **Gateway 1.1.0:** phones name the linked channel in a new `toRadio`
    envelope (kind 3, followed by the old kind 2 copy for 1.0 gateways,
    which newer gateways drop as a duplicate); every gateway radio
    resolves it to its own slot. `gateway.json` can also map rooms:
    `"meshChannels": {"5": {"name": "Trail", "hash": 98}}`. `/healthz`
    lists each radio's channels (name, hash, key kind; never a key).
  * Same flow on the Windows app over USB / Wi-Fi radios.
* **Mute is on/off.** No more 30 min / 1 h / 2 h: hold *Mute* about a
  second (the ring fills) to mute, it stays muted (also after restarts)
  until you hold *Muted · hold to unmute* (or *Unmute* on the banner)
  about a second. A quick tap only says *Hold to mute* / *Hold to unmute*.
  A timed mute from 1.9.5/1.9.6 that was still running becomes plain
  muted.
* **Quiet hours:** each schedule has its on/off switch, a pencil to edit
  it and a bin to delete it (with Undo).

Tests: `test/v197_meshtastic_import_test.dart` (vectors from the official
apps and the Python library), `test/v195_quiet_test.dart`.

## v2.3.0: Private groups, and a tidier Talk screen

**Private groups are their own thing now.** CH 1 to 16 are open channels only
(anyone on the same number can hear you, nothing is encrypted). A private group
is separate: it has its own random id, a name, a colour and an emoji, and a
secret, and it is not tied to any channel number. The channel number never goes
on the air for a group: frames carry only a 16 bit tag made from the key, so
the relay, the gateway, LoRa and Meshtastic see no channel number for private
traffic (Meshtastic links, which are for open channels only, are untouched).
The key is made from the group id plus the secret (PBKDF2, 120000 rounds, in a
background isolate, once per group; the result is remembered).

On the Channels screen there are two sections: **Private groups** (with **New
private group** and **Join with a code or QR**) above **Open channels**.
**Add people** sends an invitation to the friends you pick, in their Direct
chat with you (kept up to 24 hours if they are out of reach). The group secret
is sealed with the friend pair key, so only that friend can open it; they
choose **Join** or **Decline** and nothing is joined by itself. People who are
not friends can use the QR code or the link. Invites carry the group id and a
note: phones on older versions have to update first. Old links and QR text
(`ch=3&p=...`) still work.

**Moving over.** Every "CH 3 + passcode" group becomes a group named "CH 3
group" (rename it any time), once, and the one you were in stays the one you are
in. Those groups keep the old key derivation (channel number as the salt), so
phones that are still on an older version stay in the same room. The old
settings key is still written for them, so going back to an older app keeps
your groups. Groups made in 2.3.0 are new-style and only 2.3.0+ can join them.

**Talk screen clean-up.** Quiet hours is a small moon chip on the "Who can hear
this?" line (tap it for Change, or the held Unmute while muted) instead of a
big card; the connection icons and the backup line are one line ("Internet via
Wi-Fi · Home relay 42 ms · 1 backup ready", Details has the full text); the
recent-clips row is a History button with a dot while something is unheard;
Ring all, Beep, Hold: message, Mute (still a 2.5 s hold plus a confirm) and
History share one row that wraps; the Talk button shrinks on short screens and
with large text (never below 96 dp); the people list gets the rest. The red
"Media volume is low" banner is now a small amber speaker-low icon on the same
status line (no extra row): tap it to raise the media volume to about half (the
system volume panel opens) and see why. A calm, non-red snackbar reminds you
only when incoming talk starts while the volume is low, at most every 10
minutes (not while muted). On a 360 x
640 phone at 1.3x text the list went from about 44 dp to about 197 dp.

Battery: nothing new runs in the background. A group key is derived once
(then cached, and its tag is saved); there are no new timers, polling or wake
locks.

## v2.2.0: Save route for offline

On a drive, hike, drive then hike (or Gentle compass route), the card has one
button, **Save route for offline**. It shows the size first, then downloads a
strip of map tiles along every leg (wider and lower zoom for the drive, tighter
and higher zoom for the hike), roads and trails in a buffer (unnamed paths
too), elevation tiles for the hike strip, the turn list and trailhead info, as
ONE item in **Offline areas** named after the destination. It has **Cancel**
(partial work is kept) and **Resume**; ⋮ has **Download again** and **Delete**.
When signal drops mid-route, a failed online reroute uses the saved turns,
tiles and trails ("from your saved route"); when signal returns the app goes
back to online routing.

Fair use: tiles are fetched one at a time, about 1 request a second, with the
app's User-Agent, and the map attribution stays on screen. Downloads start only
on tap, never in the background, and stop on Cancel.

Battery (same release): the speaker is released 1.5 s after the last audio and
reopens on incoming audio without clipping the first syllable; idle,
backgrounded friend location sharing uses balanced (network) accuracy every
45 s (120 s with battery saver) and goes back to high accuracy while
navigating, recording, on the Trip screen or in SOS.
