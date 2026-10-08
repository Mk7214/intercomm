import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/membership_record.dart';
import '../providers/identity_provider.dart';
import '../providers/mesh_provider.dart';
import '../widgets/peer_color.dart';

/// Lists mesh members. Any member can remove another; anyone can leave.
class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mesh = ref.watch(meshProvider);
    final myId = ref.watch(identityProvider).value?.deviceId;
    final notifier = ref.read(meshProvider.notifier);
    final connected = mesh.connectedPeers.values.toSet();

    return Scaffold(
      appBar: AppBar(title: Text('Members (${mesh.members.length})')),
      body: !mesh.inMesh
          ? const Center(child: Text('Not in a mesh yet.'))
          : ListView(
              children: [
                for (final member in mesh.members)
                  _MemberTile(
                    member: member,
                    isMe: member.deviceId == myId,
                    isConnected: connected.contains(member.deviceId),
                    hasLocation: mesh.peerLocations.containsKey(member.deviceId),
                    onRemove: () async {
                      final ok = await _confirm(
                        context,
                        'Remove ${shortId(member.deviceId)}?',
                        'They will be disconnected and every phone in the mesh will '
                            'refuse them. To come back they need a new invite.',
                        'Remove',
                      );
                      if (ok) await notifier.removeMember(member.deviceId);
                    },
                  ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.logout),
                    label: const Text('Leave mesh'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: () async {
                      final ok = await _confirm(
                        context,
                        'Leave the mesh?',
                        'Your location stops being shared and this phone forgets the '
                            'mesh. You will need a new invite to rejoin.',
                        'Leave',
                      );
                      if (!ok) return;
                      await notifier.leaveMesh();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final MembershipRecord member;
  final bool isMe;
  final bool isConnected;
  final bool hasLocation;
  final VoidCallback onRemove;

  const _MemberTile({
    required this.member,
    required this.isMe,
    required this.isConnected,
    required this.hasLocation,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final status = isMe
        ? 'This phone'
        : isConnected
            ? 'Connected nearby'
            : hasLocation
                ? 'Seen via relay'
                : 'Not in range';
    final origin = member.isFounder ? 'Founder' : 'Invited by ${shortId(member.invitedBy)}';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isMe ? Colors.blueAccent : peerColor(member.deviceId),
        child: Text(
          member.deviceId.substring(0, 2).toUpperCase(),
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
      title: Text(isMe ? '${shortId(member.deviceId)} (you)' : shortId(member.deviceId)),
      subtitle: Text('$status · $origin'),
      trailing: isMe
          ? null
          : IconButton(
              tooltip: 'Remove from mesh',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: onRemove,
            ),
    );
  }
}
