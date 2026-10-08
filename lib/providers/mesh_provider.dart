import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../services/crypto_service.dart';
import '../services/mesh_trust.dart';
import '../services/nearby_service.dart';
import 'identity_provider.dart';
import '../models/device_identity.dart';
import '../models/invite_payload.dart';
import '../models/location_update.dart';
import '../models/member_removal.dart';
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

/// A connected endpoint must prove membership (or complete a join) within
/// this window, or it is disconnected.
const Duration _authTimeout = Duration(seconds: 15);

const int _maxLogEntries = 100;
const String _trustPrefsKey = 'mesh_trust_v1';

String shortId(String deviceId) =>
    deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;

class MeshState {
  /// Null when this device isn't in a mesh yet.
  final String? meshId;
  final bool isRunning;

  /// Inviter's deviceId while a scanned invite is being completed.
  final String? joiningVia;

  /// endpointId -> deviceId of directly connected, *verified* members.
  final Map<String, String> connectedPeers;
  final int discoveredCount;

  /// deviceId -> newest location update we know of (direct or relayed).
  final Map<String, LocationUpdate> peerLocations;

  /// Active (not removed) members, including this device.
  final List<MembershipRecord> members;

  /// Human-readable debug log, newest last.
  final List<String> log;
  final String? lastError;

  const MeshState({
    this.meshId,
    this.isRunning = false,
    this.joiningVia,
    this.connectedPeers = const {},
    this.discoveredCount = 0,
    this.peerLocations = const {},
    this.members = const [],
    this.log = const [],
    this.lastError,
  });

  bool get inMesh => meshId != null;

  MeshState copyWith({
    String? Function()? meshId,
    bool? isRunning,
    String? Function()? joiningVia,
    Map<String, String>? connectedPeers,
    int? discoveredCount,
    Map<String, LocationUpdate>? peerLocations,
    List<MembershipRecord>? members,
    List<String>? log,
    String? Function()? lastError,
  }) {
    return MeshState(
      meshId: meshId != null ? meshId() : this.meshId,
      isRunning: isRunning ?? this.isRunning,
      joiningVia: joiningVia != null ? joiningVia() : this.joiningVia,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      discoveredCount: discoveredCount ?? this.discoveredCount,
      peerLocations: peerLocations ?? this.peerLocations,
      members: members ?? this.members,
      log: log ?? this.log,
      lastError: lastError != null ? lastError() : this.lastError,
    );
  }
}

/// Mesh protocol over Nearby Connections. Messages (JSON, `type` field):
///
/// Before verification (the only types accepted from an unverified endpoint):
/// - `hello` {meshId, deviceId, nonce}: sent by members on connect.
/// - `auth` {deviceId, signature, chain}: reply to hello; Ed25519 signature
///   over the peer's nonce, plus the invite chain so unknown members verify.
/// - `join_request` {inviteToken, deviceId, publicKey, signingKey}: sent by
///   a device that scanned an invite, to the inviter only.
/// - `join_accept` {sealed}: member list etc., AES-GCM encrypted under the
///   X25519 ECDH key between inviter and joiner. Decrypting it proves the
///   sender holds the inviter's private key from the QR.
/// - `join_reject` {reason}
///
/// Between verified members:
/// - `sync` {records, removals}: full membership exchange after verifying.
/// - `membership_gossip` {record}, `member_removed` {removal}: flooded.
/// - `location_update` (product.md §6), `ping`/`pong`.
class MeshNotifier extends Notifier<MeshState> {
  NearbyService? _nearby;
  DeviceIdentity? _identity;
  MeshTrust? _trust;
  InvitePayload? _pendingInvite;
  bool _loaded = false;

  /// endpointId -> remote deviceId (advertised endpoint name), and when we first saw it.
  final Map<String, String> _discovered = {};
  final Map<String, DateTime> _discoveredAt = {};

  /// Endpoints with a connection request / handshake in flight.
  final Set<String> _pending = {};

  /// Connected endpoints (verified or not) -> remote deviceId.
  final Map<String, String> _links = {};

  /// Challenge nonce we sent to each endpoint in our `hello`.
  final Map<String, String> _nonces = {};
  final Map<String, Timer> _authTimers = {};

  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  LocationUpdate? _myLatest;

  /// Serializes incoming message handling (see [_onPayloadReceived]).
  Future<void> _inbox = Future.value();

  @override
  MeshState build() {
    ref.onDispose(() {
      _cancelTimers();
      for (final t in _authTimers.values) {
        t.cancel();
      }
    });
    return const MeshState();
  }

  String get _myId => _identity!.deviceId;

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _identity ??= await ref.read(identityProvider.future);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_trustPrefsKey);
    if (raw != null) {
      try {
        _trust = await MeshTrust.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        _log('Saved mesh unreadable, ignoring: $e');
      }
    }
    _loaded = true;
    _publishTrust();
  }

  Future<void> _saveTrust() async {
    final prefs = await SharedPreferences.getInstance();
    if (_trust == null) {
      await prefs.remove(_trustPrefsKey);
    } else {
      await prefs.setString(_trustPrefsKey, jsonEncode(_trust!.toJson()));
    }
  }

  /// Mirror trust state into [MeshState] for the UI.
  void _publishTrust() {
    final trust = _trust;
    final members = (trust?.activeMembers ?? <MembershipRecord>[])
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    state = state.copyWith(meshId: () => trust?.meshId, members: members);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Starts advertising/discovery — only when in a mesh or joining one.
  Future<void> startMesh() async {
    await _ensureLoaded();
    if (state.isRunning) return;
    if (_trust == null && _pendingInvite == null) {
      _log('Not in a mesh yet — create one (Invite friend) or scan an invite');
      return;
    }

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
    _links.clear();
    _nonces.clear();
    for (final t in _authTimers.values) {
      t.cancel();
    }
    _authTimers.clear();
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

  // ---------------------------------------------------------------------------
  // Invites, joining, leaving
  // ---------------------------------------------------------------------------

  /// Creates an invite QR payload. Founds a new mesh if not in one yet.
  Future<InvitePayload> createInvite() async {
    await _ensureLoaded();
    if (_trust == null) {
      _trust = await MeshTrust.found(_identity!, meshId: const Uuid().v4());
      _log('Founded mesh ${shortId(_trust!.meshId)}');
      _publishTrust();
    }
    final invite = await _trust!.issueInvite(_identity!, serviceId: kMeshServiceId);
    await _saveTrust();
    _log('Issued invite (valid ${kInviteLifetime.inMinutes} min)');
    if (!state.isRunning) await startMesh();
    return invite;
  }

  /// Validates a scanned invite and starts joining. Returns an error message,
  /// or null when joining has started.
  Future<String?> acceptInvite(InvitePayload invite) async {
    await _ensureLoaded();
    if (invite.inviterDeviceId == _myId) return "That's your own invite.";
    if (_trust != null) {
      return invite.meshId == _trust!.meshId
          ? "You're already in this mesh."
          : "You're already in a mesh. Leave it first to join another.";
    }
    if (!DateTime.now().toUtc().isBefore(invite.expiresAt)) {
      return 'This invite has expired. Ask for a new QR.';
    }
    if (invite.serviceUUID != kMeshServiceId) return 'Invite is for a different app.';
    final validSignature = await CryptoService.verify(
      signingKeyB64: invite.inviterSigningKey,
      message: invite.message,
      signatureB64: invite.signature,
    );
    if (!validSignature) return 'Invite signature is invalid.';

    _pendingInvite = invite;
    state = state.copyWith(joiningVia: () => invite.inviterDeviceId, lastError: () => null);
    _log('Joining via ${shortId(invite.inviterDeviceId)} — keep phones close');
    if (state.isRunning) {
      _reconnectTick();
    } else {
      await startMesh();
    }
    return null;
  }

  void _clearPendingInvite([String? error]) {
    _pendingInvite = null;
    state = state.copyWith(
      joiningVia: () => null,
      lastError: error == null ? null : () => error,
    );
    if (error != null) _log(error);
    if (_trust == null) stopMesh();
  }

  /// Removes another member. Spreads to the whole mesh.
  Future<void> removeMember(String deviceId) async {
    final trust = _trust;
    if (trust == null || !trust.isActive(deviceId) || deviceId == _myId) return;
    final removal = await trust.signRemoval(_identity!, deviceId);
    final learned = await trust.ingest(removals: [removal]);
    await _applyLearned(learned.records, learned.removals, null);
  }

  /// Leaves the mesh: tells everyone, then forgets the mesh on this device.
  Future<void> leaveMesh() async {
    final trust = _trust;
    if (trust == null) return;
    final removal = await trust.signRemoval(_identity!, _myId);
    _broadcast({'type': 'member_removed', 'removal': removal.toJson()});
    // Give the message a moment to go out before dropping connections.
    await Future<void>.delayed(const Duration(seconds: 1));
    await _forgetMesh(null);
    _log('Left the mesh');
  }

  Future<void> _forgetMesh(String? reason) async {
    await stopMesh();
    _trust = null;
    _pendingInvite = null;
    await _saveTrust();
    state = state.copyWith(
      peerLocations: {},
      joiningVia: () => null,
      lastError: () => reason,
    );
    _publishTrust();
  }

  // ---------------------------------------------------------------------------
  // Discovery & connection management
  // ---------------------------------------------------------------------------

  bool _shouldInitiate(String endpointId) {
    final remoteId = _discovered[endpointId];
    if (remoteId == null) return false;

    // Joining: connect to the inviter, and only the inviter.
    final invite = _pendingInvite;
    if (invite != null) return remoteId == invite.inviterDeviceId;

    // Members only reach out to devices they know are members. Unknown
    // members (invited elsewhere) connect to us instead, and prove themselves.
    final trust = _trust;
    if (trust == null || !trust.isActive(remoteId)) return false;

    // Both sides discover each other; to avoid simultaneous requests colliding,
    // only the device with the lexicographically smaller id initiates.
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
    if (_pending.contains(endpointId) || _links.containsKey(endpointId)) return;
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
    final invite = _pendingInvite;
    if (invite != null && !DateTime.now().toUtc().isBefore(invite.expiresAt)) {
      _clearPendingInvite('Invite expired before the inviter was found. Scan a new QR.');
      return;
    }
    for (final endpointId in _discovered.keys.toList()) {
      if (_shouldInitiate(endpointId)) _requestConnection(endpointId);
    }
  }

  Future<void> _onConnectionInitiated(String endpointId, ConnectionInfo info) async {
    final remoteId = info.endpointName;
    // Not in a mesh and not joining one: nothing to talk about. Otherwise
    // accept and verify after connecting (anyone can advertise any name, and
    // a removed device may be coming back with a fresh invite).
    if (_trust == null && _pendingInvite == null) {
      _log('Refused connection from ${shortId(remoteId)}');
      try {
        await _nearby?.rejectConnection(endpointId);
      } catch (_) {}
      return;
    }

    _pending.add(endpointId);
    _discovered[endpointId] = remoteId;
    _log('Handshake with ${shortId(remoteId)} '
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
    final remoteId = _discovered[endpointId] ?? endpointId;
    _links[endpointId] = remoteId;
    _log('Linked to ${shortId(remoteId)}, verifying…');

    _authTimers[endpointId] = Timer(_authTimeout, () {
      if (!state.connectedPeers.containsKey(endpointId)) {
        _log('${shortId(remoteId)} did not verify in time');
        _disconnect(endpointId);
      }
    });

    final invite = _pendingInvite;
    if (invite != null && remoteId == invite.inviterDeviceId) {
      _send(endpointId, {
        'type': 'join_request',
        'inviteToken': invite.inviteToken,
        'deviceId': _myId,
        'publicKey': _identity!.publicKeyB64,
        'signingKey': _identity!.signingKeyB64,
      });
    } else if (_trust != null) {
      final nonce = CryptoService.randomToken();
      _nonces[endpointId] = nonce;
      _send(endpointId, {
        'type': 'hello',
        'meshId': _trust!.meshId,
        'deviceId': _myId,
        'nonce': nonce,
      });
    }
  }

  void _onDisconnected(String endpointId) {
    _pending.remove(endpointId);
    _links.remove(endpointId);
    _nonces.remove(endpointId);
    _authTimers.remove(endpointId)?.cancel();
    final deviceId = state.connectedPeers[endpointId];
    state = state.copyWith(
      connectedPeers: Map.of(state.connectedPeers)..remove(endpointId),
    );
    _log('Disconnected from ${shortId(deviceId ?? endpointId)}');
  }

  Future<void> _disconnect(String endpointId) async {
    try {
      await _nearby?.disconnect(endpointId);
    } catch (_) {}
    _onDisconnected(endpointId);
  }

  /// [endpointId] is now a verified member: start exchanging mesh data.
  void _markVerified(String endpointId, String deviceId) {
    _authTimers.remove(endpointId)?.cancel();
    _links[endpointId] = deviceId;
    state = state.copyWith(connectedPeers: {...state.connectedPeers, endpointId: deviceId});
    _log('Verified ${shortId(deviceId)} ✓');

    final trust = _trust!;
    _send(endpointId, {
      'type': 'sync',
      'records': [for (final r in trust.allRecords) r.toJson()],
      'removals': [for (final r in trust.allRemovals) r.toJson()],
    });
    if (_myLatest != null) _send(endpointId, _myLatest!.toJson());
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
    // Handle messages one at a time, in arrival order. Handlers are async
    // (crypto), so without this a peer's location/sync sent right after
    // join_accept or auth could be processed before that handshake finished
    // verifying the peer — and be dropped as "unverified".
    _inbox = _inbox.then((_) => _handleMessage(endpointId, json)).catchError((Object e) {
      _log('Error handling ${json['type']} from $endpointId: $e');
    });
  }

  Future<void> _handleMessage(String endpointId, Map<String, dynamic> json) async {
    final type = json['type'];

    // Handshake messages are the only ones accepted before verification.
    switch (type) {
      case 'hello':
        return _handleHello(endpointId, json);
      case 'auth':
        return _handleAuth(endpointId, json);
      case 'join_request':
        return _handleJoinRequest(endpointId, json);
      case 'join_accept':
        return _handleJoinAccept(endpointId, json);
      case 'join_reject':
        if (_pendingInvite != null) {
          _clearPendingInvite('Inviter refused: ${json['reason']}');
          _disconnect(endpointId);
        }
        return;
    }

    if (!state.connectedPeers.containsKey(endpointId)) return; // unverified: ignore

    switch (type) {
      case 'sync':
        await _handleSync(endpointId, json);
      case 'location_update':
        _handleLocationUpdate(LocationUpdate.fromJson(json), endpointId);
      case 'membership_gossip':
        await _ingestAndApply(endpointId,
            records: [MembershipRecord.fromJson(json['record'] as Map<String, dynamic>)]);
      case 'member_removed':
        await _ingestAndApply(endpointId,
            removals: [MemberRemoval.fromJson(json['removal'] as Map<String, dynamic>)]);
      case 'ping':
        _log('Ping from ${shortId(json['from'] as String)}: ${json['message']}');
        _send(endpointId, {'type': 'pong', 'from': _myId, 'sentAt': json['sentAt']});
      case 'pong':
        final sentAt = DateTime.tryParse(json['sentAt'] as String? ?? '');
        final rtt = sentAt == null ? '?' : DateTime.now().difference(sentAt).inMilliseconds;
        _log('Pong from ${shortId(json['from'] as String)} (${rtt}ms)');
      default:
        _log('Unknown message type from $endpointId: $type');
    }
  }

  static String _authMessage(String meshId, String nonce, String prover, String verifier) =>
      'intercomm-auth|$meshId|$nonce|$prover|$verifier';

  /// Peer challenges us: answer with a signature over its nonce.
  Future<void> _handleHello(String endpointId, Map<String, dynamic> json) async {
    final trust = _trust;
    if (trust == null) return; // joining: we answer the inviter with join_request instead
    if (json['meshId'] != trust.meshId) {
      _log('${shortId(json['deviceId'] as String)} is in a different mesh');
      _disconnect(endpointId);
      return;
    }
    final peerId = json['deviceId'] as String;
    final signature = await CryptoService.sign(
      _identity!,
      _authMessage(trust.meshId, json['nonce'] as String, _myId, peerId),
    );
    _send(endpointId, {
      'type': 'auth',
      'deviceId': _myId,
      'signature': signature,
      'chain': [for (final r in trust.chainFor(_myId)) r.toJson()],
    });
  }

  /// Peer answers our challenge: verify its invite chain and signature.
  Future<void> _handleAuth(String endpointId, Map<String, dynamic> json) async {
    final trust = _trust;
    final nonce = _nonces[endpointId];
    if (trust == null || nonce == null) return;
    final peerId = json['deviceId'] as String;

    final chain = [
      for (final r in json['chain'] as List) MembershipRecord.fromJson(r as Map<String, dynamic>),
    ];
    final learned = await trust.ingestRecords(chain);

    final ok = trust.isActive(peerId) &&
        await CryptoService.verify(
          signingKeyB64: trust.currentRecord(peerId)!.signingKey,
          message: _authMessage(trust.meshId, nonce, peerId, _myId),
          signatureB64: json['signature'] as String,
        );
    if (!ok) {
      final removals = trust.allRemovals.where((r) => r.deviceId == peerId).toList();
      if (removals.isNotEmpty && !trust.isActive(peerId)) {
        // A removed device that missed the news (it was away). Tell it, so it
        // forgets the mesh and can be re-invited, then drop it.
        _log('Rejected ${shortId(peerId)}: was removed — notifying it');
        for (final removal in removals) {
          _send(endpointId, {'type': 'member_removed', 'removal': removal.toJson()});
        }
        Timer(const Duration(seconds: 2), () => _disconnect(endpointId));
      } else {
        _log('Rejected ${shortId(peerId)}: not a verified member');
        _disconnect(endpointId);
      }
      return;
    }
    _nonces.remove(endpointId);
    await _applyLearned(learned, const [], endpointId);
    _markVerified(endpointId, peerId);
  }

  /// Inviter side: a device presents an invite token we issued.
  Future<void> _handleJoinRequest(String endpointId, Map<String, dynamic> json) async {
    final trust = _trust;
    if (trust == null) return;
    final token = json['inviteToken'] as String;
    final joinerId = json['deviceId'] as String;

    // A valid token is all that's needed — including for a device that left
    // or was removed earlier: showing it a fresh QR is how it's let back in.
    if (!trust.isValidInvite(token)) {
      const reason = 'invite expired or unknown';
      _log('Join from ${shortId(joinerId)} refused: $reason');
      _send(endpointId, {'type': 'join_reject', 'reason': reason});
      return;
    }
    final rejoining = trust.everRemoved(joinerId);

    final record = await trust.vouchFor(
      _identity!,
      deviceId: joinerId,
      publicKey: json['publicKey'] as String,
      signingKey: json['signingKey'] as String,
    );
    final key = await CryptoService.deriveJoinKey(
      identity: _identity!,
      remotePublicKeyB64: record.publicKey,
      meshId: trust.meshId,
      inviteToken: token,
    );
    _log('Join key with ${shortId(joinerId)}: ${await CryptoService.fingerprint(key)}');

    final sealed = await CryptoService.encryptJson(key, {
      'meshId': trust.meshId,
      'founderId': trust.founderId,
      'records': [for (final r in trust.allRecords) r.toJson()],
      'removals': [for (final r in trust.allRemovals) r.toJson()],
    });
    _send(endpointId, {'type': 'join_accept', 'sealed': sealed});

    await _applyLearned([record], const [], endpointId);
    _log('${shortId(joinerId)} ${rejoining ? 'rejoined' : 'joined'} the mesh');
    _markVerified(endpointId, joinerId);
  }

  /// Joiner side: decrypt the inviter's reply with our ECDH key.
  Future<void> _handleJoinAccept(String endpointId, Map<String, dynamic> json) async {
    final invite = _pendingInvite;
    if (invite == null || _links[endpointId] != invite.inviterDeviceId) return;

    final key = await CryptoService.deriveJoinKey(
      identity: _identity!,
      // From the QR, not the network — only the real inviter can produce a
      // message that decrypts under this key.
      remotePublicKeyB64: invite.inviterPublicKey,
      meshId: invite.meshId,
      inviteToken: invite.inviteToken,
    );
    _log('Join key with ${shortId(invite.inviterDeviceId)}: '
        '${await CryptoService.fingerprint(key)}');

    final Map<String, dynamic> content;
    try {
      content = await CryptoService.decryptJson(key, json['sealed'] as Map<String, dynamic>);
    } catch (_) {
      _clearPendingInvite('Could not verify the inviter (key exchange failed).');
      _disconnect(endpointId);
      return;
    }
    if (content['meshId'] != invite.meshId) {
      _clearPendingInvite('Inviter sent a different mesh.');
      _disconnect(endpointId);
      return;
    }

    final trust = MeshTrust(meshId: invite.meshId, founderId: content['founderId'] as String);
    await trust.ingest(
      records: _parseRecords(content['records'] as List),
      removals: _parseRemovals(content['removals'] as List),
    );
    if (trust.currentRecord(_myId)?.invitedBy != invite.inviterDeviceId) {
      _clearPendingInvite('Inviter did not admit this device.');
      _disconnect(endpointId);
      return;
    }

    _trust = trust;
    _pendingInvite = null;
    await _saveTrust();
    state = state.copyWith(joiningVia: () => null);
    _publishTrust();
    _log('Joined mesh ${shortId(trust.meshId)} with ${trust.activeMembers.length} members');
    _markVerified(endpointId, invite.inviterDeviceId);
  }

  Future<void> _handleSync(String endpointId, Map<String, dynamic> json) async {
    await _ingestAndApply(
      endpointId,
      records: _parseRecords(json['records'] as List),
      removals: _parseRemovals(json['removals'] as List),
    );
  }

  static List<MembershipRecord> _parseRecords(List raw) => [
        for (final r in raw) MembershipRecord.fromJson(r as Map<String, dynamic>),
      ];

  static List<MemberRemoval> _parseRemovals(List raw) => [
        for (final r in raw) MemberRemoval.fromJson(r as Map<String, dynamic>),
      ];

  Future<void> _ingestAndApply(
    String fromEndpoint, {
    List<MembershipRecord> records = const [],
    List<MemberRemoval> removals = const [],
  }) async {
    final trust = _trust;
    if (trust == null) return;
    final learned = await trust.ingest(records: records, removals: removals);
    await _applyLearned(learned.records, learned.removals, fromEndpoint);
  }

  /// Persists newly valid membership events, floods them to everyone else
  /// (except [fromEndpoint]), and acts on anyone who is no longer active.
  Future<void> _applyLearned(
    List<MembershipRecord> records,
    List<MemberRemoval> removals,
    String? fromEndpoint,
  ) async {
    final trust = _trust;
    if (trust == null || (records.isEmpty && removals.isEmpty)) return;
    await _saveTrust();
    _publishTrust();

    for (final record in records) {
      _log('Learned member ${shortId(record.deviceId)} '
          '(invited by ${shortId(record.invitedBy)})');
      _broadcast({'type': 'membership_gossip', 'record': record.toJson()},
          excludeEndpoint: fromEndpoint);
    }
    for (final removal in removals) {
      _log(removal.isLeave
          ? '${shortId(removal.deviceId)} left the mesh'
          : '${shortId(removal.deviceId)} removed by ${shortId(removal.removedBy)}');
      _broadcast({'type': 'member_removed', 'removal': removal.toJson()},
          excludeEndpoint: fromEndpoint);
    }

    // Act on current status, not on the events: a removal may already have
    // been superseded by a newer re-invite in the same batch.
    for (final removal in removals) {
      final id = removal.deviceId;
      if (trust.isActive(id)) continue;
      if (id == _myId) {
        await _forgetMesh('You were removed from the mesh by ${shortId(removal.removedBy)}.');
        return;
      }
      state = state.copyWith(peerLocations: Map.of(state.peerLocations)..remove(id));
      for (final e in _links.entries.toList()) {
        if (e.value == id) _disconnect(e.key);
      }
    }
  }

  void _handleLocationUpdate(LocationUpdate update, String fromEndpoint) {
    // Our own update echoed back by a relay.
    if (update.deviceId == _myId) return;
    // Only show verified, current members.
    if (!(_trust?.isActive(update.deviceId) ?? false)) return;

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

  /// Sends to verified members only.
  void _broadcast(Map<String, dynamic> json, {String? excludeEndpoint}) {
    for (final endpointId in state.connectedPeers.keys) {
      if (endpointId != excludeEndpoint) _send(endpointId, json);
    }
  }

  /// Records our position and sends it to verified members. The position is
  /// kept even when not in a mesh yet: GPS only reports on movement, so a
  /// stationary phone that founds/joins a mesh later would otherwise have
  /// nothing to send (until it moved 5 m).
  Future<void> broadcastMyLocation(double lat, double lng) async {
    await _ensureLoaded();
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
