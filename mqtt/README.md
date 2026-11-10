# Private MQTT broker (Synology)

Meshtastic radios bridge channel-encrypted mesh traffic through Mosquitto
on the DS224+ (`192.168.68.64`). The app's phone relay stays on port
**47480**. The LoRa gateway stays on **47481**. This broker is **1883**.
The public Meshtastic broker is not used.

Anonymous clients are refused. Passwords are created on the NAS by the
deploy script and are not in git.

## How a radio reaches it

Starlink CGNAT blocks inbound connections. The relay is already public as
`wss://walkie-relay.tail1700cf.ts.net/ws` through Tailscale Funnel on
**443**. The broker uses Funnel's other port:

| Path | Address the radio uses | TLS | Who can open it |
|---|---|---|---|
| Funnel (chosen) | `walkie-relay.tail1700cf.ts.net:8443` | On (Funnel's certificate) | Any radio with internet |
| Home LAN | `192.168.68.64:1883` | Off | Devices on the home Wi-Fi |

Funnel terminates TLS and forwards plaintext MQTT to `127.0.0.1:1883`.
Mosquitto still requires a username and password. Do not forward 1883 on
the router: off the LAN that would send the password in the clear, and
CGNAT would not accept the connection anyway.

`tailscale serve` (tailnet only, no Funnel) is the more private option. It
was not chosen because a van radio that is not logged into Tailscale could
not reach the house. That matches the relay, which is also on Funnel so
phones off the tailnet can use it.

## Deploy

On the NAS, from a checkout of this repo, as a user who can run Docker:

```
sudo mqtt/deploy.sh
sudo tailscale funnel --bg --tcp=8443 tcp://127.0.0.1:1883
sudo tailscale funnel status
```

What the script does:

1. Creates `/volume1/docker/walkie-mqtt/{data,secrets,log}`.
2. Generates a password per device (`phone`, `skunk-ape`, `van`) plus
   `logger`, unless `secrets/passwd` already exists (a second run keeps
   the passwords). Override the names with `MQTT_USERS="phone van"`.
3. Writes `secrets/CREDENTIALS.txt` mode 600. It does not print the
   passwords. Do not commit that file.
4. Builds `walkie-mqtt-log` and starts both containers with
   `restart: unless-stopped` and host networking, the same pattern as
   `walkie-gateway`.

Then, in the app: **Settings > MQTT bridge**. Use the Funnel address, the
username from `CREDENTIALS.txt`, the password from that file, topic root
`msh/stalkie`, turn the switch on, Check now, then **Configure this radio
for my broker** and confirm the preview.

`logger.env` points the logger at `127.0.0.1:1883` with the logger
password file. It subscribes only. It does not decrypt.

## Logs

| File | What it is |
|---|---|
| `/volume1/docker/walkie-mqtt/log/nodes.json` | One row per node: id, last heard, SNR, RSSI, hops, gateway, channel name, packet count |
| `/volume1/docker/walkie-mqtt/log/range.jsonl` | One signal sample per bridged packet that had SNR or RSSI. Rotates at 2 MB |
| `/volume1/docker/walkie-mqtt/log/status.json` | Connected or not, counts, time of the last packet |

Positions are inside the channel-encrypted payload, so they are not
written. A JSON publish (encryption off) is counted under `ignored` and
the body is dropped. Container logs are json-file, 2 MB times 3.

```
sudo docker logs walkie-mqtt
sudo docker logs walkie-mqtt-log
```

## Not run here

This repo cannot reach the NAS. The script, the Funnel command, a real
radio write, and a live broker sign-in from a Meshtastic node are for
someone on the home network. Unit tests cover the bytes that would be
written, the confirm step, and redaction.
