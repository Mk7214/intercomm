import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:uuid/uuid.dart';

class NearbyService {
  final Strategy strategy = Strategy.P2P_CLUSTER; // Suitable for mesh
  final String serviceId;
  final String deviceName;
  
  // Callbacks
  final Function(String endpointId, String endpointName) onEndpointDiscovered;
  final Function(String endpointId) onEndpointLost;
  final Function(String endpointId, ConnectionInfo info) onConnectionInitiated;
  final Function(String endpointId) onConnectionResult;
  final Function(String endpointId) onDisconnected;
  final Function(String endpointId, Payload payload) onPayloadReceived;

  NearbyService({
    required this.serviceId,
    required this.deviceName,
    required this.onEndpointDiscovered,
    required this.onEndpointLost,
    required this.onConnectionInitiated,
    required this.onConnectionResult,
    required this.onDisconnected,
    required this.onPayloadReceived,
  });

  Future<void> startAdvertising() async {
    try {
      bool a = await Nearby().startAdvertising(
        deviceName,
        strategy,
        onConnectionInitiated: onConnectionInitiated,
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            onConnectionResult(id);
          } else {
            // Error or rejected
          }
        },
        onDisconnected: onDisconnected,
        serviceId: serviceId,
      );
      debugPrint('Advertising started: $a');
    } catch (e) {
      debugPrint('Error advertising: $e');
    }
  }

  Future<void> startDiscovery() async {
    try {
      bool a = await Nearby().startDiscovery(
        deviceName,
        strategy,
        onEndpointFound: (id, name, serviceId) {
          onEndpointDiscovered(id, name);
        },
        onEndpointLost: onEndpointLost,
        serviceId: serviceId,
      );
      debugPrint('Discovery started: $a');
    } catch (e) {
      debugPrint('Error discovering: $e');
    }
  }

  Future<void> stopAll() async {
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
    await Nearby().stopAllEndpoints();
  }

  Future<void> requestConnection(String endpointId) async {
    try {
      await Nearby().requestConnection(
        deviceName,
        endpointId,
        onConnectionInitiated: onConnectionInitiated,
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            onConnectionResult(id);
          }
        },
        onDisconnected: onDisconnected,
      );
    } catch (e) {
      debugPrint('Error requesting connection: $e');
    }
  }

  Future<void> acceptConnection(String endpointId) async {
    try {
      await Nearby().acceptConnection(
        endpointId,
        onPayLoadRecieved: (id, payload) {
          onPayloadReceived(id, payload);
        },
        onPayloadTransferUpdate: (id, payloadTransferUpdate) {},
      );
    } catch (e) {
      debugPrint('Error accepting connection: $e');
    }
  }
  
  Future<void> sendTestMessage(String endpointId, String message) async {
    final payload = Payload.forBytes(utf8.encode(message));
    await Nearby().sendPayload(PayloadType.BYTES, endpointId, payload);
  }
}
