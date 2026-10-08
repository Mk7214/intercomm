import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Nearby Connections service id shared by every device in the mesh.
/// Also carried in the QR invite payload as `serviceUUID`.
const String kMeshServiceId = 'nearby-connections-mesh';

/// Thin wrapper over the `nearby_connections` plugin.
///
/// Uses P2P_CLUSTER (M-to-N topology), so every device both advertises and
/// discovers and can hold connections to several peers at once — which is
/// what lets B relay between A and C.
///
/// Note: the plugin keeps a single global set of callbacks, so only one
/// NearbyService should be alive at a time.
class NearbyService {
  final Strategy strategy = Strategy.P2P_CLUSTER;
  final String serviceId;

  /// Advertised endpoint name. We use the full deviceId so peers can map
  /// endpointId -> deviceId before any payload is exchanged.
  final String deviceName;

  final void Function(String endpointId, String endpointName) onEndpointFound;
  final void Function(String? endpointId) onEndpointLost;
  final void Function(String endpointId, ConnectionInfo info) onConnectionInitiated;
  final void Function(String endpointId, Status status) onConnectionResult;
  final void Function(String endpointId) onDisconnected;
  final void Function(String endpointId, Payload payload) onPayloadReceived;

  NearbyService({
    required this.serviceId,
    required this.deviceName,
    required this.onEndpointFound,
    required this.onEndpointLost,
    required this.onConnectionInitiated,
    required this.onConnectionResult,
    required this.onDisconnected,
    required this.onPayloadReceived,
  });

  /// Throws a PlatformException on failure (e.g. Bluetooth off, missing permission).
  Future<bool> startAdvertising() {
    return Nearby().startAdvertising(
      deviceName,
      strategy,
      onConnectionInitiated: onConnectionInitiated,
      onConnectionResult: onConnectionResult,
      onDisconnected: onDisconnected,
      serviceId: serviceId,
    );
  }

  /// Throws a PlatformException on failure (e.g. location services off).
  Future<bool> startDiscovery() {
    return Nearby().startDiscovery(
      deviceName,
      strategy,
      onEndpointFound: (id, name, _) => onEndpointFound(id, name),
      onEndpointLost: onEndpointLost,
      serviceId: serviceId,
    );
  }

  /// Stops advertising/discovery and drops every connection.
  /// Safe to call when nothing is running (e.g. to clear state after a hot restart).
  Future<void> stopAll() async {
    for (final stop in [
      Nearby().stopAdvertising,
      Nearby().stopDiscovery,
      Nearby().stopAllEndpoints,
    ]) {
      try {
        await stop();
      } catch (e) {
        debugPrint('Nearby stop error: $e');
      }
    }
  }

  Future<bool> requestConnection(String endpointId) {
    return Nearby().requestConnection(
      deviceName,
      endpointId,
      onConnectionInitiated: onConnectionInitiated,
      onConnectionResult: onConnectionResult,
      onDisconnected: onDisconnected,
    );
  }

  Future<bool> acceptConnection(String endpointId) {
    return Nearby().acceptConnection(
      endpointId,
      onPayLoadRecieved: onPayloadReceived,
    );
  }

  Future<bool> rejectConnection(String endpointId) {
    return Nearby().rejectConnection(endpointId);
  }

  Future<void> disconnect(String endpointId) {
    return Nearby().disconnectFromEndpoint(endpointId);
  }

  Future<void> sendJson(String endpointId, Map<String, dynamic> json) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    return Nearby().sendBytesPayload(endpointId, bytes);
  }
}
