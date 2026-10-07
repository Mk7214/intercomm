import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nearby_connections/nearby_connections.dart';
import '../services/nearby_service.dart';
import 'identity_provider.dart';
import '../models/device_identity.dart';
import '../models/location_update.dart';
import '../models/membership_record.dart';

final meshProvider = NotifierProvider<MeshNotifier, MeshState>(() {
  return MeshNotifier();
});

/// Initial TTL for our own location updates: reaches peers up to 2 relays away.
const int kLocationTtl = 3;

/// How often to retry connecting to discovered-but-unconnected endpoints.
const Duration _reconnectInterval = Duration(seconds: 8);

/// If the peer that "should" initiate hasn't connected within this window,
/// we initiate ourselves (covers asymmetric discovery).
const Duration _initiateFallback = Duration(seconds: 20);

/// Re-broadcast our last position so stationary devices stay visible
/// (the GPS stream only fires on movement).
const Duration _heartbeatInterval = Duration(seconds: 15);

const int _maxLogEntries = 100;

String shortId(String deviceId) =>
    deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;

class MeshState {
  final bool isRunning;

  /// endpointId -> deviceId of directly connected peers.
  final Map<String, String> connectedPeers;
  final int discoveredCount;

  /// deviceId -> newest location update we know of (direct or relayed).
  final Map<String, LocationUpdate> peerLocations;
  final Map<String, MembershipRecord> membershipRecords;

  /// Human-readable debug log, newest last.
  final List<String> log;
  final String? lastError;

  const MeshState({
    this.isRunning = false,
    this.connectedPeers = const {},
    this.discoveredCount = 0,
    this.peerLocations = const {},
    this.membershipRecords = const {},
    this.log = const [],
    this.lastError,
  });

  MeshState copyWith({
    bool? isRunning,
    Map<String, String>? connectedPeers,
    int? discoveredCount,
    Map<String, LocationUpdate>? peerLocations,
    Map<String, MembershipRecord>? membershipRecords,
    List<String>? log,
    String? Function()? lastError,
  }) {
    return MeshState(
      isRunning: isRunning ?? this.isRunning,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      discoveredCount: discoveredCount ?? this.discoveredCount,
      peerLocations: peerLocations ?? this.peerLocations,
      membershipRecords: membershipRecords ?? this.membershipRecords,
      log: log ?? this.log,
      lastError: lastError != null ? lastError() : this.lastError,
    );
  }
}

class MeshNotifier extends Notifier<MeshState> {
  NearbyService? _nearby;
  DeviceIdentity? _identity;

  /// endpointId -> remote deviceId (advertised endpoint name), and when we first saw it.
  final Map<String, String> _discovered = {};
  final Map<String, DateTime> _discoveredAt = {};

  /// Endpoints with a connection request / handshake in flight.
  final Set<String> _pending = {};

  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  LocationUpdate? _myLatest;

  @override
  MeshState build() {
    ref.onDispose(_cancelTimers);
    return const MeshState();
  }

  String get _myId => _identity!.deviceId;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> startMesh() async {
    if (state.isRunning) return;
    _identity ??= await ref.read(identityProvider.future);
    _addSelfRecord();

    _nearby ??= NearbyService(
      serviceId: kMeshServiceId,
      deviceName: _myId,
      onEndpointFound: _onEndpointFound,
      onEndpointLost: _onEndpointLost,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
      onPayloadReceived: _onPayloadReceived,
    );

    // Clear stale native state (e.g. after a hot restart the plugin is still advertising).
    await _nearby!.stopAll();

    try {
      await _nearby!.startAdvertising();
      await _nearby!.startDiscovery();
    } catch (e) {
      _log('Failed to start mesh: $e');
      await _nearby!.stopAll();
      state = state.copyWith(
        lastError: () => 'Could not start mesh. Check Bluetooth, Location and '
            'Nearby-devices permissions are on.\n$e',
      );
      return;
    }

    state = state.copyWith(isRunning: true, lastError: () => null);
    _log('Mesh started as ${shortId(_myId)}');

    _reconnectTimer = Timer.periodic(_reconnectInterval, (_) => _reconnectTick());
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _heartbeatTick());
  }

  Future<void> stopMesh() async {
    _cancelTimers();
    await _nearby?.stopAll();
    _discovered.clear();
    _discoveredAt.clear();
    _pending.clear();
    // Keep peerLocations: the map shows last-known positions.
    state = state.copyWith(isRunning: false, connectedPeers: {}, discoveredCount: 0);
    _log('Mesh stopped');
  }

  void _cancelTimers() {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer = null;
  }

  void _addSelfRecord() {
    if (state.membershipRecords.containsKey(_myId)) return;
    _putMembership(MembershipRecord(
      deviceId: _myId,
      publicKey: base64Encode(_identity!.publicKeyBytes),
      invitedBy: 'self',
      joinedAt: DateTime.now(),
    ));
  }

  // ---------------------------------------------------------------------------
  // Discovery & connection management
  // ---------------------------------------------------------------------------

  /// Both sides discover each other; to avoid simultaneous requests colliding,
  /// only the device with the lexicographically smaller id initiates.
  bool _shouldInitiate(String endpointId) {
    final remoteId = _discovered[endpointId];
    if (remoteId == null) return false;
    if (_myId.compareTo(remoteId) < 0) return true;
    final seen = _discoveredAt[endpointId];
    return seen != null && DateTime.now().difference(seen) > _initiateFallback;
  }

  void _onEndpointFound(String endpointId, String endpointName) {
    if (endpointName == _myId) return;
    _discovered[endpointId] = endpointName;
    _discoveredAt.putIfAbsent(endpointId, DateTime.now);
    state = state.copyWith(discoveredCount: _discovered.length);
    _log('Discovered ${shortId(endpointName)} ($endpointId)');
    if (_shouldInitiate(endpointId)) _requestConnection(endpointId);
  }

  void _onEndpointLost(String? endpointId) {
    if (endpointId == null) return;
    _discovered.remove(endpointId);
    _discoveredAt.remove(endpointId);
    state = state.copyWith(discoveredCount: _discovered.length);
    _log('Lost endpoint $endpointId');
  }

  Future<void> _requestConnection(String endpointId) async {
    if (_pending.contains(endpointId) ||
        state.connectedPeers.containsKey(endpointId)) {
      return;
    }
    _pending.add(endpointId);
    try {
      await _nearby?.requestConnection(endpointId);
    } catch (e) {
      // Typically STATUS_ENDPOINT_IO_ERROR / already-connecting; retried by _reconnectTick.
      _pending.remove(endpointId);
      _log('Request to $endpointId failed: $e');
    }
  }

  void _reconnectTick() {
    for (final endpointId in _discovered.keys.toList()) {
      if (_shouldInitiate(endpointId)) _requestConnection(endpointId);
    }
  }

  Future<void> _onConnectionInitiated(String endpointId, ConnectionInfo info) async {
    // v1: open mesh — accept anyone advertising our service id.
    _pending.add(endpointId);
    _discovered[endpointId] = info.endpointName;
    _log('Handshake with ${shortId(info.endpointName)} '
        '(${info.isIncomingConnection ? "incoming" : "outgoing"})');
    try {
      await _nearby?.acceptConnection(endpointId);
    } catch (e) {
      _pending.remove(endpointId);
      _log('Accept $endpointId failed: $e');
    }
  }

  void _onConnectionResult(String endpointId, Status status) {
    _pending.remove(endpointId);
    if (status != Status.CONNECTED) {
      _log('Connection to $endpointId ${status.name}');
      return;
    }
    final deviceId = _discovered[endpointId] ?? endpointId;
    state = state.copyWith(
      connectedPeers: {...state.connectedPeers, endpointId: deviceId},
    );
    _log('Connected to ${shortId(deviceId)}');

    // Bring the new peer up to date: everyone we know about + our position.
    for (final record in state.membershipRecords.values) {
      _send(endpointId, {'type': 'membership_gossip', 'record': record.toJson()});
    }
    if (_myLatest != null) _send(endpointId, _myLatest!.toJson());
  }

  void _onDisconnected(String endpointId) {
    _pending.remove(endpointId);
    final deviceId = state.connectedPeers[endpointId];
    state = state.copyWith(
      connectedPeers: Map.of(state.connectedPeers)..remove(endpointId),
    );
    _log('Disconnected from ${shortId(deviceId ?? endpointId)}');
  }

  // ---------------------------------------------------------------------------
  // Payloads
  // ---------------------------------------------------------------------------

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(payload.bytes!)) as Map<String, dynamic>;
    } catch (e) {
      _log('Bad payload from $endpointId: $e');
      return;
    }

    switch (json['type']) {
      case 'location_update':
        _handleLocationUpdate(LocationUpdate.fromJson(json), endpointId);
      case 'membership_gossip':
        _handleMembershipGossip(
            MembershipRecord.fromJson(json['record'] as Map<String, dynamic>), endpointId);
      case 'ping':
        _log('Ping from ${shortId(json['from'] as String)}: ${json['message']}');
        _send(endpointId, {'type': 'pong', 'from': _myId, 'sentAt': json['sentAt']});
      case 'pong':
        final sentAt = DateTime.tryParse(json['sentAt'] as String? ?? '');
        final rtt = sentAt == null ? '?' : DateTime.now().difference(sentAt).inMilliseconds;
        _log('Pong from ${shortId(json['from'] as String)} (${rtt}ms)');
      default:
        _log('Unknown message type from $endpointId: ${json['type']}');
    }
  }

  void _handleLocationUpdate(LocationUpdate update, String fromEndpoint) {
    // Our own update echoed back by a relay.
    if (update.deviceId == _myId) return;

    // Keep only the newest per device. Equal timestamps are duplicates arriving
    // via another path — dropping them here is what stops relay loops.
    final existing = state.peerLocations[update.deviceId];
    if (existing != null && !update.timestamp.isAfter(existing.timestamp)) return;

    state = state.copyWith(
      peerLocations: {...state.peerLocations, update.deviceId: update},
    );

    // Forward with decremented TTL; a message whose TTL would hit 0 is dropped.
    if (update.ttl > 1) {
      _broadcast(
        update.copyWith(ttl: update.ttl - 1, hopCount: update.hopCount + 1).toJson(),
        excludeEndpoint: fromEndpoint,
      );
    }
  }

  void _handleMembershipGossip(MembershipRecord record, String fromEndpoint) {
    if (state.membershipRecords.containsKey(record.deviceId)) return;
    _putMembership(record);
    _log('Learned member ${shortId(record.deviceId)} '
        '(invited by ${shortId(record.invitedBy)})');
    _broadcast({'type': 'membership_gossip', 'record': record.toJson()},
        excludeEndpoint: fromEndpoint);
  }

  void _putMembership(MembershipRecord record) {
    state = state.copyWith(
      membershipRecords: {...state.membershipRecords, record.deviceId: record},
    );
  }

  // ---------------------------------------------------------------------------
  // Outgoing
  // ---------------------------------------------------------------------------

  Future<void> _send(String endpointId, Map<String, dynamic> json) async {
    try {
      await _nearby?.sendJson(endpointId, json);
    } catch (e) {
      _log('Send to $endpointId failed: $e');
    }
  }

  void _broadcast(Map<String, dynamic> json, {String? excludeEndpoint}) {
    for (final endpointId in state.connectedPeers.keys) {
      if (endpointId != excludeEndpoint) _send(endpointId, json);
    }
  }

  void broadcastNewMembership(MembershipRecord record) {
    _putMembership(record);
    _broadcast({'type': 'membership_gossip', 'record': record.toJson()});
  }

  Future<void> broadcastMyLocation(double lat, double lng) async {
    _identity ??= await ref.read(identityProvider.future);
    _myLatest = LocationUpdate(
      deviceId: _myId,
      lat: lat,
      lng: lng,
      timestamp: DateTime.now(),
      ttl: kLocationTtl,
      hopCount: 0,
    );
    _broadcast(_myLatest!.toJson());
  }

  void _heartbeatTick() {
    final last = _myLatest;
    if (last == null) return;
    broadcastMyLocation(last.lat, last.lng);
  }

  /// Phase 2 acceptance check: every connected peer should answer with a pong.
  void sendPing([String message = 'hello']) {
    if (_identity == null) return;
    _log('Ping -> ${state.connectedPeers.length} peer(s)');
    _broadcast({
      'type': 'ping',
      'from': _myId,
      'message': message,
      'sentAt': DateTime.now().toIso8601String(),
    });
  }

  void _log(String line) {
    debugPrint('[mesh] $line');
    final t = DateTime.now().toIso8601String().substring(11, 19);
    final log = [...state.log, '$t  $line'];
    state = state.copyWith(
      log: log.length > _maxLogEntries ? log.sublist(log.length - _maxLogEntries) : log,
    );
  }
}
