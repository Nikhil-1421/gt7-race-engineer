/// Track & car catalog for the session selectors — the Flutter counterpart of
/// `app/catalog.py`. Loads the same `catalog.json` (bundled as an asset) so the
/// cascading Track/Car pickers work offline, with no server.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

bool _real(String s) => s.isNotEmpty && !s.startsWith('_');

class TrackVenue {
  final String venue;
  final String region;
  final List<String> layouts;
  const TrackVenue(this.venue, this.region, this.layouts);

  factory TrackVenue.fromJson(Map<String, dynamic> j) => TrackVenue(
        (j['venue'] ?? '').toString(),
        (j['region'] ?? '').toString(),
        [for (final l in (j['layouts'] as List? ?? [])) l.toString()]
            .where(_real)
            .toList(),
      );
}

class CarMaker {
  final String country;
  final List<String> cars;
  const CarMaker(this.country, this.cars);

  factory CarMaker.fromJson(Map<String, dynamic> j) => CarMaker(
        (j['country'] ?? '').toString(),
        [for (final c in (j['cars'] as List? ?? [])) c.toString()]
            .where(_real)
            .toList(),
      );
}

class CarCategory {
  final String category;
  final List<CarMaker> manufacturers;
  const CarCategory(this.category, this.manufacturers);

  factory CarCategory.fromJson(Map<String, dynamic> j) => CarCategory(
        (j['category'] ?? '').toString(),
        [
          for (final m in (j['manufacturers'] as List? ?? []))
            CarMaker.fromJson((m as Map).cast<String, dynamic>())
        ].where((m) => m.cars.isNotEmpty && _real(m.country)).toList(),
      );
}

class Catalog {
  final List<TrackVenue> tracks;
  final List<CarCategory> cars;
  const Catalog(this.tracks, this.cars);

  factory Catalog.empty() => const Catalog([], []);

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
        [
          for (final t in (j['tracks'] as List? ?? []))
            TrackVenue.fromJson((t as Map).cast<String, dynamic>())
        ].where((v) => v.layouts.isNotEmpty).toList(),
        [
          for (final c in (j['cars'] as List? ?? []))
            CarCategory.fromJson((c as Map).cast<String, dynamic>())
        ].where((c) => c.manufacturers.isNotEmpty && _real(c.category)).toList(),
      );

  static Future<Catalog> load() async {
    try {
      final raw = await rootBundle.loadString('assets/catalog.json');
      return Catalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return Catalog.empty();
    }
  }

  // -- track cascade --
  List<String> venueNames() => [for (final v in tracks) v.venue];
  List<String> layoutsForVenue(String? venue) => tracks
      .firstWhere((v) => v.venue == venue,
          orElse: () => const TrackVenue('', '', []))
      .layouts;
  String? venueForLayout(String layout) {
    for (final v in tracks) {
      if (v.layouts.contains(layout)) return v.venue;
    }
    return null;
  }

  // -- car cascade --
  List<String> categoryNames() => [for (final c in cars) c.category];
  List<String> countriesForCategory(String? cat) => cars
      .firstWhere((c) => c.category == cat,
          orElse: () => const CarCategory('', []))
      .manufacturers
      .map((m) => m.country)
      .toList();
  List<String> carsFor(String? cat, String? country) {
    final c = cars.firstWhere((c) => c.category == cat,
        orElse: () => const CarCategory('', []));
    return c.manufacturers
        .firstWhere((m) => m.country == country,
            orElse: () => const CarMaker('', []))
        .cars;
  }

  /// (category, country) that contains [car], or (null, null).
  (String?, String?) locateCar(String car) {
    for (final c in cars) {
      for (final m in c.manufacturers) {
        if (m.cars.contains(car)) return (c.category, m.country);
      }
    }
    return (null, null);
  }

  bool get hasTracks => tracks.isNotEmpty;
  bool get hasCars => cars.isNotEmpty;
}
