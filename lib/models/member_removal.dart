/// A signed statement that [deviceId] is no longer in the mesh.
/// [removedBy] may be another member, or the device itself when leaving.
class MemberRemoval {
  final String deviceId;
  final String removedBy;
  final DateTime removedAt;
  final String signature; // base64, by removedBy's Ed25519 key

  MemberRemoval({
    required this.deviceId,
    required this.removedBy,
    required this.removedAt,
    required this.signature,
  });

  bool get isLeave => deviceId == removedBy;

  static String signedMessage({
    required String meshId,
    required String deviceId,
    required String removedBy,
    required DateTime removedAt,
  }) =>
      'intercomm-remove|$meshId|$deviceId|$removedBy|${removedAt.toUtc().toIso8601String()}';

  String messageFor(String meshId) => signedMessage(
        meshId: meshId,
        deviceId: deviceId,
        removedBy: removedBy,
        removedAt: removedAt,
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'removedBy': removedBy,
        'removedAt': removedAt.toUtc().toIso8601String(),
        'signature': signature,
      };

  factory MemberRemoval.fromJson(Map<String, dynamic> json) => MemberRemoval(
        deviceId: json['deviceId'],
        removedBy: json['removedBy'],
        removedAt: DateTime.parse(json['removedAt']),
        signature: json['signature'],
      );
}
