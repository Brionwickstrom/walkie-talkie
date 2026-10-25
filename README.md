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

## Private channels and the internet relay (v1.3)

**Private channels.** Tap the lock next to the channel picker, type a passcode
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
* Voice messages recorded on a private channel are only sent while on that
  same private channel.

**Relay.** `relay/` is a standalone pure-Dart server (Dockerfile, `PORT` env,
`GET /healthz`, WebSocket on `/ws?ch=<room>&id=<hex>`), deployed on Render via
`render.yaml` (`brion-walkie-relay`). It also runs in Synology Container
Manager unchanged. Limits: 4 KB max message, ~150 msg/s and 64 KB/s per socket,
silent sockets dropped after 3 min, max 64 per room. Private channels use room
`p<tag>`, so the relay only ever sees ciphertext.

The app keeps an ordered list of relays (default
`wss://brion-walkie-relay.onrender.com/ws`; Settings accepts a comma separated
list, empty = default, `off` = none), connects to all of them in parallel, sends
every frame to each connected relay and de-duplicates on receive. Reconnects
with 2 s..60 s backoff, 75 s first-connect timeout (Render cold start), text
`ping` every 25 s.

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
  BLUETOOTH/ADMIN/FINE_LOCATION (<= 11), WAKE_LOCK, FOREGROUND_SERVICE(+MIC,
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
