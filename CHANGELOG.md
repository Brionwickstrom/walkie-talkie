# Changelog

## 2.6.15+75

MQTT bridge through a private Mosquitto broker on the Synology. Settings
for the broker, a confirm-before-write action for a connected radio, and
a logger container for the node log and signal samples. Channel encryption
stays on. The public Meshtastic broker is not used. The broker password
is sealed in the app's private folder, not stored in SharedPreferences.

Deploy steps and ports: `mqtt/README.md` and the README section
"v2.6.15: MQTT bridge".

## Older versions

Notes for 2.6.14 and earlier are the version sections in `README.md`.
