import '../tile_cache.dart';
import 'fetch.dart';
import 'nominatim.dart';
import 'overpass.dart';

enum OnlineStatus { ok, empty, noSignal, failed }

/// Outcome of an online place search; never throws.
class OnlineSearchResult {
  const OnlineSearchResult(
    this.status, {
    this.places = const [],
    this.message = '',
  });
  final OnlineStatus status;
  final List<PlaceResult> places;
  final String message;
  bool get noSignal => status == OnlineStatus.noSignal;
}

/// The area "Get trails" / "Download topo" use for a place: its outline's
/// box (or the area on screen), capped to [maxTrailAreaKm] a side.
({GeoBounds bounds, bool trimmed}) areaForPlace(
  PlaceResult? p, {
  GeoBounds? visible,
}) {
  final b = p?.bounds ?? visible;
  if (b == null) {
    final c = p!.center;
    return capBounds(GeoBounds(c.lat, c.lng, c.lat, c.lng), center: c);
  }
  return capBounds(b, center: p?.center);
}

/// Online "Find maps" (Nominatim + Overpass) with a graceful no-signal
/// fallback: when the network is off or unreachable the result says so and
/// the caller shows offline results instead.
class MapSearch {
  MapSearch({
    required Fetch fetch,
    required this.canUseNetwork,
    NominatimClient? nominatim,
    OverpassClient? overpass,
  }) : nominatim = nominatim ?? NominatimClient(fetch: fetch),
       overpass = overpass ?? OverpassClient(fetch: fetch);

  final NominatimClient nominatim;
  final OverpassClient overpass;

  /// Null = allowed; otherwise why the network is not used now.
  final String? Function() canUseNetwork;

  Future<OnlineSearchResult> findPlaces(String query) async {
    if (NominatimClient.normQuery(query).length < 2) {
      return const OnlineSearchResult(
        OnlineStatus.empty,
        message: 'Type a place name.',
      );
    }
    final why = canUseNetwork();
    if (why != null) {
      return OnlineSearchResult(OnlineStatus.noSignal, message: why);
    }
    try {
      final r = await nominatim.search(query);
      if (r.isEmpty) {
        return OnlineSearchResult(
          OnlineStatus.empty,
          message: 'No places found for "${query.trim()}".',
        );
      }
      return OnlineSearchResult(OnlineStatus.ok, places: r);
    } on NoSignalException catch (e) {
      return OnlineSearchResult(OnlineStatus.noSignal, message: e.message);
    } on FetchException catch (e) {
      return OnlineSearchResult(OnlineStatus.failed, message: e.message);
    } catch (e) {
      return OnlineSearchResult(
        OnlineStatus.failed,
        message: 'Map search failed: $e',
      );
    }
  }

  /// Trails and places for an area. Throws [NoSignalException] /
  /// [FetchException].
  Future<OverpassResult> trailsFor(
    GeoBounds bounds, {
    int? areaId,
    required String name,
  }) async {
    final why = canUseNetwork();
    if (why != null) throw NoSignalException(why);
    return overpass.trails(bounds, areaId: areaId, name: name);
  }
}
