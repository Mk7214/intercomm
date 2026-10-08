import 'package:flutter/material.dart';

/// Distinct, high-contrast pin colours. Blue is left out — it's our own dot.
const _peerPalette = <Color>[
  Color(0xFFE53935), // red
  Color(0xFF43A047), // green
  Color(0xFF8E24AA), // purple
  Color(0xFFFB8C00), // orange
  Color(0xFF00897B), // teal
  Color(0xFFD81B60), // pink
  Color(0xFF6D4C41), // brown
  Color(0xFF3949AB), // indigo
  Color(0xFFC0CA33), // lime
  Color(0xFF00ACC1), // cyan
];

/// Stable colour per device. Uses FNV-1a rather than String.hashCode, which
/// isn't guaranteed to match across runs — this way a friend has the same
/// colour on every phone in the mesh.
Color peerColor(String deviceId) {
  var hash = 0x811c9dc5;
  for (final unit in deviceId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return _peerPalette[hash % _peerPalette.length];
}
