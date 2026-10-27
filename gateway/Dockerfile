# Walkie Talkie LoRa gateway. Build context: the folder made by
# tool/gateway_bundle.sh (pubspec, bin/, lib/ copied from the app).
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/main.dart -o /app/gateway

# stty (coreutils) sets the USB serial port to raw mode.
FROM debian:bookworm-slim
COPY --from=build /app/gateway /app/gateway
ENV GATEWAY_DATA=/data
VOLUME /data
EXPOSE 47481
CMD ["/app/gateway"]
