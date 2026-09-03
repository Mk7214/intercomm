class InvitePayload {
  final String meshId;
  final String inviterDeviceId;
  final String inviterPublicKey; // base64
  final String groupKey; // base64
  final String serviceUUID;
  final DateTime expiresAt;
  final String signature; // base64

  InvitePayload({
    required this.meshId,
    required this.inviterDeviceId,
    required this.inviterPublicKey,
    required this.groupKey,
    required this.serviceUUID,
    required this.expiresAt,
    required this.signature,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': 'mesh_invite',
      'meshId': meshId,
      'inviterDeviceId': inviterDeviceId,
      'inviterPublicKey': inviterPublicKey,
      'groupKey': groupKey,
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
      groupKey: json['groupKey'] ?? '',
      serviceUUID: json['serviceUUID'],
      expiresAt: DateTime.parse(json['expiresAt']),
      signature: json['signature'],
    );
  }
}
