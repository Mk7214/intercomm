import 'dart:convert';

/// This device's long-term identity. Two key pairs:
/// - X25519 ([privateKeyBytes]/[publicKeyBytes]) for ECDH key exchange.
/// - Ed25519 ([signingSeed]/[signingPublicKey]) for signing invites,
///   membership records and connection challenges (X25519 can't sign).
class DeviceIdentity {
  final String deviceId;
  final List<int> privateKeyBytes;
  final List<int> publicKeyBytes;
  final List<int> signingSeed;
  final List<int> signingPublicKey;

  DeviceIdentity({
    required this.deviceId,
    required this.privateKeyBytes,
    required this.publicKeyBytes,
    required this.signingSeed,
    required this.signingPublicKey,
  });

  String get publicKeyB64 => base64Encode(publicKeyBytes);
  String get signingKeyB64 => base64Encode(signingPublicKey);

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'privateKey': base64Encode(privateKeyBytes),
      'publicKey': base64Encode(publicKeyBytes),
      'signingSeed': base64Encode(signingSeed),
      'signingPublicKey': base64Encode(signingPublicKey),
    };
  }

  /// Returns null for identities saved before signing keys existed;
  /// the identity provider migrates those.
  static DeviceIdentity? tryFromJson(Map<String, dynamic> json) {
    if (json['signingSeed'] == null || json['signingPublicKey'] == null) return null;
    return DeviceIdentity(
      deviceId: json['deviceId'],
      privateKeyBytes: base64Decode(json['privateKey']),
      publicKeyBytes: base64Decode(json['publicKey']),
      signingSeed: base64Decode(json['signingSeed']),
      signingPublicKey: base64Decode(json['signingPublicKey']),
    );
  }
}
