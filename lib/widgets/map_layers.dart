import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../i18n.dart';
import '../theme.dart';

/// What the map is drawn on.
///
/// Streets are easier to follow along a road; satellite is easier to recognise
/// standing in one. A passenger describing where they are wants the second — a
/// roof, a yard, the shape of a junction — which is why it is offered on both
/// sides rather than treated as a driver's tool.
enum Basemap { streets, satellite }

/// The tiles for a basemap, with the attribution each one requires.
TileLayer basemapTiles(Basemap map) {
  switch (map) {
    case Basemap.satellite:
      return TileLayer(
        urlTemplate:
            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        userAgentPackageName: 'rw.mpahmapu.motari',
        // Esri's imagery stops short of the deepest street zooms; without this
        // the map goes blank instead of showing a stretched last tile.
        maxNativeZoom: 19,
      );
    case Basemap.streets:
      return TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'rw.mpahmapu.motari',
      );
  }
}

/// Whose imagery this is. Both sources ask to be named, and naming them is the
/// condition of using them for free.
String basemapCredit(Basemap map) =>
    map == Basemap.satellite ? 'Esri, Maxar, Earthstar Geographics' : 'OpenStreetMap';

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
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          basemapCredit(map),
          style: const TextStyle(color: Brand.dim, fontSize: 8.5),
        ),
      );
}
