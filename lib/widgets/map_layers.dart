import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';

/// What the map is drawn on.
enum Basemap { streets, satellite }

/// Which map provider the Admin has chosen globally for all users.
enum MapProvider { google, osm }

/// Global reactive map provider controlled by Admin settings ('google' or 'osm').
final ValueNotifier<MapProvider> activeMapProvider =
    ValueNotifier<MapProvider>(MapProvider.google);

void setMapProviderFromConfig(String? raw) {
  if (raw == null || raw.trim().isEmpty) return;
  final v = raw.trim().toLowerCase();
  final next = (v == 'osm' || v == 'openstreetmap') ? MapProvider.osm : MapProvider.google;
  if (activeMapProvider.value != next) {
    activeMapProvider.value = next;
  }
}

Future<void> syncMapProviderFromBackend() async {
  try {
    final res = await http
        .get(Uri.parse('${Api.baseUrl}/api/config/maps'))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] is Map<String, dynamic>
          ? body['data'] as Map<String, dynamic>
          : body;
      setMapProviderFromConfig(data['provider']?.toString());
    }
  } catch (_) {}
}

/// High-contrast monochrome (white & black only) color filter for street map tiles.
const ColorFilter _bwStreetsFilter = ColorFilter.matrix(<double>[
  0.34, 0.67, 0.14, 0, -18,
  0.34, 0.67, 0.14, 0, -18,
  0.34, 0.67, 0.14, 0, -18,
  0,    0,    0,    1,   0,
]);

/// The tiles for a basemap, honoring the Admin's global choice between Google Maps and OpenStreetMap.
/// Streets mode is rendered in crisp white and black only.
Widget basemapTiles(Basemap map) {
  return ValueListenableBuilder<MapProvider>(
    valueListenable: activeMapProvider,
    builder: (context, provider, _) {
      if (provider == MapProvider.google) {
        final lyrs = map == Basemap.satellite ? 'y' : 'm';
        final tileLayer = TileLayer(
          key: ValueKey('google_$lyrs'),
          urlTemplate: 'https://mt1.google.com/vt/lyrs=$lyrs&x={x}&y={y}&z={z}',
          userAgentPackageName: 'rw.mpahmapu.motari',
          maxNativeZoom: 21,
        );
        if (map == Basemap.streets) {
          return ColorFiltered(
            colorFilter: _bwStreetsFilter,
            child: tileLayer,
          );
        }
        return tileLayer;
      }

      switch (map) {
        case Basemap.satellite:
          return TileLayer(
            key: const ValueKey('osm_satellite'),
            urlTemplate:
                'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'rw.mpahmapu.motari',
            maxNativeZoom: 19,
          );
        case Basemap.streets:
          return ColorFiltered(
            colorFilter: _bwStreetsFilter,
            child: TileLayer(
              key: const ValueKey('osm_streets'),
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'rw.mpahmapu.motari',
              maxNativeZoom: 19,
            ),
          );
      }
    },
  );
}

/// Whose imagery this is.
String basemapCredit(Basemap map, [MapProvider? provider]) {
  final p = provider ?? activeMapProvider.value;
  if (p == MapProvider.google) {
    return map == Basemap.satellite ? 'Google Maps Satellite' : 'Google Maps';
  }
  return map == Basemap.satellite ? 'Esri, Maxar, Earthstar Geographics' : 'OpenStreetMap';
}

/// The button that swaps between them.
class BasemapButton extends StatelessWidget {
  final Basemap value;
  final ValueChanged<Basemap> onChanged;

  const BasemapButton({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final satellite = value == Basemap.satellite;
    return GestureDetector(
      onTap: () => onChanged(satellite ? Basemap.streets : Basemap.satellite),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: satellite ? Brand.orange : Brand.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(satellite ? Icons.satellite_alt : Icons.map_outlined,
                size: 12, color: satellite ? Brand.orange : Brand.muted),
            const SizedBox(width: 5),
            Text(
              satellite ? t('map.satellite') : t('map.streets'),
              style: TextStyle(
                color: satellite ? Brand.text : Brand.muted,
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The credit line, small and out of the way, but always there.
class MapCredit extends StatelessWidget {
  final Basemap map;
  const MapCredit({super.key, required this.map});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<MapProvider>(
        valueListenable: activeMapProvider,
        builder: (context, provider, _) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Brand.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            basemapCredit(map, provider),
            style: const TextStyle(color: Brand.dim, fontSize: 8.5),
          ),
        ),
      );
}
