# walkie-gateway (Home gateway)

Bridges the Walkie Talkie internet relay rooms and the Meshtastic LoRa mesh.
Runs on the Synology next to `walkie-relay`.

* Container: `walkie-gateway` (restart unless-stopped, host network, logs
  json-file 2 MB x 3).
* Data / config: `/volume1/docker/walkie-gateway/data/gateway.json`
  (`state.json` keeps the gateway's id).
* Status: `http://192.168.68.64:47481/healthz`.

## Radios

Edit `gateway.json`; changes are picked up within 15 s (no restart):

```json
"radios": [
  {"name": "Home RAK (USB)", "serial": "auto"},
  {"name": "Van radio", "tcp": "192.168.1.50:4403"}
]
```

* `serial`: `auto` (first `/dev/ttyACM*` / `/dev/ttyUSB*`) or a path. Hot
  plug works: the container sees `/dev` and retries every 5 s.
* `tcp`: a Meshtastic radio with Wi-Fi or Ethernet enabled (Meshtastic app →
  Radio config → Network → Wi-Fi on, SSID / password). Port 4403.
* `"enabled": false` turns one off without deleting it.
* Every radio must be on the same primary channel (name + key) as the
  phones' radios.

## Build / deploy

```
tool/gateway_bundle.sh build/gateway_ctx   # on the box
# copy build/gateway_ctx to /volume1/docker/walkie-gateway/build, then:
sudo docker build -t walkie-gateway:latest .
sudo docker run -d --name walkie-gateway --restart unless-stopped \
  --network host -v /volume1/docker/walkie-gateway/data:/data \
  -v /dev:/dev --device-cgroup-rule 'c 166:* rmw' \
  --device-cgroup-rule 'c 188:* rmw' \
  --log-driver json-file --log-opt max-size=2m --log-opt max-file=3 \
  walkie-gateway:latest
```
