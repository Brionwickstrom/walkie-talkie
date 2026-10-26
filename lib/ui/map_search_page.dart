import 'package:flutter/material.dart';

import '../trip/geo.dart';
import '../trip/search/map_search.dart';
import '../trip/search/nominatim.dart';
import '../trip/search/offline_search.dart';
import '../trip/search/rate_limiter.dart';
import '../trip/trip_controller.dart';

/// What the user picked in [MapSearchPage].
sealed class MapSearchPick {
  const MapSearchPick();
}

/// Something already on the phone: center the map on it and highlight it.
class OfflinePick extends MapSearchPick {
  const OfflinePick(this.hit);
  final SearchHit hit;
}

/// A place found online: zoom there and offer trails / topo download.
class PlacePick extends MapSearchPick {
  const PlacePick(this.place);
  final PlaceResult place;
}

/// Icon for a place kind from map search ('peak', 'lake' ...).
IconData placeKindIcon(String kind) => switch (kind) {
  'peak' => Icons.terrain,
  'lake' => Icons.water,
  'trailhead' => Icons.signpost,
  'spring' || 'water' => Icons.water_drop,
  'campsite' => Icons.park,
  'shelter' => Icons.cabin,
  _ => Icons.place,
};

IconData searchKindIcon(SearchDoc d) => switch (d.kind) {
  SearchKind.trail => Icons.route,
  SearchKind.place => placeKindIcon(d.placeKind),
  SearchKind.waypoint => Icons.place,
  SearchKind.pin => Icons.push_pin,
  SearchKind.sharedPin => Icons.push_pin_outlined,
  SearchKind.person => Icons.person,
  SearchKind.track => Icons.timeline,
  SearchKind.area => Icons.map,
};

IconData _placeIcon(PlaceResult p) => switch (p.type) {
  'peak' || 'volcano' || 'mountain_range' || 'ridge' => Icons.terrain,
  'water' || 'lake' || 'reservoir' => Icons.water,
  'protected_area' || 'national_park' || 'nature_reserve' => Icons.forest,
  'trailhead' => Icons.signpost,
  'camp_site' => Icons.park,
  _ => Icons.place,
};

/// Map search (Trip tab): live offline search across everything on the
/// phone as you type, and "Find maps" online (Nominatim) when you press
/// search.
class MapSearchPage extends StatefulWidget {
  const MapSearchPage({super.key, required this.trip, this.near});
  final TripController trip;

  /// Rank closer things first (my position or the map center).
  final GeoPoint? near;

  @override
  State<MapSearchPage> createState() => _MapSearchPageState();
}

class _MapSearchPageState extends State<MapSearchPage> {
  TripController get t => widget.trip;
  final _q = TextEditingController();
  final _deb = Debouncer(const Duration(milliseconds: 150));
  List<SearchHit> _hits = const [];
  OnlineSearchResult? _online;
  String _onlineFor = '';
  bool _searching = false;

  @override
  void dispose() {
    _deb.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _deb(() {
      if (!mounted) return;
      setState(() {
        _hits = t.searchOffline(v, near: widget.near);
        if (NominatimClient.normQuery(v) != _onlineFor) _online = null;
      });
    });
  }

  Future<void> _searchOnline() async {
    final q = _q.text;
    final key = NominatimClient.normQuery(q);
    // Pressing search again for the same words does nothing (the answer is
    // already shown), and only one request runs at a time.
    if (_searching || (key == _onlineFor && _online != null)) return;
    setState(() {
      _searching = true;
      _hits = t.searchOffline(q, near: widget.near);
    });
    final r = await t.findPlaces(q);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _online = r;
      _onlineFor = key;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _q.text.trim();
    final o = _online;
    final imp = t.settings.imperial;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('mapSearchField'),
          controller: _q,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Trails, places, pins, people',
            border: InputBorder.none,
          ),
          onChanged: _changed,
          onSubmitted: (_) => _searchOnline(),
        ),
        actions: [
          if (q.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _q.clear();
                _changed('');
              },
            ),
          IconButton(
            key: const Key('mapSearchOnline'),
            tooltip: 'Find maps online',
            icon: const Icon(Icons.travel_explore),
            onPressed: _searchOnline,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _header(context, 'Find maps online'),
          if (_searching) const LinearProgressIndicator(),
          if (o == null && !_searching)
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: Text(
                q.length < 2
                    ? 'Type a place, like "Trapper Creek Wilderness", then '
                          'press search'
                    : 'Find maps for "$q"',
              ),
              subtitle: const Text(
                'Finds the place, then gets its trails and topo map for '
                'offline use. Needs signal.',
              ),
              onTap: q.length < 2 ? null : _searchOnline,
            ),
          if (o != null && o.status == OnlineStatus.noSignal)
            ListTile(
              key: const Key('mapSearchNoSignal'),
              leading: const Icon(Icons.signal_cellular_off),
              title: Text(o.message),
            ),
          if (o != null && o.status == OnlineStatus.failed)
            ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(o.message),
              trailing: TextButton(
                onPressed: () {
                  setState(() => _online = null);
                  _searchOnline();
                },
                child: const Text('Retry'),
              ),
            ),
          if (o != null && o.status == OnlineStatus.empty)
            ListTile(
              leading: const Icon(Icons.search_off),
              title: Text(o.message),
            ),
          if (o != null && o.status == OnlineStatus.ok) ...[
            for (final p in o.places)
              ListTile(
                leading: Icon(_placeIcon(p)),
                title: Text(p.name),
                subtitle: Text(
                  [
                    if (p.kindLabel.isNotEmpty) p.kindLabel,
                    p.displayName,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, PlacePick(p)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                NominatimClient.attribution,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          const Divider(height: 24),
          _header(context, 'On this phone (works offline)'),
          if (q.isEmpty)
            const ListTile(
              leading: Icon(Icons.offline_pin),
              title: Text(
                'Search your imported trails, peaks, lakes, trailheads, '
                'pins, people, recorded trails and downloaded maps.',
              ),
            )
          else if (_hits.isEmpty)
            ListTile(
              leading: const Icon(Icons.search_off),
              title: Text('Nothing saved on this phone matches "$q".'),
            ),
          for (final h in _hits)
            ListTile(
              key: ValueKey('hit:${h.doc.kind.name}:${h.doc.ref}'),
              leading: Icon(searchKindIcon(h.doc)),
              title: Text(
                h.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  h.doc.kind == SearchKind.place && h.doc.subtitle.isNotEmpty
                      ? h.doc.subtitle
                      : [
                          h.doc.kind.label,
                          if (h.doc.subtitle.isNotEmpty) h.doc.subtitle,
                        ].join(' · '),
                  if (h.doc.lengthM != null && h.doc.lengthM! > 0)
                    formatDistance(h.doc.lengthM!, imperial: imp),
                  if (h.distanceM != null)
                    '${formatDistance(h.distanceM!, imperial: imp)} away',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, OfflinePick(h)),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String s) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(s, style: Theme.of(context).textTheme.titleSmall),
  );
}
