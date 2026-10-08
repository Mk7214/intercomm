import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/device_identity.dart';

final identityProvider = FutureProvider<DeviceIdentity>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final identityJson = prefs.getString('device_identity');
  final stored = identityJson == null ? null : jsonDecode(identityJson) as Map<String, dynamic>;

  final existing = stored == null ? null : DeviceIdentity.tryFromJson(stored);
  if (existing != null) return existing;

  // New device, or one saved before signing keys existed: keep its deviceId
  // and X25519 key if present, add whatever is missing.
  final String deviceId;
  final List<int> privateKey;
  final List<int> publicKey;
  if (stored != null) {
    deviceId = stored['deviceId'];
    privateKey = base64Decode(stored['privateKey']);
    publicKey = base64Decode(stored['publicKey']);
  } else {
    deviceId = const Uuid().v4();
    final keyPair = await X25519().newKeyPair();
    privateKey = await keyPair.extractPrivateKeyBytes();
    publicKey = (await keyPair.extractPublicKey()).bytes;
  }

  final signingPair = await Ed25519().newKeyPair();
  final identity = DeviceIdentity(
    deviceId: deviceId,
    privateKeyBytes: privateKey,
    publicKeyBytes: publicKey,
    signingSeed: await signingPair.extractPrivateKeyBytes(),
    signingPublicKey: (await signingPair.extractPublicKey()).bytes,
  );

  await prefs.setString('device_identity', jsonEncode(identity.toJson()));
  return identity;
});
