import '../models/device_identity.dart';
import '../models/invite_payload.dart';
import '../models/member_removal.dart';
import '../models/membership_record.dart';
import 'crypto_service.dart';

/// How long an invite QR stays valid (product.md §6).
const Duration kInviteLifetime = Duration(minutes: 10);

/// Upper bound on stored events, so junk from non-members can't grow it forever.
const int _maxCandidates = 2000;

/// Who is in the mesh, as verified by this device. Pure Dart (no Flutter or
/// Nearby) so it can be unit-tested.
///
/// Membership is an event log: admissions ([MembershipRecord], signed by the
/// inviter) and removals ([MemberRemoval], signed by the remover or by the
/// device itself when leaving). The current membership is computed by
/// replaying all known events in time order:
/// - The founder's self-signed admission is the root.
/// - An admission counts only if its inviter was active at that moment.
/// - A removal counts only if the remover and the target were active then.
/// So a removed device can be re-invited later (a newer admission), a stale
/// removal can't undo a newer re-admission, and removed members can't
/// invite or remove anyone. Old events are kept, so every invite chain
/// stays verifiable even after members leave and rejoin.
///
/// Every device replays the same events the same way, so all devices that
/// have seen the same events agree. Ordering relies on device clocks; the
/// signers clamp timestamps to keep cause before effect (see [_after]).
class MeshTrust {
  final String meshId;
  final String founderId;

  /// Invite tokens this device issued -> expiry. Multi-use until expiry
  /// (v1 = open invite, product.md §3).
  final Map<String, DateTime> issuedInvites;

  /// Every well-formed event we've received, valid or not yet valid
  /// (an event can become valid when an earlier event it depends on arrives).
  final Map<String, MembershipRecord> _recordCandidates = {};
  final Map<String, MemberRemoval> _removalCandidates = {};

  /// Signature check results, by event key (verification is the slow part).
  final Map<String, bool> _signatureOk = {};

  // Results of the last replay.
  final Map<String, List<MembershipRecord>> _admissions = {};
  final Map<String, List<MemberRemoval>> _removals = {};
  final Map<String, Object> _latest = {}; // deviceId -> last valid event
  final Set<String> _validKeys = {};

  MeshTrust({
    required this.meshId,
    required this.founderId,
    Map<String, DateTime>? issuedInvites,
  }) : issuedInvites = issuedInvites ?? {};

  /// Start a brand-new mesh with [identity] as founder.
  static Future<MeshTrust> found(DeviceIdentity identity, {required String meshId}) async {
    final trust = MeshTrust(meshId: meshId, founderId: identity.deviceId);
    final record = await _signRecord(
      identity,
      meshId: meshId,
      deviceId: identity.deviceId,
      publicKey: identity.publicKeyB64,
      signingKey: identity.signingKeyB64,
      joinedAt: DateTime.now().toUtc(),
    );
    await trust.ingest(records: [record]);
    return trust;
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  bool isActive(String deviceId) => _latest[deviceId] is MembershipRecord;

  /// The admission that made [deviceId] active, if it is active now.
  MembershipRecord? currentRecord(String deviceId) {
    final latest = _latest[deviceId];
    return latest is MembershipRecord ? latest : null;
  }

  /// Whether [deviceId] has ever been removed / left (and not necessarily rejoined).
  bool everRemoved(String deviceId) => _removals[deviceId]?.isNotEmpty ?? false;

  List<MembershipRecord> get activeMembers => [
        for (final id in _latest.keys)
          if (currentRecord(id) != null) currentRecord(id)!,
      ];

  /// All valid admissions and removals — what to send in a sync.
  List<MembershipRecord> get allRecords => [for (final l in _admissions.values) ...l];
  List<MemberRemoval> get allRemovals => [for (final l in _removals.values) ...l];

  /// Admissions from the founder down to [deviceId]'s current admission —
  /// enough for a device that has never heard of [deviceId] to verify it.
  List<MembershipRecord> chainFor(String deviceId) {
    final chain = <MembershipRecord>[];
    var current = currentRecord(deviceId);
    while (current != null && !chain.contains(current)) {
      chain.insert(0, current);
      if (current.isFounder) break;
      current = _admissionActiveAt(current.invitedBy, current.joinedAt);
    }
    return chain;
  }

  /// The admission under which [deviceId] was active just before [time].
  MembershipRecord? _admissionActiveAt(String deviceId, DateTime time) {
    Object? last;
    for (final event in [...?_admissions[deviceId], ...?_removals[deviceId]]) {
      final t = _time(event);
      if (t.isBefore(time) && (last == null || t.isAfter(_time(last)))) last = event;
    }
    return last is MembershipRecord ? last : null;
  }

  // ---------------------------------------------------------------------------
  // Ingest + replay
  // ---------------------------------------------------------------------------

  /// Adds events and recomputes membership. Returns the events that became
  /// valid because of this call (for logging and gossip).
  Future<({List<MembershipRecord> records, List<MemberRemoval> removals})> ingest({
    Iterable<MembershipRecord> records = const [],
    Iterable<MemberRemoval> removals = const [],
  }) async {
    for (final r in records) {
      if (_recordCandidates.length < _maxCandidates) _recordCandidates[_recordKey(r)] = r;
    }
    for (final r in removals) {
      if (_removalCandidates.length < _maxCandidates) _removalCandidates[_removalKey(r)] = r;
    }
    final before = Set.of(_validKeys);
    await _replay();
    return (
      records: [
        for (final e in _recordCandidates.entries)
          if (_validKeys.contains(e.key) && !before.contains(e.key)) e.value,
      ],
      removals: [
        for (final e in _removalCandidates.entries)
          if (_validKeys.contains(e.key) && !before.contains(e.key)) e.value,
      ],
    );
  }

  /// Convenience wrappers.
  Future<List<MembershipRecord>> ingestRecords(Iterable<MembershipRecord> records) async =>
      (await ingest(records: records)).records;

  Future<bool> applyRemoval(MemberRemoval removal) async =>
      (await ingest(removals: [removal])).removals.isNotEmpty;

  Future<void> _replay() async {
    final events = <Object>[..._recordCandidates.values, ..._removalCandidates.values]
      ..sort((a, b) {
        final byTime = _time(a).compareTo(_time(b));
        // Same instant: admissions before removals, then a stable tie-break.
        if (byTime != 0) return byTime;
        if (a is MembershipRecord && b is MemberRemoval) return -1;
        if (a is MemberRemoval && b is MembershipRecord) return 1;
        return _key(a).compareTo(_key(b));
      });

    _admissions.clear();
    _removals.clear();
    _latest.clear();
    _validKeys.clear();

    for (final event in events) {
      if (event is MembershipRecord) {
        final String signerKey;
        if (event.isFounder) {
          // Only the founder's original self-signed admission is a root.
          if (event.deviceId != founderId || _admissions.containsKey(founderId)) continue;
          signerKey = event.signingKey;
        } else {
          final inviter = currentRecord(event.invitedBy);
          if (inviter == null) continue; // inviter not active at that time
          signerKey = inviter.signingKey;
        }
        if (!await _verified(_recordKey(event), signerKey, event.messageFor(meshId), event.signature)) {
          continue;
        }
        (_admissions[event.deviceId] ??= []).add(event);
        _latest[event.deviceId] = event;
        _validKeys.add(_recordKey(event));
      } else if (event is MemberRemoval) {
        final remover = currentRecord(event.removedBy);
        if (remover == null || !isActive(event.deviceId)) continue;
        if (!await _verified(
            _removalKey(event), remover.signingKey, event.messageFor(meshId), event.signature)) {
          continue;
        }
        (_removals[event.deviceId] ??= []).add(event);
        _latest[event.deviceId] = event;
        _validKeys.add(_removalKey(event));
      }
    }
  }

  Future<bool> _verified(String key, String signerKey, String message, String signature) async {
    // Cache by event + signer: the same event checked against the same key
    // always gives the same answer.
    final cacheKey = '$key|$signerKey';
    return _signatureOk[cacheKey] ??= await CryptoService.verify(
      signingKeyB64: signerKey,
      message: message,
      signatureB64: signature,
    );
  }

  static DateTime _time(Object event) =>
      event is MembershipRecord ? event.joinedAt : (event as MemberRemoval).removedAt;

  static String _recordKey(MembershipRecord r) => 'a|${r.deviceId}|${r.signature}';
  static String _removalKey(MemberRemoval r) => 'r|${r.deviceId}|${r.signature}';
  static String _key(Object e) =>
      e is MembershipRecord ? _recordKey(e) : _removalKey(e as MemberRemoval);

  /// A timestamp that is now, but strictly after every event of [deviceIds].
  /// Keeps cause before effect in the replay even if this device's clock is
  /// a little behind the device that admitted it.
  DateTime _after(Iterable<String> deviceIds) {
    var t = DateTime.now().toUtc();
    for (final id in deviceIds) {
      for (final e in [...?_admissions[id], ...?_removals[id]]) {
        final next = _time(e).add(const Duration(milliseconds: 1));
        if (!t.isAfter(_time(e))) t = next;
      }
    }
    return t;
  }

  // ---------------------------------------------------------------------------
  // Signing new events
  // ---------------------------------------------------------------------------

  static Future<MembershipRecord> _signRecord(
    DeviceIdentity inviter, {
    required String meshId,
    required String deviceId,
    required String publicKey,
    required String signingKey,
    required DateTime joinedAt,
  }) async {
    return MembershipRecord(
      deviceId: deviceId,
      publicKey: publicKey,
      signingKey: signingKey,
      invitedBy: inviter.deviceId,
      joinedAt: joinedAt,
      signature: await CryptoService.sign(
        inviter,
        MembershipRecord.signedMessage(
          meshId: meshId,
          deviceId: deviceId,
          publicKey: publicKey,
          signingKey: signingKey,
          invitedBy: inviter.deviceId,
          joinedAt: joinedAt,
        ),
      ),
    );
  }

  /// Admits a device, with [identity] (an active member) as inviter.
  /// Re-admits a device that was removed or left. Returns its current record.
  Future<MembershipRecord> vouchFor(
    DeviceIdentity identity, {
    required String deviceId,
    required String publicKey,
    required String signingKey,
  }) async {
    final existing = currentRecord(deviceId);
    if (existing != null) return existing;
    final record = await _signRecord(
      identity,
      meshId: meshId,
      deviceId: deviceId,
      publicKey: publicKey,
      signingKey: signingKey,
      joinedAt: _after([identity.deviceId, deviceId]),
    );
    await ingest(records: [record]);
    return record;
  }

  Future<MemberRemoval> signRemoval(DeviceIdentity identity, String deviceId) async {
    final removedAt = _after([identity.deviceId, deviceId]);
    return MemberRemoval(
      deviceId: deviceId,
      removedBy: identity.deviceId,
      removedAt: removedAt,
      signature: await CryptoService.sign(
        identity,
        MemberRemoval.signedMessage(
          meshId: meshId,
          deviceId: deviceId,
          removedBy: identity.deviceId,
          removedAt: removedAt,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Invites
  // ---------------------------------------------------------------------------

  Future<InvitePayload> issueInvite(DeviceIdentity identity, {required String serviceId}) async {
    _pruneInvites();
    final token = CryptoService.randomToken();
    final expiresAt = DateTime.now().toUtc().add(kInviteLifetime);
    issuedInvites[token] = expiresAt;
    final message = InvitePayload.signedMessage(
      meshId: meshId,
      inviterDeviceId: identity.deviceId,
      inviterPublicKey: identity.publicKeyB64,
      inviterSigningKey: identity.signingKeyB64,
      inviteToken: token,
      serviceUUID: serviceId,
      expiresAt: expiresAt,
    );
    return InvitePayload(
      meshId: meshId,
      inviterDeviceId: identity.deviceId,
      inviterPublicKey: identity.publicKeyB64,
      inviterSigningKey: identity.signingKeyB64,
      inviteToken: token,
      serviceUUID: serviceId,
      expiresAt: expiresAt,
      signature: await CryptoService.sign(identity, message),
    );
  }

  bool isValidInvite(String token) {
    final expiry = issuedInvites[token];
    return expiry != null && DateTime.now().toUtc().isBefore(expiry);
  }

  void _pruneInvites() {
    final now = DateTime.now().toUtc();
    issuedInvites.removeWhere((_, expiry) => !now.isBefore(expiry));
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Saves only valid events; not-yet-valid candidates are re-learned on sync.
  Map<String, dynamic> toJson() {
    _pruneInvites();
    return {
      'meshId': meshId,
      'founderId': founderId,
      'members': [for (final r in allRecords) r.toJson()],
      'removals': [for (final r in allRemovals) r.toJson()],
      'issuedInvites': {
        for (final e in issuedInvites.entries) e.key: e.value.toIso8601String(),
      },
    };
  }

  /// Restores saved state; re-verifies it by replaying the saved events.
  static Future<MeshTrust> fromJson(Map<String, dynamic> json) async {
    final trust = MeshTrust(
      meshId: json['meshId'],
      founderId: json['founderId'],
      issuedInvites: {
        for (final e in (json['issuedInvites'] as Map<String, dynamic>).entries)
          e.key: DateTime.parse(e.value as String),
      },
    );
    await trust.ingest(
      records: [
        for (final r in json['members'] as List) MembershipRecord.fromJson(r as Map<String, dynamic>),
      ],
      removals: [
        for (final r in json['removals'] as List) MemberRemoval.fromJson(r as Map<String, dynamic>),
      ],
    );
    return trust;
  }
}
