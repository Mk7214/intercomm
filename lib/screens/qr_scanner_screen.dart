import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invite_payload.dart';
import '../models/membership_record.dart';
import '../providers/identity_provider.dart';
import '../providers/mesh_provider.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  bool _scanned = false;

  void _onDetect(BarcodeCapture capture) async {
    if (_scanned) return;
    
    final barcodes = capture.barcodes;
    if (barcodes.isNotEmpty) {
      final code = barcodes.first.rawValue;
      if (code != null) {
        try {
          final json = jsonDecode(code);
          if (json['type'] == 'mesh_invite') {
            _scanned = true;
            final payload = InvitePayload.fromJson(json);
            
            final identity = await ref.read(identityProvider.future);
            
            // Create membership record for self
            final record = MembershipRecord(
              deviceId: identity.deviceId,
              publicKey: base64Encode(identity.publicKeyBytes),
              invitedBy: payload.inviterDeviceId,
              joinedAt: DateTime.now(),
            );

            // Broadcast to the mesh once connected (or immediately if already connected)
            ref.read(meshProvider.notifier).broadcastNewMembership(record);

            _showSuccess(payload);
          }
        } catch (e) {
          // invalid code, ignore or show error
        }
      }
    }
  }

  void _showSuccess(InvitePayload payload) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Found Invite'),
        content: Text('Invited by: ${payload.inviterDeviceId}'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context); // close scanner
            },
            child: const Text('Join'),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Invite QR')),
      body: MobileScanner(
        onDetect: _onDetect,
      ),
    );
  }
}

