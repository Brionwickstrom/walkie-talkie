#!/bin/sh
# Build libcodec2.so for the host (Linux box) so tests can run the real
# codec: test/lora_codec2_test.dart skips when it is missing.
set -e
cd "$(dirname "$0")/.."
C2=android/app/src/main/cpp/codec2
mkdir -p build/host
cc -O2 -fPIC -shared -w -I$C2 -o build/host/libcodec2.so $C2/*.c -lm
echo build/host/libcodec2.so
