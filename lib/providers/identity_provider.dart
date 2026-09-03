import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/device_identity.dart';

final identityProvider = FutureProvider<DeviceIdentity>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final identityJson = prefs.getString('device_identity');

  if (identityJson != null) {
    return DeviceIdentity.fromJson(jsonDecode(identityJson));
  }

  // Generate new identity
  final uuid = const Uuid().v4();
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final privateKey = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();

  final identity = DeviceIdentity(
    deviceId: uuid,
    privateKeyBytes: privateKey,
    publicKeyBytes: publicKey.bytes,
  );

  await prefs.setString('device_identity', jsonEncode(identity.toJson()));
  return identity;
});
