class LocationUpdate {
  final String deviceId;
  final double lat;
  final double lng;
  final DateTime timestamp;
  final int ttl;
  final int hopCount;

  LocationUpdate({
    required this.deviceId,
    required this.lat,
    required this.lng,
    required this.timestamp,
    required this.ttl,
    required this.hopCount,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': 'location_update',
      'deviceId': deviceId,
      'lat': lat,
      'lng': lng,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'ttl': ttl,
      'hopCount': hopCount,
    };
  }

  factory LocationUpdate.fromJson(Map<String, dynamic> json) {
    return LocationUpdate(
      deviceId: json['deviceId'],
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp']),
      ttl: json['ttl'] ?? 3,
      hopCount: json['hopCount'] ?? 0,
    );
  }

  LocationUpdate copyWith({
    String? deviceId,
    double? lat,
    double? lng,
    DateTime? timestamp,
    int? ttl,
    int? hopCount,
  }) {
    return LocationUpdate(
      deviceId: deviceId ?? this.deviceId,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      timestamp: timestamp ?? this.timestamp,
      ttl: ttl ?? this.ttl,
      hopCount: hopCount ?? this.hopCount,
    );
  }
}
