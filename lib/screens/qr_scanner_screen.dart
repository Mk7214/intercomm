import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invite_payload.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  bool _scanned = false;

  void _onDetect(BarcodeCapture capture) {
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
            // Process payload (verify signature, do ECDH, store membership)
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
