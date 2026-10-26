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
play all missed, swipe to delete, mark all heard, clear. Private channels
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

### Friends and private 1:1 talk
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
  has a private chat. Unread counts show as badges.
* Text, **photos** (gallery or camera, recompressed to <= 150 KB; over
  Bluetooth only a ~160 px preview is sent and marked as such) and
  **location**: one pin, or *live* for 15/30/60 min (updates every 30 s; tap
  a pin to open Google Maps).
* Chats use the voice-message machinery: chunked, acknowledged, retried and
  stored for up to 24 h for phones not in reach. "waiting" / "delivered"
  shows under your messages.

### Channel names, mute, block, admin
* Tap the lock: give the channel a **name and emoji**; it is shared with
  everyone on the channel via presence (newest wins; on private channels
  only the admin's name is accepted).
* Long-press a person: **Mute** (their live talk is not played here) or
  **Block** (nothing from them at all: talk, rings, messages, chats, friend
  traffic). Unblock in Settings > Blocked.
* Private channels have an **admin**: tick *I'm setting up this channel* when
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
* Each friend uses one extra relay connection (first relay in the list only);
  many friends = more sockets and battery.
* Admin is trust-on-first-use: the first phone that claims admin on a
  private channel is accepted by the others. Anyone who knows the passcode
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
* Private talk to a friend is not saved in the replay history.
* 1.4 and older phones do not see chats, names, friends or moderation.

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
