import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:somthing/models/device_identity.dart';
import 'package:somthing/models/membership_record.dart';
import 'package:somthing/services/crypto_service.dart';
import 'package:somthing/services/mesh_trust.dart';

Future<DeviceIdentity> newIdentity(String id) async {
  final x = await X25519().newKeyPair();
  final ed = await Ed25519().newKeyPair();
  return DeviceIdentity(
    deviceId: id,
    privateKeyBytes: await x.extractPrivateKeyBytes(),
    publicKeyBytes: (await x.extractPublicKey()).bytes,
    signingSeed: await ed.extractPrivateKeyBytes(),
    signingPublicKey: (await ed.extractPublicKey()).bytes,
  );
}

/// Simulates the join handshake's trust side: inviter vouches, joiner
/// receives the inviter's full member list.
Future<MeshTrust> join(MeshTrust inviterTrust, DeviceIdentity inviter, DeviceIdentity joiner) async {
  await inviterTrust.vouchFor(
    inviter,
    deviceId: joiner.deviceId,
    publicKey: joiner.publicKeyB64,
    signingKey: joiner.signingKeyB64,
  );
  final joinerTrust = MeshTrust(meshId: inviterTrust.meshId, founderId: inviterTrust.founderId);
  await joinerTrust.ingest(
    records: inviterTrust.allRecords.reversed,
    removals: inviterTrust.allRemovals,
  );
  return joinerTrust;
}

void main() {
  late DeviceIdentity a, b, c, mallory;

  setUp(() async {
    a = await newIdentity('aaaa');
    b = await newIdentity('bbbb');
    c = await newIdentity('cccc');
    mallory = await newIdentity('mmmm');
  });

  test('join handshake: both sides derive the same key', () async {
    final keyA = await CryptoService.deriveJoinKey(
        identity: a, remotePublicKeyB64: b.publicKeyB64, meshId: 'm', inviteToken: 't');
    final keyB = await CryptoService.deriveJoinKey(
        identity: b, remotePublicKeyB64: a.publicKeyB64, meshId: 'm', inviteToken: 't');
    expect(await CryptoService.fingerprint(keyA), await CryptoService.fingerprint(keyB));

    final sealed = await CryptoService.encryptJson(keyA, {'hello': 'mesh'});
    expect(await CryptoService.decryptJson(keyB, sealed), {'hello': 'mesh'});

    // An impostor using the inviter's public key but its own private key can't read it.
    final keyM = await CryptoService.deriveJoinKey(
        identity: mallory, remotePublicKeyB64: a.publicKeyB64, meshId: 'm', inviteToken: 't');
    expect(() => CryptoService.decryptJson(keyM, sealed), throwsA(anything));
  });

  test('member invited by a non-founder is verifiable by the founder (Phase 5)', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    final trustB = await join(trustA, a, b);
    final trustC = await join(trustB, b, c);

    // A has never seen C; C presents its chain and A verifies it.
    final accepted = await trustA.ingestRecords(trustC.chainFor(c.deviceId));
    expect(accepted.map((r) => r.deviceId), ['cccc']);
    expect(trustA.isActive('cccc'), isTrue);
    expect(trustC.isActive('aaaa'), isTrue);
  });

  test('forged or self-signed records are rejected', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');

    // Mallory signs her own record claiming A invited her.
    final joinedAt = DateTime.now().toUtc();
    final forged = MembershipRecord(
      deviceId: mallory.deviceId,
      publicKey: mallory.publicKeyB64,
      signingKey: mallory.signingKeyB64,
      invitedBy: a.deviceId,
      joinedAt: joinedAt,
      signature: await CryptoService.sign(
        mallory,
        MembershipRecord.signedMessage(
          meshId: 'mesh1',
          deviceId: mallory.deviceId,
          publicKey: mallory.publicKeyB64,
          signingKey: mallory.signingKeyB64,
          invitedBy: a.deviceId,
          joinedAt: joinedAt,
        ),
      ),
    );
    expect(await trustA.ingestRecords([forged]), isEmpty);

    // A record from another mesh doesn't carry over.
    final otherMesh = await MeshTrust.found(mallory, meshId: 'mesh2');
    expect(await trustA.ingestRecords(otherMesh.allRecords), isEmpty);
  });

  test('removal is enforced and spreads; removed members cannot invite', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    final trustB = await join(trustA, a, b);

    final removal = await trustA.signRemoval(a, b.deviceId);
    expect(await trustA.applyRemoval(removal), isTrue);
    expect(trustA.isActive('bbbb'), isFalse);

    // A member joining later receives the removal with the member list.
    final trustC = await join(trustA, a, c);
    expect(trustC.isActive('bbbb'), isFalse);
    expect(await trustC.applyRemoval(removal), isFalse); // already known

    // A member that already knew B learns it via gossip.
    final trustD = MeshTrust(meshId: 'mesh1', founderId: 'aaaa');
    await trustD.ingestRecords(trustA.allRecords);
    expect(trustD.isActive('bbbb'), isTrue);
    expect(await trustD.applyRemoval(removal), isTrue);
    expect(trustD.isActive('bbbb'), isFalse);

    // B (removed) tries to invite Mallory: A rejects her.
    await trustB.vouchFor(b,
        deviceId: mallory.deviceId,
        publicKey: mallory.publicKeyB64,
        signingKey: mallory.signingKeyB64);
    expect(await trustA.ingestRecords(trustB.chainFor(mallory.deviceId)), isEmpty);

    // And B can no longer remove anyone.
    final revenge = await trustB.signRemoval(b, a.deviceId);
    expect(await trustA.applyRemoval(revenge), isFalse);
  });

  test('leaving: a member can remove itself', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    final trustB = await join(trustA, a, b);
    final leave = await trustB.signRemoval(b, b.deviceId);
    expect(leave.isLeave, isTrue);
    expect(await trustA.applyRemoval(leave), isTrue);
    expect(trustA.isActive('bbbb'), isFalse);
  });

  test('invites expire and survive persistence round-trip', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    final invite = await trustA.issueInvite(a, serviceId: 'svc');
    expect(trustA.isValidInvite(invite.inviteToken), isTrue);
    expect(trustA.isValidInvite('nope'), isFalse);
    expect(
      await CryptoService.verify(
          signingKeyB64: invite.inviterSigningKey,
          message: invite.message,
          signatureB64: invite.signature),
      isTrue,
    );

    final restored = await MeshTrust.fromJson(trustA.toJson());
    expect(restored.isValidInvite(invite.inviteToken), isTrue);
    expect(restored.isActive('aaaa'), isTrue);
  });

  test('founder leaves, then rejoins through another member', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    final trustB = await join(trustA, a, b);

    // A leaves; B learns about it.
    final leave = await trustA.signRemoval(a, a.deviceId);
    expect(await trustB.applyRemoval(leave), isTrue);
    expect(trustB.isActive('aaaa'), isFalse);

    // B can still invite without the founder.
    final trustC = await join(trustB, b, c);
    expect(trustC.isActive('cccc'), isTrue);
    expect(trustC.isActive('aaaa'), isFalse);

    // A scans B's new QR: B re-admits A.
    final trustA2 = await join(trustB, b, a);
    expect(trustA2.isActive('aaaa'), isTrue);
    expect(trustA2.currentRecord('aaaa')!.invitedBy, 'bbbb');
    // Chains through the departed founder still verify.
    expect(trustA2.isActive('bbbb'), isTrue);

    // C learns of A's re-admission via gossip.
    await trustC.ingestRecords(trustB.chainFor('aaaa'));
    expect(trustC.isActive('aaaa'), isTrue);

    // A stale copy of the old removal arriving later doesn't undo it.
    expect(await trustC.applyRemoval(leave), isFalse);
    expect(trustC.isActive('aaaa'), isTrue);
  });

  test('removed member is re-admitted only by a fresh invite', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    await join(trustA, a, b);
    expect(await trustA.applyRemoval(await trustA.signRemoval(a, b.deviceId)), isTrue);
    expect(trustA.isActive('bbbb'), isFalse);

    // B's *old* admission replayed again doesn't bring B back.
    await trustA.ingestRecords(trustA.allRecords);
    expect(trustA.isActive('bbbb'), isFalse);

    // A new admission does.
    await trustA.vouchFor(a,
        deviceId: b.deviceId, publicKey: b.publicKeyB64, signingKey: b.signingKeyB64);
    expect(trustA.isActive('bbbb'), isTrue);
  });

  test('history survives persistence and order of arrival does not matter', () async {
    final trustA = await MeshTrust.found(a, meshId: 'mesh1');
    final trustB = await join(trustA, a, b);
    await join(trustB, b, c);
    await trustB.applyRemoval(await trustB.signRemoval(b, a.deviceId));
    await join(trustB, b, a); // A re-admitted by B

    final restored = await MeshTrust.fromJson(trustB.toJson());
    expect(restored.isActive('aaaa'), isTrue);
    expect(restored.isActive('cccc'), isTrue);

    // Same events, shuffled, give the same answer.
    final fresh = MeshTrust(meshId: 'mesh1', founderId: 'aaaa');
    await fresh.ingest(
      removals: trustB.allRemovals,
      records: trustB.allRecords.reversed,
    );
    expect(fresh.activeMembers.map((r) => r.deviceId).toSet(), {'aaaa', 'bbbb', 'cccc'});
  });
}
