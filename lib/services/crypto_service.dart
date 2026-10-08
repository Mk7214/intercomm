import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import '../models/device_identity.dart';

/// All crypto used by the mesh, built on the `cryptography` package
/// (no hand-rolled primitives):
/// - Ed25519 signatures for invites, membership records, removals, and
///   connection challenges.
/// - X25519 ECDH + HKDF-SHA256 + AES-256-GCM for the join handshake.
class CryptoService {
  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();
  static final _aead = AesGcm.with256bits();
  static final _random = Random.secure();

  static List<int> randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  static String randomToken([int length = 16]) =>
      base64UrlEncode(randomBytes(length)).replaceAll('=', '');

  static Future<String> sign(DeviceIdentity identity, String message) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(identity.signingSeed);
    final signature = await _ed25519.sign(utf8.encode(message), keyPair: keyPair);
    return base64Encode(signature.bytes);
  }

  static Future<bool> verify({
    required String signingKeyB64,
    required String message,
    required String signatureB64,
  }) async {
    try {
      return await _ed25519.verify(
        utf8.encode(message),
        signature: Signature(
          base64Decode(signatureB64),
          publicKey: SimplePublicKey(base64Decode(signingKeyB64), type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false; // malformed key/signature
    }
  }

  /// Pairwise key for the join handshake: X25519(my private, their public),
  /// stretched with HKDF and bound to the mesh and invite token.
  /// Both sides derive the same key; nobody else can.
  static Future<SecretKey> deriveJoinKey({
    required DeviceIdentity identity,
    required String remotePublicKeyB64,
    required String meshId,
    required String inviteToken,
  }) async {
    final myPair = await _x25519.newKeyPairFromSeed(identity.privateKeyBytes);
    final shared = await _x25519.sharedSecretKey(
      keyPair: myPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(remotePublicKeyB64),
        type: KeyPairType.x25519,
      ),
    );
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode(meshId),
      info: utf8.encode('intercomm-join|$inviteToken'),
    );
  }

  /// Short hex fingerprint of a key — safe to log for comparing that two
  /// devices derived the same key, without revealing it.
  static Future<String> fingerprint(SecretKey key) async {
    final hash = await Sha256().hash(await key.extractBytes());
    return hash.bytes.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<Map<String, String>> encryptJson(
    SecretKey key,
    Map<String, dynamic> json,
  ) async {
    final box = await _aead.encrypt(utf8.encode(jsonEncode(json)), secretKey: key);
    return {
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// Throws if the key is wrong or the message was tampered with.
  static Future<Map<String, dynamic>> decryptJson(
    SecretKey key,
    Map<String, dynamic> sealed,
  ) async {
    final clear = await _aead.decrypt(
      SecretBox(
        base64Decode(sealed['cipherText']),
        nonce: base64Decode(sealed['nonce']),
        mac: Mac(base64Decode(sealed['mac'])),
      ),
      secretKey: key,
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}
