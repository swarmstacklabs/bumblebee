# LoRaWAN Server Migration Spec

## Goal

Implement the LoRaWAN server in `br2-external/package/lorawan-server/src/` by migrating only the Erlang code paths needed for:

1. the Semtech UDP packet forwarder interface
2. the HTTP admin/API interface

The reference implementation is the Erlang project at `/home/vnareiko/Homespace/bumblebee-lns/`.

This spec is intentionally narrow. It does not ask for full Bumblebee feature parity. It asks for a Zig implementation that preserves the externally visible UDP and HTTP behavior required to run the LoRaWAN server on the target system.

## Reference source

The migration target is defined primarily by these Erlang modules:

- `src/bumblebee_gw_forwarder.erl`
- `src/bumblebee_gw_router.erl`
- `src/bumblebee_app.erl`
- `src/bumblebee_http_registry.erl`
- `src/bumblebee_admin.erl`
- `src/bumblebee_frontend_handler.erl`
- `src/bumblebee_admin_redirect.erl`
- `src/bumblebee_lns.app.src`
- `doc/Configuration.md`
- `test/test_forwarder.erl`

The current Zig stub in `src/main.zig` is not compatible with the Erlang server yet:

- UDP listens on `1700`, while the Erlang default is `1680`
- UDP echoes payloads instead of implementing the Semtech protocol
- HTTP only exposes a sample `/api/devices` CRUD surface instead of the LoRaWAN admin/API routes

## Scope

### In scope

- Semtech UDP packet forwarder server behavior compatible with `bumblebee_gw_forwarder.erl`
- HTTP listener bootstrap and routing compatible with the relevant Erlang admin/API server behavior
- HTTP authentication behavior needed for admin/API access
- persistent storage required by the migrated HTTP/API and UDP flows
- enough internal server state to support uplink ingestion, gateway keepalive tracking, and downlink acknowledgements
- test coverage for migrated UDP and HTTP behavior

### Out of scope

- Basic Station / WebSocket LNS support from `bumblebee_gw_lns.erl`
- frontend asset build/dev-server integration from `bumblebee_frontend.erl`
- dynamic application/plugin route registration from `bumblebee_http_registry:update/2`
- non-HTTP connectors and backend integrations
- Prometheus, cluster support, Slack/e-mail alerts, live graphs, and admin UI parity
- full Mnesia data model parity
- migration of every admin endpoint in Bumblebee

## Required externally visible behavior

## 1. UDP packet forwarder interface

### Listen address

- default UDP port must be `1680`
- bind on `0.0.0.0`
- port must be configurable, matching the Erlang `packet_forwarder_listen` concept

### Supported Semtech packet types

Implement protocol handling compatible with `bumblebee_gw_forwarder.erl`:

- `PUSH_DATA` (`ident = 0`)
- `PUSH_ACK` (`ident = 1`) as server response
- `PULL_DATA` (`ident = 2`)
- `PULL_RESP` (`ident = 3`) as server response
- `PULL_ACK` (`ident = 4`) as server response
- `TX_ACK` (`ident = 5`)

Version handling should initially accept the version used in the Erlang tests and common packet forwarders. If stricter validation is added later, it must not break the existing Semtech forwarder flow used by Bumblebee.

### PUSH_DATA behavior

On receiving:

`<<Version, Token:16, 0, GatewayMac:8/binary, Json/binary>>`

the server must:

1. immediately send `PUSH_ACK` with the same version and token
2. decode JSON payload
3. handle:
   - `rxpk`
   - `stat`
   - ignore `time`
4. log or count malformed JSON, but not crash the listener

### `rxpk` handling

The migrated implementation must parse the subset used by Erlang:

- `tmst`
- `freq`
- `datr`
- `codr`
- `data`
- optional `time`
- optional `tmms`
- optional `rssi`
- optional `lsnr`
- optional `rsig` entries, picking the best RSSI when present

Expected normalization:

- `data` is Base64-decoded into PHY payload bytes
- `time` is parsed when present
- missing or `null` optional fields become `null`/`undefined` internally

The implementation must preserve enough parsed information for subsequent LoRaWAN processing and future downlink scheduling.

### `stat` handling

The migrated implementation does not need full server telemetry parity, but it must:

- parse the gateway status object
- associate it with the gateway MAC
- update last-seen/alive state
- retain enough fields to support later observability or admin API reads

### PULL_DATA behavior

On receiving:

`<<Version, Token:16, 2, GatewayMac:8/binary>>`

the server must:

1. immediately send `PULL_ACK`
2. mark the gateway as alive
3. store the return address tuple needed for later `PULL_RESP` downlinks

This alive record is the core server-side contract between uplink processing and later downlink delivery.

### Downlink send path

The Zig implementation must provide an internal API equivalent in role to:

- `bumblebee_gw_router:downlink/5`
- the `{send, Target, GWState, DevAddr, TxQ, RFCh, PHYPayload}` message handled by `bumblebee_gw_forwarder`

The first implementation does not need the full router stack, but it must define the server-side contract and data structures now.

Minimum required behavior:

- create `PULL_RESP` payload with JSON `{txpk: ...}`
- generate random 16-bit token
- track pending downlinks by token
- remember send timestamp
- expire pending ack state after 30 seconds

### `txpk` JSON generation

Mirror the Erlang behavior in `build_txpk/4`:

- class A downlink: `imme=false`, `tmst = gateway_tmst + delay_seconds * 1_000_000`
- immediate/class C downlink: `imme=true`
- absolute-time downlink: `imme=false`, `time=<ISO8601>`
- include:
  - `freq`
  - `rfch`
  - `powe`
  - `modu` (`"LORA"` for string datarate, `"FSK"` for integer datarate)
  - `datr`
  - `codr`
  - `ipol=true`
  - `size`
  - `data` as Base64

### TX_ACK behavior

On receiving:

`<<Version, Token:16, 5, GatewayMac:8/binary, Json/binary>>`

the server must:

- match the token against pending downlinks
- compute network delay using send timestamp and ack timestamp
- accept empty JSON payloads and trimmed leading `0`, space, or tab bytes
- if JSON contains `txpk_ack.error`:
  - treat missing or `"NONE"` as success
  - treat other values as a downlink error attached to the gateway or device
- remove the pending token from state

### Error tolerance

UDP listener must stay alive on:

- malformed JSON
- unsupported JSON members
- unknown packet types
- unknown tokens in `TX_ACK`

These cases must be observable through logging or counters.

## 2. HTTP server

### Listen behavior

Implement a plain HTTP listener first.

Required default:

- port `8080`
- bind `0.0.0.0`

Configuration should reserve room for future HTTPS parity, but TLS redirect behavior is not required for the first migration cut.

### Authentication

The migrated HTTP implementation must support the behavior used by `bumblebee_admin.erl`:

- HTTP Basic authentication
- admin credential fallback from static config
- method-aware authorization split between read and write routes
- unauthenticated `OPTIONS` preflight handling

Digest auth exists in Erlang, but it is optional for the first Zig migration. The spec requires Basic auth first because it is simpler and enough for initial parity on embedded deployments.

### Route surface

Do not migrate the entire Bumblebee admin plane.

Implement only the HTTP routes required for LoRaWAN server administration of the migrated scope:

- `GET /healthz`
- `GET /router-info/:mac`
- `GET /api/config/[:name]`
- `PUT /api/config/:name`
- `GET /api/gateways/[:mac]`
- `POST /api/gateways`
- `PUT /api/gateways/:mac`
- `DELETE /api/gateways/:mac`
- `GET /api/networks/[:name]`
- `POST /api/networks`
- `PUT /api/networks/:name`
- `DELETE /api/networks/:name`
- `GET /api/devices/[:deveui]`
- `POST /api/devices`
- `PUT /api/devices/:deveui`
- `DELETE /api/devices/:deveui`
- `GET /api/nodes/[:devaddr]`
- `POST /api/nodes`
- `PUT /api/nodes/:devaddr`
- `DELETE /api/nodes/:devaddr`
- `GET /api/events/[:evid]`

Rationale:

- `config`, `gateways`, and `networks` are required to make the UDP side meaningful
- `devices` and `nodes` are the minimal LoRaWAN entities needed to ingest and later route uplinks/downlinks
- `events` gives a minimal operational/debugging surface
- `router-info/:mac` is part of the server-facing contract already present in the Erlang routing table, even though Basic Station itself is out of scope

Routes outside this list stay unimplemented for now and should return `404`.

### Authorization model

Preserve the existing scope names so data and clients do not need renaming:

- `unlimited`
- `web-admin`
- `server:read`
- `server:write`
- `network:read`
- `network:write`
- `gateway:link`
- `device:read`
- `device:write`
- `device:send`
- `backend:read`
- `backend:write`

Initial route requirements:

- config routes: `server:read` / `server:write`
- gateway + network routes: `network:read` / `network:write`
- device + node + event routes: `device:read` / `device:write`
- `router-info/:mac`: unauthenticated for now, unless later Basic Station work depends on auth

### HTTP payload and response rules

- request and response bodies use JSON
- `GET` list endpoints return arrays
- `GET` item endpoints return a single JSON object or `404`
- `POST` creates records and returns `201`
- `PUT` updates records and returns `200`
- `DELETE` deletes records and returns `200` or `204`
- malformed JSON returns `400`
- auth failure returns `401`
- permission failure returns `403`
- unknown resource returns `404`
- unique key conflict returns `409`

### Data normalization

The Erlang admin layer converts many fields from hex strings into binaries and back.
The Zig migration should keep the HTTP representation stable and friendly:

- identifiers such as `mac`, `deveui`, `appeui`, `appkey`, `devaddr`, keys, and payload fields are represented as uppercase or lowercase hex strings on the wire
- internal storage can use text or binary, but conversions must be centralized
- validation must reject malformed hex lengths and invalid characters

## Storage model

SQLite is acceptable and already used by the current Zig stub.

Minimum tables required in the first migration:

- `config`
- `users`
- `gateways`
- `networks`
- `devices`
- `nodes`
- `events`
- `gateway_runtime` or equivalent transient/persistent table for last-alive, peer address, and pending downlink state if process memory alone is not sufficient

Recommended split:

- persistent entities in SQLite
- live socket/pending-token state in memory

The implementation does not need to reproduce Mnesia semantics. It does need deterministic CRUD behavior and clear uniqueness constraints:

- `users.name` unique
- `gateways.mac` unique
- `networks.name` unique
- `devices.deveui` unique
- `nodes.devaddr` unique
- `config.name` unique, with `"main"` as the default record

## Internal architecture

Use a structure that keeps the current one-file Zig stub from becoming the final design.

Recommended module split:

- `main.zig` - process bootstrap, config loading, thread startup
- `config.zig` - environment/file config parsing
- `udp_server.zig` - UDP socket loop and Semtech framing
- `udp_packets.zig` - Semtech packet encode/decode and `txpk`/`rxpk` transforms
- `gateway_registry.zig` - live gateway peer state, last alive, pending downlinks
- `http_server.zig` - HTTP listener and request parsing
- `http_auth.zig` - Basic auth and scope checks
- `http_routes.zig` - route dispatch
- `storage.zig` - SQLite connection and migrations
- `repo/*.zig` - CRUD helpers for config/gateway/network/device/node/event
- `lorawan_types.zig` - shared structs for rx/tx queue and identifiers

Concurrency requirements:

- HTTP and UDP listeners run independently
- shared mutable state is synchronized explicitly
- long-running or blocking DB work must not stall the UDP listener

## Configuration

Support these environment variables in the first cut:

- `LORAWAN_SERVER_UDP_PORT` default `1680`
- `LORAWAN_SERVER_HTTP_PORT` default `8080`
- `LORAWAN_SERVER_DB_PATH`
- `LORAWAN_SERVER_ADMIN_USER`
- `LORAWAN_SERVER_ADMIN_PASS`

Future file-backed configuration can be added later, but env-based configuration is enough for initial Buildroot integration.

## Compatibility notes

1. Use the Erlang default UDP port `1680`, not the current Zig stub port `1700`.
2. Keep the Semtech packet framing compatible with `test_forwarder.erl`.
3. Preserve the HTTP entity names and field names where practical so existing tooling and future migration scripts do not need remapping.
4. Basic Station support is deliberately deferred; do not let `router-info/:mac` pull WebSocket/LNS work into this migration.

## Implementation phases

### Phase 1: foundations

- split current `main.zig`
- add config loading
- add SQLite schema and migrations
- add structured logging

### Phase 2: UDP parity

- implement Semtech frame decode/encode
- implement `PUSH_DATA`, `PULL_DATA`, `TX_ACK`
- implement gateway runtime registry
- add UDP-focused tests using fixtures equivalent to `test_forwarder.erl`

### Phase 3: HTTP parity for migrated entities

- implement HTTP server and routing
- add Basic auth and scope checks
- implement CRUD for config/gateway/network/device/node/event
- add API tests

### Phase 4: integration

- connect UDP ingestion to persisted entities
- add downlink enqueue/send path
- add end-to-end tests covering uplink -> runtime state -> downlink ack handling

## Acceptance criteria

The migration is complete when all of the following are true:

1. The server listens on UDP `1680` and HTTP `8080` by default.
2. A Semtech packet forwarder can `PUSH_DATA` and receive `PUSH_ACK`.
3. A Semtech packet forwarder can `PULL_DATA` and receive `PULL_ACK`.
4. The server can emit a valid `PULL_RESP` downlink and consume `TX_ACK`.
5. HTTP CRUD exists for config, gateways, networks, devices, nodes, and events.
6. HTTP Basic auth protects the admin/API routes.
7. Malformed UDP and HTTP requests do not crash the process.
8. The implementation is split into maintainable Zig modules rather than a single monolith.
9. Automated tests cover the Semtech UDP handshake and the migrated HTTP CRUD/auth behavior.

## Missing for LoRaWan 1.0.3 spec

LoRaWAN 1.0.3 Missing Checklist:

- [X] Enforce uplink frame-counter validation and reject replays/duplicates.
Current code reconstructs FCnt and verifies MIC, but still accepts and stores any parsed uplink counter in service.zig (line 151).

- [X] Persist and validate DevNonce for OTAA join replay protection.
Join handling verifies MIC only and does not reject reused DevNonce in service.zig (line 89).

- [X] Make AppNonce generation/state compliant and uniqueness-safe.
It is currently random per join in service.zig (line 96).

- [X] Implement confirmed uplink ACK behavior.
The parser exposes confirmed and ack, but uplinks do not trigger protocol ACK downlinks unless MAC responses happen to exist in service.zig (line 163).

- [X] Implement confirmed downlink tracking/retry semantics.
 Downlinks are sent once and TX_ACK is only used for gateway delivery bookkeeping in udp.zig (line 198).

- [X] Use node RX window settings for actual downlink scheduling.
rxwin_use is stored and partly updated, but downlinks still use uplink frequency/data-rate-derived values in service.zig (line 172).

- [X] Implement proper RX1/RX2 selection logic.
Current logic only emits a single class A delayed downlink and does not choose between RX1 and RX2 based on node/network state.

- [X] Persist channel-plan state on the node.
Node has no storage for channel masks, enabled channels, extra channels, or DL channel mapping in types.zig (line 107).

- [X] Fully apply MAC command answers beyond LinkADRAns and RXParamSetupAns.
Current node updates only handle a narrow subset in mac_handlers.zig (line 102).

- [X] Implement generation policy for network-originated MAC commands.
The server only auto-responds to LinkCheckReq and DeviceTimeReq in mac_handlers.zig (line 65).

- [X] Support sending MAC commands in FRMPayload on FPort=0 when FOpts exceeds 15 bytes.
Outgoing MAC commands are currently limited by FOptsTooLarge in codec.zig (line 195).

- [X] Implement application downlink queueing and payload delivery.
Current downlinks are MAC-only even though the encoder can carry payloads.

- [X] Implement FPending behavior for queued downlinks.
TxData supports pending, but nothing schedules or uses it in a real queue path in types.zig (line 145).

- [X] Implement proper ADR/network control policy.
The code stores ADR-related values and accepts LinkADRAns, but there is no ADR decision engine.

- [X] Improve LinkCheckAns values from placeholders to real link metrics.
`LinkCheckAns.margin` now derives from the current uplink LoRa SNR against the data-rate demodulation floor, and `gateway_count` is sourced through the uplink link-metrics path instead of a hardcoded literal at the MAC handler call site.

- [X] Wire CFList into join-accept when regional setup requires it.
The join-accept encoder supports CFList, but joins always pass null in service.zig (line 103).

- [X] Decide and implement regional constraints explicitly.
Channel commands, RX2 defaults, data-rate meanings, dwell limits, and CFList usage are region-sensitive, but the current implementation is mostly generic.

## Non-goals for this migration

The following should be explicitly refused if they appear during implementation unless the scope is re-opened:

- full admin UI feature parity
- Basic Station WebSocket support
- connector/backends migration
- Prometheus and cluster support
- reproducing Erlang supervision trees exactly
- reproducing every Mnesia table and every admin endpoint

## Middleware

Good middleware to add next to mac_command_logger:

command_validator: reject malformed/unsupported command payloads early
node_context_guard: ensure required node/region/pending state exists before handler runs
ack_correlation: validate *_ans commands match expected pending *_req
metrics_collector: count per-command success/failure/latency
idempotency_or_replay_guard: prevent duplicate processing of repeated uplink command sets
error_mapper: normalize low-level errors into consistent app-level errors/log fields
