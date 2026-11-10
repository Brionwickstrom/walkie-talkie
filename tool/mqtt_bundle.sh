#!/bin/sh
# Build context for walkie-mqtt-log: the logger plus the pure-Dart
# Meshtastic decoder it shares with the app. No passwords, no channel keys.
set -e
cd "$(dirname "$0")/.."
out=${1:-build/mqtt_log_ctx}
rm -rf "$out"
mkdir -p "$out/lib/mqtt" "$out/lib/lora" "$out/lib/app" "$out/bin"
cp mqtt/log/pubspec.yaml mqtt/log/Dockerfile "$out/"
cp mqtt/log/bin/main.dart "$out/bin/"
cp lib/mqtt/mesh_log.dart lib/mqtt/mqtt_client.dart lib/mqtt/mqtt_logger.dart \
  "$out/lib/mqtt/"
cp lib/lora/protobuf.dart lib/lora/meshtastic_proto.dart "$out/lib/lora/"
cp lib/app/debug_log.dart "$out/lib/app/"
echo "$out"
