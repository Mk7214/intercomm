import 'dart:convert';

class DeviceIdentity {
  final String deviceId;
  final List<int> privateKeyBytes;
  final List<int> publicKeyBytes;

  DeviceIdentity({
    required this.deviceId,
    required this.privateKeyBytes,
    required this.publicKeyBytes,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'privateKey': base64Encode(privateKeyBytes),
      'publicKey': base64Encode(publicKeyBytes),
    };
  }

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    return DeviceIdentity(
      deviceId: json['deviceId'],
      privateKeyBytes: base64Decode(json['privateKey']),
      publicKeyBytes: base64Decode(json['publicKey']),
    );
  }
}
