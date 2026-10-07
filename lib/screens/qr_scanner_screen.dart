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
  DateTime _lastErrorTime = DateTime.fromMillisecondsSinceEpoch(0);

  void _showError(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastErrorTime).inSeconds > 2) {
      _lastErrorTime = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _onDetect(BarcodeCapture capture) async {
    if (_scanned) return;
    
    final barcodes = capture.barcodes;
    if (barcodes.isNotEmpty) {
      final code = barcodes.first.rawValue;
      if (code != null) {
        try {
          final decoded = jsonDecode(code);
          if (decoded is Map<String, dynamic> && decoded['type'] == 'mesh_invite') {
            setState(() { _scanned = true; });
            debugPrint('Scanned valid mesh_invite QR!');
            
            final payload = InvitePayload.fromJson(decoded);
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
            
            // Auto-start the mesh connection after a successful scan
            ref.read(meshProvider.notifier).startMesh();

            if (mounted) {
              _showSuccess(payload);
            }
          } else {
            _showError('Invalid QR: Not a mesh invite');
          }
        } catch (e, stack) {
          debugPrint('Error parsing QR: $e\n$stack');
          _showError('Error parsing QR code');
          // Don't set _scanned to true on error so we can keep scanning
        }
      }
    }
  }

  void _showSuccess(InvitePayload payload) {
    showDialog(
      context: context,
      barrierDismissible: false,
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
