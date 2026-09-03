import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/invite_payload.dart';
import '../providers/identity_provider.dart';

class QrGeneratorScreen extends ConsumerWidget {
  const QrGeneratorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Invite a Friend')),
      body: identityAsync.when(
        data: (identity) {
          // Generate a payload. In a real app we'd sign it using the private key.
          final payload = InvitePayload(
            meshId: const Uuid().v4(), // Ideally from a mesh provider
            inviterDeviceId: identity.deviceId,
            inviterPublicKey: base64Encode(identity.publicKeyBytes),
            groupKey: 'temp_group_key_for_v1', // Should be exchanged or generated
            serviceUUID: 'nearby-connections-mesh',
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
            signature: 'dummy_signature',
          );

          final jsonStr = jsonEncode(payload.toJson());

          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                QrImageView(
                  data: jsonStr,
                  version: QrVersions.auto,
                  size: 250.0,
                ),
                const SizedBox(height: 20),
                const Text('Scan this code to join the mesh'),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
      ),
    );
  }
}
