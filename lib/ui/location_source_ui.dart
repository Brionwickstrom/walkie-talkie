// v2.6.7: the "Location source" setting (Settings > Long-range radio):
// Auto / Phone GPS only / Radio GPS only, which one is in use now and why.
import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../trip/location_source.dart';
import 'friendly_error.dart';

/// Short labels for the three-way switch.
String locationSourceShort(LocationSource s) => switch (s) {
  LocationSource.auto => 'Auto',
  LocationSource.phone => 'Phone GPS',
  LocationSource.radio => 'Radio GPS',
};

IconData locationIcon(ActiveLocation a) => switch (a) {
  ActiveLocation.radio => Icons.satellite_alt,
  ActiveLocation.phone => Icons.phone_android,
  ActiveLocation.none => Icons.gps_off,
};

/// The setting with the source in use under it.
class LocationSourceSection extends StatelessWidget {
  const LocationSourceSection({
    super.key,
    required this.choice,
    required this.onChanged,
    this.onFix,
  });

  /// Null when the Trip part of the app is not running.
  final LocationChoice? choice;
  final ValueChanged<LocationSource>? onChanged;
  final void Function(FixAction)? onFix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ch = choice;
    final setting = ch?.setting ?? LocationSource.auto;
    final err = ch == null ? null : radioGpsError(ch);
    return Column(
      key: const Key('location-source'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(locationIcon(ch?.active ?? ActiveLocation.phone)),
          title: const Text('Location source'),
          subtitle: Text(
            ch == null
                ? setting.about
                : ch.title.replaceFirst('Location: ', 'In use: '),
            key: const Key('location-source-now'),
          ),
        ),
        SegmentedButton<LocationSource>(
          key: const Key('location-source-picker'),
          showSelectedIcon: false,
          segments: [
            for (final s in LocationSource.values)
              ButtonSegment(
                value: s,
                label: Text(
                  locationSourceShort(s),
                  key: Key('location-source-${s.id}'),
                ),
              ),
          ],
          selected: {setting},
          onSelectionChanged: onChanged == null || ch == null
              ? null
              : (v) => onChanged!(v.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            setting.about,
            key: const Key('location-source-about'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (setting != LocationSource.phone)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              "Battery: while the radio's GPS is used, the phone's GPS is "
              "off. Navigation, Drive, SOS, a recorded trail and range "
              "logging still turn the phone's GPS on in Auto.",
              key: const Key('location-source-battery'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (err != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FriendlyErrorView(
              key: const Key('location-source-error'),
              error: err,
              color: setting == LocationSource.radio
                  ? null
                  : theme.colorScheme.onSurfaceVariant,
              onFix: onFix ?? (_) {},
            ),
          ),
      ],
    );
  }
}

/// [LocationSourceSection] for the app.
class LocationSourceSetting extends StatelessWidget {
  const LocationSourceSetting({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return LocationSourceSection(
      choice: c.locationChoice,
      onChanged: (v) => c.setLocationSource(v),
      onFix: (a) => runFix(context, c, a),
    );
  }
}
