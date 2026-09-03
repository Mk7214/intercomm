import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nearby_connections/nearby_connections.dart';
import '../services/nearby_service.dart';
import 'identity_provider.dart';
import '../models/location_update.dart';
import '../models/membership_record.dart';

final meshProvider = StateNotifierProvider<MeshNotifier, MeshState>((ref) {
  return MeshNotifier(ref);
});

class MeshState {
  final bool isAdvertising;
  final bool isDiscovering;
  final List<String> connectedEndpoints;
  final List<String> messages;
  final Map<String, LocationUpdate> peerLocations;
  final Map<String, MembershipRecord> membershipRecords;

  MeshState({
    this.isAdvertising = false,
    this.isDiscovering = false,
    this.connectedEndpoints = const [],
    this.messages = const [],
    this.peerLocations = const {},
    this.membershipRecords = const {},
  });

  MeshState copyWith({
    bool? isAdvertising,
    bool? isDiscovering,
    List<String>? connectedEndpoints,
    List<String>? messages,
    Map<String, LocationUpdate>? peerLocations,
    Map<String, MembershipRecord>? membershipRecords,
  }) {
    return MeshState(
      isAdvertising: isAdvertising ?? this.isAdvertising,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      connectedEndpoints: connectedEndpoints ?? this.connectedEndpoints,
      messages: messages ?? this.messages,
      peerLocations: peerLocations ?? this.peerLocations,
      membershipRecords: membershipRecords ?? this.membershipRecords,
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
      },
      onDisconnected: (id) {
        debugPrint('Disconnected: $id');
        state = state.copyWith(
          connectedEndpoints: state.connectedEndpoints.where((e) => e != id).toList()
        );
      },
      onPayloadReceived: (id, payload) {
        if (payload.type == PayloadType.BYTES) {
          final messageStr = utf8.decode(payload.bytes!);
          try {
            final json = jsonDecode(messageStr);
            if (json['type'] == 'location_update') {
              _handleLocationUpdate(LocationUpdate.fromJson(json), id);
            } else if (json['type'] == 'membership_gossip') {
              _handleMembershipGossip(MembershipRecord.fromJson(json['record']), id);
            } else {
              _handlePlainMessage(id, messageStr);
            }
          } catch (e) {
             _handlePlainMessage(id, messageStr);
          }
        }
      },
    );
  }

  void _handlePlainMessage(String id, String text) {
    state = state.copyWith(messages: [...state.messages, '$id: $text']);
  }

  void _handleLocationUpdate(LocationUpdate update, String senderId) {
    final existing = state.peerLocations[update.deviceId];
    if (existing != null && existing.timestamp.isAfter(update.timestamp)) {
      return; 
    }

    final newLocations = Map<String, LocationUpdate>.from(state.peerLocations);
    newLocations[update.deviceId] = update;
    state = state.copyWith(peerLocations: newLocations);

    if (update.ttl > 0) {
      final relayedUpdate = update.copyWith(
        ttl: update.ttl - 1,
        hopCount: update.hopCount + 1,
      );
      _broadcastJson(relayedUpdate.toJson(), excludeId: senderId);
    }
  }

  void _handleMembershipGossip(MembershipRecord record, String senderId) {
    if (state.membershipRecords.containsKey(record.deviceId)) return;

    final newRecords = Map<String, MembershipRecord>.from(state.membershipRecords);
    newRecords[record.deviceId] = record;
    state = state.copyWith(membershipRecords: newRecords);

    // Relay to others
    _broadcastJson({
      'type': 'membership_gossip',
      'record': record.toJson(),
    }, excludeId: senderId);
  }

  void broadcastNewMembership(MembershipRecord record) {
    final newRecords = Map<String, MembershipRecord>.from(state.membershipRecords);
    newRecords[record.deviceId] = record;
    state = state.copyWith(membershipRecords: newRecords);

    _broadcastJson({
      'type': 'membership_gossip',
      'record': record.toJson(),
    });
  }

  void _broadcastJson(Map<String, dynamic> jsonMap, {String? excludeId}) {
    if (_nearbyService == null) return;
    final jsonStr = jsonEncode(jsonMap);
    
    for (var endpointId in state.connectedEndpoints) {
      if (endpointId != excludeId) {
        _nearbyService!.sendTestMessage(endpointId, jsonStr);
      }
    }
  }


  Future<void> broadcastMyLocation(double lat, double lng) async {
    final identity = await ref.read(identityProvider.future);
    final update = LocationUpdate(
      deviceId: identity.deviceId,
      lat: lat,
      lng: lng,
      timestamp: DateTime.now(),
      ttl: 3, // start with 3 hops
      hopCount: 0,
    );
    _broadcastJson(update.toJson());
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
      peerLocations: {},
    );
  }
  
  void sendTestMessage(String text) {
    _broadcastJson({'type': 'ping', 'message': text});
  }
}

