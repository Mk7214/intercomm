import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nearby_connections/nearby_connections.dart';
import '../services/nearby_service.dart';
import 'identity_provider.dart';

final meshProvider = StateNotifierProvider<MeshNotifier, MeshState>((ref) {
  return MeshNotifier(ref);
});

class MeshState {
  final bool isAdvertising;
  final bool isDiscovering;
  final List<String> connectedEndpoints;
  final List<String> messages;

  MeshState({
    this.isAdvertising = false,
    this.isDiscovering = false,
    this.connectedEndpoints = const [],
    this.messages = const [],
  });

  MeshState copyWith({
    bool? isAdvertising,
    bool? isDiscovering,
    List<String>? connectedEndpoints,
    List<String>? messages,
  }) {
    return MeshState(
      isAdvertising: isAdvertising ?? this.isAdvertising,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      connectedEndpoints: connectedEndpoints ?? this.connectedEndpoints,
      messages: messages ?? this.messages,
    );
  }
}

class MeshNotifier extends StateNotifier<MeshState> {
  final Ref ref;
  NearbyService? _nearbyService;

  MeshNotifier(this.ref) : super(MeshState());

  Future<void> initMesh(String serviceId) async {
    final identity = await ref.read(identityProvider.future);
    
    _nearbyService = NearbyService(
      serviceId: serviceId, // E.g., 'nearby-connections-mesh'
      deviceName: identity.deviceId.substring(0, 8), // Short name
      onEndpointDiscovered: (id, name) {
        debugPrint('Discovered endpoint: $id, $name');
        _nearbyService?.requestConnection(id);
      },
      onEndpointLost: (id) {
        debugPrint('Lost endpoint: $id');
      },
      onConnectionInitiated: (id, info) async {
        debugPrint('Connection initiated: $id');
        // Auto-accept connection for prototype
        await _nearbyService?.acceptConnection(id);
      },
      onConnectionResult: (id) {
        debugPrint('Connection successful: $id');
        state = state.copyWith(
          connectedEndpoints: [...state.connectedEndpoints, id]
        );
        // Send a test message on connect
        _nearbyService?.sendTestMessage(id, 'Hello from ${identity.deviceId.substring(0, 8)}!');
      },
      onDisconnected: (id) {
        debugPrint('Disconnected: $id');
        state = state.copyWith(
          connectedEndpoints: state.connectedEndpoints.where((e) => e != id).toList()
        );
      },
      onPayloadReceived: (id, payload) {
        if (payload.type == PayloadType.BYTES) {
          final message = utf8.decode(payload.bytes!);
          debugPrint('Received message from $id: $message');
          state = state.copyWith(
            messages: [...state.messages, '$id: $message']
          );
        }
      },
    );
  }

  Future<void> startMesh() async {
    if (_nearbyService == null) return;
    
    await _nearbyService!.startAdvertising();
    await _nearbyService!.startDiscovery();
    
    state = state.copyWith(
      isAdvertising: true,
      isDiscovering: true,
    );
  }

  Future<void> stopMesh() async {
    await _nearbyService?.stopAll();
    state = state.copyWith(
      isAdvertising: false,
      isDiscovering: false,
      connectedEndpoints: [],
    );
  }
  
  void sendTestMessage(String text) {
    if (_nearbyService == null) return;
    for (var endpointId in state.connectedEndpoints) {
      _nearbyService!.sendTestMessage(endpointId, text);
    }
  }
}
