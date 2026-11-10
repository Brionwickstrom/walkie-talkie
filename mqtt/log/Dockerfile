# Mesh logger. Build context: the folder made by tool/mqtt_bundle.sh.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/main.dart -o /app/mqtt_log

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/mqtt_log /app/mqtt_log
ENV LOG_DIR=/data
CMD ["/app/mqtt_log"]
