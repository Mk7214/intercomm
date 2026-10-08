import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/invite_payload.dart';
import '../providers/mesh_provider.dart';

/// Shows a signed, short-lived invite QR. If this device isn't in a mesh
/// yet, creating the invite founds a new one.
class QrGeneratorScreen extends ConsumerStatefulWidget {
  const QrGeneratorScreen({super.key});

  @override
  ConsumerState<QrGeneratorScreen> createState() => _QrGeneratorScreenState();
}

class _QrGeneratorScreenState extends ConsumerState<QrGeneratorScreen> {
  late Future<InvitePayload> _invite;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _invite = ref.read(meshProvider.notifier).createInvite();
    // Refresh the countdown once a second.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _regenerate() {
    setState(() => _invite = ref.read(meshProvider.notifier).createInvite());
  }

  @override
  Widget build(BuildContext context) {
    final mesh = ref.watch(meshProvider);

    // Someone joined while this QR was on screen.
    ref.listen<MeshState>(meshProvider, (prev, next) {
      final before = prev?.members.length ?? 0;
      if (next.members.length > before) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A new member joined the mesh')),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Invite a friend')),
      body: FutureBuilder<InvitePayload>(
        future: _invite,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Could not create invite: ${snapshot.error}'));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final invite = snapshot.data!;
          final left = invite.expiresAt.difference(DateTime.now().toUtc());
          final expired = left.isNegative;

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Opacity(
                    opacity: expired ? 0.2 : 1,
                    child: QrImageView(
                      data: jsonEncode(invite.toJson()),
                      version: QrVersions.auto,
                      size: 260,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (expired) ...[
                    const Text('This invite has expired.'),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _regenerate, child: const Text('New invite')),
                  ] else ...[
                    const Text(
                      'Have your friend scan this with Intercomm,\n'
                      'then keep the phones close while they join.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Expires in ${left.inMinutes}:'
                      '${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text('${mesh.members.length} member(s) in this mesh',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
