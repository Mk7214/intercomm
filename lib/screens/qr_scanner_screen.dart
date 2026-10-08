import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invite_payload.dart';
import '../providers/mesh_provider.dart';

/// Scans an invite QR, verifies it, and starts joining. The join itself
/// (key exchange with the inviter) completes over Bluetooth afterwards.
class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  bool _busy = false;
  DateTime _lastErrorTime = DateTime.fromMillisecondsSinceEpoch(0);

  void _showError(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastErrorTime).inSeconds > 2) {
      _lastErrorTime = now;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null) return;

    final InvitePayload invite;
    try {
      final decoded = jsonDecode(code);
      if (decoded is! Map<String, dynamic> || decoded['type'] != 'mesh_invite') {
        _showError('Not an Intercomm invite');
        return;
      }
      invite = InvitePayload.fromJson(decoded);
    } catch (e) {
      debugPrint('Error parsing QR: $e');
      _showError('Could not read this QR code');
      return;
    }

    _busy = true;
    final error = await ref.read(meshProvider.notifier).acceptInvite(invite);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      // Let the same code be rescanned after the message, in case it's fixed.
      await Future<void>.delayed(const Duration(seconds: 2));
      _busy = false;
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Joining via ${shortId(invite.inviterDeviceId)} — keep the phones close'),
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan invite')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
