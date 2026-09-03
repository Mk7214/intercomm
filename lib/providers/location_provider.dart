import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'mesh_provider.dart';

final locationProvider = StateNotifierProvider<LocationNotifier, Position?>((ref) {
  return LocationNotifier(ref);
});

class LocationNotifier extends StateNotifier<Position?> {
  final Ref ref;
  StreamSubscription<Position>? _positionStream;

  LocationNotifier(this.ref) : super(null) {
    _init();
  }

  Future<void> _init() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('Location services are disabled.');
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('Location permissions are denied');
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      debugPrint('Location permissions are permanently denied, we cannot request permissions.');
      return;
    } 

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // Update every 5 meters
      ),
    ).listen((Position position) {
      state = position;
      // Broadcast location over mesh if connected
      ref.read(meshProvider.notifier).broadcastMyLocation(position.latitude, position.longitude);
    });
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }
}
