# Product spec: Hybrid online/offline friend location mesh (prototype v1)

## 1. What we're building

A mobile app where a group of friends can see each other's live location on a map.

- **Online mode**: location syncs through a cloud backend over cellular/Wi-Fi.
- **Offline mode**: location syncs peer-to-peer over Bluetooth (BLE) when no internet is available. More connected peers = more relay hops = better effective range.
- **Onboarding**: any existing member can generate a QR code to invite a new member. Scanning it pairs the new device into the mesh and (if online) the server-side friend graph.

This spec covers the **first testable prototype**, not the full product. Scope is deliberately narrow so an agent can build and verify each piece independently.

---

## 2. Prototype goals (v1)

Build and verify, in order:

1. Two devices can pair via QR code and exchange keys.
2. Two-three devices in BLE range can discover each other, form a mesh, and relay a location update (offline mode only).
3. The map UI shows all mesh members' last-known location, updating live.
4. (Phase 2) Devices can also sync location through a cloud backend when online, and the map merges both sources.

## 3. Explicit non-goals for v1 (do not build yet)

- Multi-hop relay beyond 2 hops (test with 1 hop first — A relays for B to reach C)
- Key revocation / removing members
- Admin approval flow for invites (v1 = open invite, anyone with the QR joins)
- Production-grade encryption review (use a well-known library, don't hand-roll crypto, but don't spend time on formal audit yet)
- Battery optimization / adaptive duty cycling
- iOS support if time-constrained — **prototype on Android first**, since Android's background BLE restrictions are far less punishing than iOS's. Port to iOS after core logic is proven.

---

## 4. Do we need Firebase for v1?

**No — not for the first milestone.** Build and test the offline BLE mesh + QR pairing path first; it's fully peer-to-peer and needs no backend at all. Add Firebase (or Supabase) only in Phase 2, once offline mode works, to handle the online sync path. This lets you validate the harder, more novel part of the system (mesh + pairing) before investing in backend setup.

---

## 5. Tech stack

| Layer | Choice | Notes |
|---|---|---|
| App framework | Flutter | Cross-platform, but prototype Android-first |
| Local mesh transport | `nearby_connections` plugin (wraps Google Nearby Connections API) | Handles BLE + Wi-Fi Direct discovery/transport; do not hand-roll BLE GATT for v1. Android-only — flag iOS gap early (see §3) |
| QR generation | `qr_flutter` | Encodes JSON payload (see §6) |
| QR scanning | `mobile_scanner` | |
| Key exchange | X25519 via the `cryptography` package | Do not invent custom crypto |
| Map | `google_maps_flutter` | |
| Local state/storage | Riverpod or Provider for state, `shared_preferences`/`hive` for persistence (no backend needed for v1 offline path) | |
| Online backend (Phase 2 only) | Firebase (FlutterFire: `firebase_auth` + `cloud_firestore`) | Add only once offline path is verified |

---

## 6. Data formats

### QR invite payload (JSON, encoded into QR)
```json
{
  "type": "mesh_invite",
  "meshId": "uuid",
  "inviterDeviceId": "uuid",
  "inviterPublicKey": "base64",
  "groupKey": "base64 (encrypted to be filled after handshake, or omitted and exchanged via ECDH)",
  "serviceUUID": "nearby-connections-service-id",
  "expiresAt": "ISO8601 timestamp (10 min from generation)",
  "signature": "base64 signature over the above fields, signed by inviter's private key"
}
```

### Location update message (broadcast over mesh)
```json
{
  "type": "location_update",
  "deviceId": "uuid",
  "lat": 12.9716,
  "lng": 77.5946,
  "timestamp": "ISO8601",
  "ttl": 3,
  "hopCount": 0
}
```
- Receivers keep only the newest `timestamp` per `deviceId`.
- Decrement `ttl` on each relay hop; drop message when `ttl` reaches 0 (prevents infinite flooding).

### Local membership record (stored per device)
```json
{
  "deviceId": "uuid",
  "publicKey": "base64",
  "invitedBy": "deviceId",
  "joinedAt": "ISO8601"
}
```

---

## 7. Task breakdown (clean, agent-sized tasks)

### Phase 0 — project setup
- [ ] Init Flutter project, Android target (min SDK per `nearby_connections` plugin requirements)
- [ ] Add and configure `nearby_connections`, `qr_flutter`, `mobile_scanner`, `cryptography`, `google_maps_flutter` packages
- [ ] Basic navigation: Map screen, Pairing screen

### Phase 1 — QR pairing (2 devices, no mesh yet)
- [ ] Generate device keypair (X25519) on first launch, store locally
- [ ] Device A: generate QR invite payload per §6, render as QR code
- [ ] Device B: scan QR, parse payload, verify signature and expiry
- [ ] Perform key exchange (ECDH) between A and B to derive shared group key
- [ ] Store resulting membership record (§6) on both devices
- [ ] **Acceptance test**: A generates QR, B scans it, both devices log the same derived shared key and each other's public key

### Phase 2 — BLE mesh discovery + transport (2 devices)
- [ ] Integrate Nearby Connections API: advertise + discover using `serviceUUID` from the invite payload
- [ ] Establish a Nearby Connections session between paired devices
- [ ] Send a hardcoded test message device-to-device, confirm receipt
- [ ] **Acceptance test**: two paired devices in BLE range auto-discover and connect without manual intervention

### Phase 3 — location broadcast over mesh (2-3 devices)
- [ ] Get device GPS location (foreground only for v1, `geolocator` package)
- [ ] On location change (or every N seconds), broadcast `location_update` message (§6) over the mesh session
- [ ] Receiving devices update a local in-memory map: `{deviceId: latestLocationUpdate}`
- [ ] Implement TTL/hopCount decrement + relay logic for 1-hop forwarding (device A → B → C, where A and C are not in direct range)
- [ ] **Acceptance test**: 3 devices, A and C not in direct BLE range but both in range of B — C receives A's location via B's relay

### Phase 4 — map UI
- [ ] Render `google_maps_flutter` with a marker per known device from the local location map
- [ ] Live-update markers as new `location_update` messages arrive
- [ ] Show device's own location too
- [ ] **Acceptance test**: moving one device updates its marker position on the other devices' map screens in near-real-time

### Phase 5 — mesh growth via QR (3rd+ member invited by a non-original member)
- [ ] Allow any paired device (not just the original) to generate a new invite QR, reusing the shared group key
- [ ] New device joins, gets group key, starts broadcasting/receiving location updates
- [ ] Gossip membership record to existing mesh members so everyone learns about the new device
- [ ] **Acceptance test**: device C is invited by device B (not A); device A still learns about C's location once in mesh range

### Phase 6 (only after Phase 0-5 verified) — online mode
- [ ] Set up Firebase project, add via FlutterFire CLI (Auth + Firestore)
- [ ] On connectivity available, sync local location + membership state to Firestore
- [ ] Subscribe to Firestore real-time updates for friends not in BLE range
- [ ] Merge server-sourced and mesh-sourced location data on the map (dedupe by `deviceId`, prefer newest `timestamp`)
- [ ] **Acceptance test**: device with cellular but no BLE range to a friend still sees that friend's location if the friend has connectivity too

---

## 8. Open questions to resolve during/after prototype

- Open invites vs approval-gated invites — decide after testing usability of open invites
- Key revocation strategy (needed before any real usage beyond testing)
- iOS feasibility given background BLE restrictions — revisit after Android prototype works
- Battery impact of continuous BLE advertising/scanning — measure once Phase 3 works

## 9. Definition of done for "prototype works"

You can hand 3 Android test devices to someone, have them:
1. Pair via QR (one seeds the mesh, invites the second; the second invites the third)
2. Turn on airplane mode (BLE only, no cellular)
3. Walk around, and see each other's live location update on a shared map, including at least one relayed (non-direct-range) hop
