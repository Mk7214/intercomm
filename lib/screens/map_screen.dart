import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'members_screen.dart';
import 'qr_generator_screen.dart';
import 'qr_scanner_screen.dart';
import '../widgets/action_dial.dart';
import '../widgets/peer_color.dart';
import '../models/location_update.dart';
import '../providers/mesh_provider.dart';
import '../providers/location_provider.dart';

/// On-disk tile cache. Lives in app support storage (not the temp dir, which
/// Android may purge) so areas viewed while online stay available offline.
final Future<FileCacheStore> _tileCacheFuture = getApplicationSupportDirectory()
    .then((dir) => FileCacheStore('${dir.path}${Platform.pathSeparator}map_tiles'));

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  bool _mapReady = false;
  bool _centeredOnMe = false;
  bool _starting = false;
  String? _permissionProblem;

  static const _requiredPermissions = [
    Permission.locationWhenInUse,
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices,
  ];

  static const _fallbackCenter = LatLng(12.9716, 77.5946);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from Settings (e.g. after enabling Bluetooth/Location or
  /// granting a permission) retries automatically — no Start button needed.
  /// Only *checks* permissions here: the permission dialog itself pauses and
  /// resumes the app, so requesting on resume would re-prompt in a loop.
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed && !ref.read(meshProvider).isRunning) {
      _startMesh(prompt: false);
    }
  }

  Future<void> _startMesh({bool prompt = true}) async {
    if (_starting) return;
    _starting = true;
    try {
      if (await _checkPermissions(prompt: prompt) && mounted) {
        await ref.read(meshProvider.notifier).startMesh();
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _bootstrap() async {
    await _startMesh();
    if (!mounted) return;
    // Start GPS stream (foreground only for v1).
    ref.read(locationProvider);
  }

  /// Returns true when everything Nearby Connections needs is granted.
  /// With [prompt] false, only reads the current status (no dialog).
  Future<bool> _checkPermissions({required bool prompt}) async {
    // Foreground location only — requesting locationAlways in the same batch
    // gets the whole request denied on Android 11+.
    final statuses = prompt
        ? await _requiredPermissions.request()
        : {for (final p in _requiredPermissions) p: await p.status};

    final denied = statuses.entries
        .where((e) => !e.value.isGranted && !e.value.isLimited)
        .map((e) => e.key.toString().replaceFirst('Permission.', ''))
        .toList();

    String? problem;
    if (denied.isNotEmpty) {
      problem = 'Permissions denied: ${denied.join(', ')}';
    } else if (!await Geolocator.isLocationServiceEnabled()) {
      // Nearby discovery and GPS both need system location turned on.
      problem = 'Turn on Location services to join the mesh.';
    }
    if (mounted) setState(() => _permissionProblem = problem);
    return problem == null;
  }

  void _onMapReady() {
    _mapReady = true;
    final me = ref.read(locationProvider);
    if (me != null) _centerOn(me);
  }

  void _centerOn(Position p) {
    if (!_mapReady) return;
    _centeredOnMe = true;
    _mapController.move(LatLng(p.latitude, p.longitude), 16);
  }

  List<Marker> _buildMarkers(MeshState mesh, Position? me) {
    return [
      for (final loc in mesh.peerLocations.values)
        Marker(
          point: LatLng(loc.lat, loc.lng),
          width: 110,
          height: 62,
          alignment: Alignment.topCenter, // pin tip sits on the point
          child: GestureDetector(
            onTap: () => _showPeerInfo(loc),
            child: _PeerPin(loc: loc),
          ),
        ),
      if (me != null)
        Marker(
          point: LatLng(me.latitude, me.longitude),
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blueAccent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
          ),
        ),
    ];
  }

  void _showPeerInfo(LocationUpdate loc) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Peer ${shortId(loc.deviceId)} · '
            '${loc.hopCount == 0 ? 'direct' : '${loc.hopCount} hop(s)'} · '
            '${_ago(loc.timestamp)}'),
        duration: const Duration(seconds: 3),
      ));
  }

  Widget _buildMap(MeshState mesh, Position? me) {
    return FutureBuilder<FileCacheStore>(
      future: _tileCacheFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        return FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _fallbackCenter,
            initialZoom: 11,
            onMapReady: _onMapReady,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              // Required by the OSM tile usage policy.
              userAgentPackageName: 'com.intercomm.app',
              // Fall back to the uncached provider if the cache dir is unavailable.
              tileProvider: snapshot.hasData
                  ? CachedTileProvider(
                      store: snapshot.data!,
                      maxStale: const Duration(days: 30),
                    )
                  : null,
            ),
            MarkerLayer(markers: _buildMarkers(mesh, me)),
            // Bottom-left: top is the status card, bottom-right is the action dial.
            const SimpleAttributionWidget(
              source: Text('OpenStreetMap contributors'),
              alignment: Alignment.bottomLeft,
            ),
          ],
        );
      },
    );
  }

  static String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 60) return '${s}s ago';
    if (s < 3600) return '${s ~/ 60}m ago';
    return '${s ~/ 3600}h ago';
  }

  static String _statusText(MeshState mesh) {
    if (mesh.joiningVia != null) {
      return 'Joining via ${shortId(mesh.joiningVia!)}… keep the phones close';
    }
    if (!mesh.inMesh) {
      return 'Not in a mesh yet. Tap + → Invite friend to start one, '
          'or Scan invite to join a friend\'s.';
    }
    if (!mesh.isRunning) return 'Starting mesh…';
    return '${mesh.members.length} members · ${mesh.connectedPeers.length} connected · '
        '${mesh.peerLocations.length} on map';
  }

  void _open(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  void _goToMe() {
    final me = ref.read(locationProvider);
    if (me != null) {
      _centerOn(me);
    } else {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Waiting for GPS fix…')));
    }
  }

  void _showDebugSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _MeshDebugSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mesh = ref.watch(meshProvider);
    final me = ref.watch(locationProvider);

    ref.listen<Position?>(locationProvider, (prev, next) {
      if (next != null && !_centeredOnMe) _centerOn(next);
    });

    ref.listen<MeshState>(meshProvider, (prev, next) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (prev?.joiningVia != null && prev?.meshId == null && next.meshId != null) {
        messenger.showSnackBar(const SnackBar(content: Text('Joined the mesh!')));
        return;
      }
      final before = prev?.connectedPeers.length ?? 0;
      if (next.connectedPeers.length > before) {
        messenger.showSnackBar(SnackBar(
          content: Text('Connected to ${next.connectedPeers.length} peer(s)'),
          duration: const Duration(seconds: 2),
        ));
      }
    });

    // Mesh errors (e.g. "you were removed", join failures) show even when
    // not running; startup errors only while stopped.
    final error = _permissionProblem ?? (mesh.isRunning ? null : mesh.lastError);
    final canRetry = !mesh.isRunning && (mesh.inMesh || mesh.joiningVia != null);

    return Scaffold(
      // Bottom-right speed dial; actions expand upwards.
      floatingActionButton: ActionDial(
        actions: [
          DialAction(icon: Icons.hub, label: 'Mesh debug', onPressed: _showDebugSheet),
          DialAction(
            icon: Icons.group,
            label: 'Members',
            onPressed: () => _open(const MembersScreen()),
          ),
          DialAction(
            icon: Icons.qr_code_scanner,
            label: 'Scan invite',
            onPressed: () => _open(const QrScannerScreen()),
          ),
          DialAction(
            icon: Icons.qr_code,
            label: 'Invite friend',
            onPressed: () => _open(const QrGeneratorScreen()),
          ),
          DialAction(icon: Icons.my_location, label: 'My location', onPressed: _goToMe),
        ],
      ),
      body: Stack(
        children: [
          _buildMap(mesh, me),
          // No app bar, so keep the status card clear of the status bar.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 16,
            right: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(error,
                            style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    Text(_statusText(mesh), textAlign: TextAlign.center),
                    if (error != null && canRetry) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: FilledButton(
                          onPressed: _startMesh,
                          child: const Text('Retry'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live view of connections, members and the mesh log — used to verify
/// Phase 2/3 acceptance tests on-device.
class _MeshDebugSheet extends ConsumerWidget {
  const _MeshDebugSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mesh = ref.watch(meshProvider);
    final textTheme = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Connected peers (${mesh.connectedPeers.length})',
                    style: textTheme.titleMedium),
              ),
              OutlinedButton(
                onPressed: mesh.connectedPeers.isEmpty
                    ? null
                    : ref.read(meshProvider.notifier).sendPing,
                child: const Text('Ping peers'),
              ),
            ],
          ),
          for (final e in mesh.connectedPeers.entries)
            _PeerRow(deviceId: e.value, text: '${shortId(e.value)}  (endpoint ${e.key})'),
          const SizedBox(height: 12),
          Text('Members (${mesh.members.length})', style: textTheme.titleMedium),
          for (final r in mesh.members)
            Text('• ${shortId(r.deviceId)}  invited by ${shortId(r.invitedBy)}'),
          const SizedBox(height: 12),
          Text('Known locations (${mesh.peerLocations.length})', style: textTheme.titleMedium),
          for (final l in mesh.peerLocations.values)
            _PeerRow(
              deviceId: l.deviceId,
              text: '${shortId(l.deviceId)}  ${l.lat.toStringAsFixed(5)}, '
                  '${l.lng.toStringAsFixed(5)}  hops=${l.hopCount}',
            ),
          const SizedBox(height: 12),
          Text('Log', style: textTheme.titleMedium),
          for (final line in mesh.log.reversed)
            Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}

/// Map pin in the peer's colour with a name label above it.
/// Relayed peers get a "relay" tag and a lighter pin.
class _PeerPin extends StatelessWidget {
  final LocationUpdate loc;
  const _PeerPin({required this.loc});

  @override
  Widget build(BuildContext context) {
    final color = peerColor(loc.deviceId);
    final relayed = loc.hopCount > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
          ),
          child: Text(
            relayed ? '${shortId(loc.deviceId)} · relay' : shortId(loc.deviceId),
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Icon(
          Icons.location_on,
          size: 40,
          color: relayed ? color.withValues(alpha: 0.6) : color,
        ),
      ],
    );
  }
}

class _PeerRow extends StatelessWidget {
  final String deviceId;
  final String text;
  const _PeerRow({required this.deviceId, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          CircleAvatar(radius: 6, backgroundColor: peerColor(deviceId)),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
