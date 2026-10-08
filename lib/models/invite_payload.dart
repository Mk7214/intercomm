/// QR invite (product.md §6). Carries only public data: the inviter's keys
/// and a short-lived [inviteToken]. The scanner proves it saw the QR by
/// presenting the token; the inviter proves its identity in the ECDH join
/// handshake. No group key travels in the QR.
class InvitePayload {
  final String meshId;
  final String inviterDeviceId;
  final String inviterPublicKey; // base64 X25519
  final String inviterSigningKey; // base64 Ed25519
  final String inviteToken;
  final String serviceUUID;
  final DateTime expiresAt;
  final String signature; // base64, by inviter over [signedMessage]

  InvitePayload({
    required this.meshId,
    required this.inviterDeviceId,
    required this.inviterPublicKey,
    required this.inviterSigningKey,
    required this.inviteToken,
    required this.serviceUUID,
    required this.expiresAt,
    required this.signature,
  });

  static String signedMessage({
    required String meshId,
    required String inviterDeviceId,
    required String inviterPublicKey,
    required String inviterSigningKey,
    required String inviteToken,
    required String serviceUUID,
    required DateTime expiresAt,
  }) =>
      'intercomm-invite|$meshId|$inviterDeviceId|$inviterPublicKey|$inviterSigningKey|'
      '$inviteToken|$serviceUUID|${expiresAt.toUtc().toIso8601String()}';

  String get message => signedMessage(
        meshId: meshId,
        inviterDeviceId: inviterDeviceId,
        inviterPublicKey: inviterPublicKey,
        inviterSigningKey: inviterSigningKey,
        inviteToken: inviteToken,
        serviceUUID: serviceUUID,
        expiresAt: expiresAt,
      );

  Map<String, dynamic> toJson() {
    return {
      'type': 'mesh_invite',
      'meshId': meshId,
      'inviterDeviceId': inviterDeviceId,
      'inviterPublicKey': inviterPublicKey,
      'inviterSigningKey': inviterSigningKey,
      'inviteToken': inviteToken,
      'serviceUUID': serviceUUID,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'signature': signature,
    };
  }

  factory InvitePayload.fromJson(Map<String, dynamic> json) {
    return InvitePayload(
      meshId: json['meshId'],
      inviterDeviceId: json['inviterDeviceId'],
      inviterPublicKey: json['inviterPublicKey'],
      inviterSigningKey: json['inviterSigningKey'],
      inviteToken: json['inviteToken'],
      serviceUUID: json['serviceUUID'],
      expiresAt: DateTime.parse(json['expiresAt']),
      signature: json['signature'],
    );
  }
}
