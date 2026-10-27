#!/bin/sh
# Make the gateway's Docker build context: gateway/ + the pure-Dart app
# files it shares (frame format, gateway protocol, Meshtastic client).
set -e
cd "$(dirname "$0")/.."
out=${1:-build/gateway_ctx}
rm -rf "$out"
mkdir -p "$out/lib/core" "$out/lib/lora" "$out/lib/gateway"
cp gateway/pubspec.yaml gateway/Dockerfile "$out/"
cp -r gateway/bin "$out/"
for f in frame transport mesh lobby gateway_protocol; do cp lib/core/$f.dart "$out/lib/core/"; done
for f in meshtastic_proto protobuf meshtastic_session lora_transport; do cp lib/lora/$f.dart "$out/lib/lora/"; done
cp lib/gateway/*.dart "$out/lib/gateway/"
echo "$out"
