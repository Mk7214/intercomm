import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'pairing_screen.dart';
import '../providers/mesh_provider.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  late GoogleMapController mapController;
  final LatLng _center = const LatLng(12.9716, 77.5946);
  
  @override
  void initState() {
    super.initState();
    // Initialize mesh provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(meshProvider.notifier).initMesh('nearby-connections-mesh');
    });
  }

  void _onMapCreated(GoogleMapController controller) {
    mapController = controller;
  }

  @override
  Widget build(BuildContext context) {
    final meshState = ref.watch(meshProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mesh Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PairingScreen()),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            onMapCreated: _onMapCreated,
            initialCameraPosition: CameraPosition(
              target: _center,
              zoom: 11.0,
            ),
            myLocationEnabled: true,
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Peers Connected: ${meshState.connectedEndpoints.length}'),
                    if (meshState.messages.isNotEmpty)
                      Text('Last Msg: ${meshState.messages.last}'),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton(
                          onPressed: () {
                            if (meshState.isAdvertising) {
                              ref.read(meshProvider.notifier).stopMesh();
                            } else {
                              ref.read(meshProvider.notifier).startMesh();
                            }
                          },
                          child: Text(meshState.isAdvertising ? 'Stop Mesh' : 'Start Mesh'),
                        ),
                        ElevatedButton(
                          onPressed: meshState.connectedEndpoints.isEmpty
                              ? null
                              : () {
                                  ref.read(meshProvider.notifier).sendTestMessage('Ping!');
                                },
                          child: const Text('Send Ping'),
                        ),
                      ],
                    ),
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

