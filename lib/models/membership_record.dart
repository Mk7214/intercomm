/// A mesh member's public keys, vouched for by whoever invited them.
///
/// [signature] is made by the inviter's Ed25519 key over [signedMessage].
/// The mesh founder's record is self-signed (`invitedBy == deviceId`).
/// Any device can therefore verify a member by walking the invite chain
/// back to the founder.
class MembershipRecord {
  final String deviceId;
  final String publicKey; // base64 X25519
  final String signingKey; // base64 Ed25519
  final String invitedBy;
  final DateTime joinedAt;
  final String signature; // base64, by inviter

  MembershipRecord({
    required this.deviceId,
    required this.publicKey,
    required this.signingKey,
    required this.invitedBy,
    required this.joinedAt,
    required this.signature,
  });

  bool get isFounder => invitedBy == deviceId;

  /// Canonical bytes the inviter signs. Includes [meshId] so a record can't
  /// be replayed into a different mesh.
  static String signedMessage({
    required String meshId,
    required String deviceId,
    required String publicKey,
    required String signingKey,
    required String invitedBy,
    required DateTime joinedAt,
  }) =>
      'intercomm-member|$meshId|$deviceId|$publicKey|$signingKey|$invitedBy|'
      '${joinedAt.toUtc().toIso8601String()}';

  String messageFor(String meshId) => signedMessage(
        meshId: meshId,
        deviceId: deviceId,
        publicKey: publicKey,
        signingKey: signingKey,
        invitedBy: invitedBy,
        joinedAt: joinedAt,
      );

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'publicKey': publicKey,
      'signingKey': signingKey,
      'invitedBy': invitedBy,
      'joinedAt': joinedAt.toUtc().toIso8601String(),
      'signature': signature,
    };
  }

  factory MembershipRecord.fromJson(Map<String, dynamic> json) {
    return MembershipRecord(
      deviceId: json['deviceId'],
      publicKey: json['publicKey'],
      signingKey: json['signingKey'],
      invitedBy: json['invitedBy'],
      joinedAt: DateTime.parse(json['joinedAt']),
      signature: json['signature'],
    );
  }
}
