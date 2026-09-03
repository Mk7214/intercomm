class MembershipRecord {
  final String deviceId;
  final String publicKey; // base64
  final String invitedBy;
  final DateTime joinedAt;

  MembershipRecord({
    required this.deviceId,
    required this.publicKey,
    required this.invitedBy,
    required this.joinedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'publicKey': publicKey,
      'invitedBy': invitedBy,
      'joinedAt': joinedAt.toUtc().toIso8601String(),
    };
  }

  factory MembershipRecord.fromJson(Map<String, dynamic> json) {
    return MembershipRecord(
      deviceId: json['deviceId'],
      publicKey: json['publicKey'],
      invitedBy: json['invitedBy'],
      joinedAt: DateTime.parse(json['joinedAt']),
    );
  }
}
