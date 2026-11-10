#!/bin/sh
# Deploy the private Mosquitto broker and the mesh logger on the Synology.
# Run from the repo, with sudo:
#   sudo mqtt/deploy.sh
# Optional: MQTT_USERS="phone skunk-ape van" MQTT_TOPIC_ROOT=msh/stalkie
#
# Creates passwords on the NAS. Does not print them. Does not commit them.
set -eu
cd "$(dirname "$0")/.."

ROOT=${MQTT_ROOT_DIR:-/volume1/docker/walkie-mqtt}
TOPIC=${MQTT_TOPIC_ROOT:-msh/stalkie}
# shellcheck disable=SC2086
USERS=${MQTT_USERS:-phone skunk-ape van}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo mqtt/deploy.sh" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed." >&2
  exit 1
fi

umask 077
mkdir -p "$ROOT/data" "$ROOT/secrets" "$ROOT/log"
chmod 700 "$ROOT/secrets"
cp mqtt/mosquitto.conf "$ROOT/mosquitto.conf"

if [ -f "$ROOT/secrets/passwd" ]; then
  echo "Keeping existing credentials in $ROOT/secrets"
else
  echo "Creating credentials in $ROOT/secrets (not printed)."
  : > "$ROOT/secrets/CREDENTIALS.txt"
  chmod 600 "$ROOT/secrets/CREDENTIALS.txt"
  printf 'topic_root=%s\nbroker_funnel=walkie-relay.tail1700cf.ts.net:8443\ntls=on\nlan=192.168.68.64:1883\n' \
    "$TOPIC" >> "$ROOT/secrets/CREDENTIALS.txt"
  : > "$ROOT/secrets/acl"
  first=1
  for u in $USERS logger; do
    p=$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24)
    flag=
    if [ "$first" -eq 1 ]; then
      flag=-c
      first=0
    fi
    # shellcheck disable=SC2086
    printf '%s\n%s\n' "$p" "$p" | docker run --rm -i --entrypoint mosquitto_passwd \
      -v "$ROOT/secrets:/sec" eclipse-mosquitto:2 \
      $flag /sec/passwd "$u"
    if [ "$u" = "logger" ]; then
      printf '%s\n' "$u" > "$ROOT/secrets/logger.user"
      printf '%s\n' "$p" > "$ROOT/secrets/logger.pass"
      printf 'user %s\ntopic read %s/#\n\n' "$u" "$TOPIC" >> "$ROOT/secrets/acl"
    else
      printf 'user %s\npassword %s\n\n' "$u" "$p" >> "$ROOT/secrets/CREDENTIALS.txt"
      printf 'user %s\ntopic readwrite %s/#\n\n' "$u" "$TOPIC" >> "$ROOT/secrets/acl"
    fi
  done
  chmod 600 "$ROOT/secrets/passwd" "$ROOT/secrets/logger.pass" \
    "$ROOT/secrets/CREDENTIALS.txt" "$ROOT/secrets/acl"
fi

if [ ! -f "$ROOT/secrets/logger.env" ]; then
  cat > "$ROOT/secrets/logger.env" << EOF
MQTT_HOST=127.0.0.1
MQTT_PORT=1883
MQTT_USER_FILE=/secrets/logger.user
MQTT_PASS_FILE=/secrets/logger.pass
MQTT_ROOT=$TOPIC
LOG_DIR=/data
EOF
  chmod 600 "$ROOT/secrets/logger.env"
fi

tool/mqtt_bundle.sh build/mqtt_log_ctx
docker build -t walkie-mqtt-log:latest build/mqtt_log_ctx

if docker compose version >/dev/null 2>&1; then
  docker compose -f mqtt/docker-compose.yml up -d
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f mqtt/docker-compose.yml up -d
else
  echo "docker compose is not available." >&2
  exit 1
fi

echo
echo "Broker is on port 1883 (password required, no anonymous access)."
echo "Logger writes /volume1/docker/walkie-mqtt/log/nodes.json and range.jsonl."
echo "Credentials (mode 600, do not commit): $ROOT/secrets/CREDENTIALS.txt"
echo
echo "Outside path (Starlink CGNAT): Tailscale Funnel on 8443. The relay stays on 443."
echo "  sudo tailscale funnel --bg --tcp=8443 tcp://127.0.0.1:1883"
echo "  sudo tailscale funnel status"
echo "Radios and the app then use walkie-relay.tail1700cf.ts.net:8443 with TLS on."
echo "A radio on the home Wi-Fi can instead use 192.168.68.64:1883 with TLS off."
echo "Do not open 1883 on the router."
