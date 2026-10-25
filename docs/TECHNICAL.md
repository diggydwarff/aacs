# Implementation reference

## Program layout

`start.lua` dispatches setup, diagnostics, runtime, tests, demo, reporting and printing. `app.lua` runs the per-role event loops. `service.lua` is the HQ-only write authority; `policy.lua` decides zone membership/clearance; `tracker.lua` merges observations and emits events. `sensors.lua` is the replaceable peripheral boundary. `wire.lua` and `crypto.lua` implement the private links; `store.lua` manages persistent state/logs. `ui.lua` provides terminal menus and optional monitor lists. `reports.lua` exports/prints retained history.

No external Lua dependency, HTTP updater, Minecraft command block, companion mod or general remote execution interface is required. CC: Sable is optional and used only by the non-authoritative onboard beacon.

## Roles and authority

| Role | Authority |
|---|---|
| HQ local operator | Registrations, zones, binding, permits, statuses, revocations, reports and national view. |
| Station | Submit bounded sensor observations; request read-only policy; relay pilot chat and send HQ-directed notices. Cannot edit national records. |
| Public kiosk | Submit pending applications and inspect receipts from that kiosk. No person-level privacy within a shared kiosk. |
| Registrar | Review applications, approve/reject/directly register vessels and list vessel records. No policy/binding/peer control. |
| Beacon | Send credential-associated self-claims and receive acknowledgements/warnings. Cannot report trusted observations. |

The role is pinned at HQ. Changing a packet field or the client menu does not change that authority. There is no local login boundary: anyone with access to a privileged computer's filesystem/operator console is trusted as that machine. Protect it in the world.

## Identifiers

- `ARD-0001`: a national registration, created by HQ; it is not a physical ship UUID.
- `APP-000001`: a pending application receipt. An owner username/claimed UUID is an assertion until staff verify it.
- `player:<UUID>`: a player subject from a trusted detector. UUIDs are normalized to lowercase.
- `ship:<namespace>:<radar-id>`: a raw sensor identity. Default namespaces are distinct per station.
- `vessel:ARD-0001`: a registered subject after a valid manual radar binding.
- `PER-000001`: a zone-specific, time-limited permission.

Binding multiple independently verified sensor keys to one registration merges that vessel's national track. Unknown contacts in different namespaces remain separate rather than being guessed to be the same craft by proximity. Multiple radar peripherals on one station share that station namespace; use this only when their IDs mean the same physical objects. Otherwise use separate station computers/namespaces.

## Data and files

All paths are on the computer, not your desktop:

| File | Meaning |
|---|---|
| `/aacs/config.json` | Node identity, pinned peers, private pairwise keys, peripherals and limits. |
| `/aacs/data/transport.json` | Realm/node, reserved sending high-water mark and per-peer receive high-water marks. Required; never reset with the same keys. |
| `/aacs/data/database.json` | HQ registry, zones, bindings, permits, applications, peer revocations, beacon assignments and bounded request receipts. |
| `/aacs/data/policy.json` | Station's last complete authenticated policy with an expiry. |
| `/aacs/data/pending-request.json` | Terminal's unresolved operation for retry without a new request ID. |
| `/aacs/data/events.jsonl` | Sampled positions and events, plus numbered rotated segments. |
| `/aacs/data/audit.jsonl` | Bounded HQ mutation audit records. Not an immutable ledger. |
| `/aacs/data/reports/` | Saved summaries and CSV exports; manually archive/remove when needed. |

Structured state files contain a JSON payload string and SHA-256 checksum. Replacement uses `.new` and `.bak`; ambiguous/corrupt state causes a stop instead of an automatic rollback. Config is plain JSON and is changed only while the program is stopped. Source-code upgrades must preserve private config and all data.

## Configuration

Provisioning writes the sensitive parts. Use the in-game setup for station peripherals rather than inventing their names. Common editable values are:

| Setting | Default / purpose |
|---|---|
| `dimension` | `minecraft:overworld`; valid resource IDs may contain a path. Must match HQ's station peer entry. |
| `modems` | Empty list discovers modem-capable peripherals; set explicit names to limit which interfaces open. |
| `monitor` | Empty = none; otherwise a reachable monitor peripheral. |
| `radars` | Explicit peripheral names exposing `getTracks()`. |
| `namespace` | `radar-<node>` on stations; must match the pinned HQ peer namespace. |
| `playerDetector` | Empty or a peripheral exposing `getPlayersInRange()` and `getPlayer()`/`getPlayerPos()`. |
| `playerRange` | 128 blocks, also limited by actual peripheral/server configuration. |
| `coverage` | Ground station `{x,y,z,radius}` sanity sphere for radar positions. |
| `scanSeconds` | 2; increase for load testing rather than assuming tick-rate scans are necessary. |
| `radarFreshMs` | 15000; unchanged radar scan token expires. |
| `alarmSide`, `faultSide` | Empty disables output. Different sides; lamps/sirens only. |
| `logBytes`, `logSegments` | 49152 bytes, 3 old segments plus the live event log. |

HQ peer definitions pin `computer`, `role`, `key`, `namespace`, `dimension` and optional `coverage`. A station cannot redefine these trust boundaries in its observation message. Provisioner `inventory.json` lists computers/roles but no keys; the generated node folders contain secrets.

## Zone shape

A box includes `minX/maxX`, `minZ/maxZ`, `minY/maxY`. A vertical cylinder includes center `x/z`, horizontal `radius` and `minY/maxY`. Both include `id`, `name`, `dimension`, `class`, `applies` (`ships`, `players`, `both`) and `enabled`.

Bounds are inclusive. Every applicable overlapping restriction must be satisfied. Unrestricted means log-only. Controlled requires active registration. Restricted/prohibited require active registration plus a current permit for that exact zone; prohibited has higher alert severity. Outside configured zones is unregulated. There are no implicit nation-wide passes based on a typed nation, aircraft name or beacon assertion.

`examples/zones.json` contains illustrative shapes only. Enter them through HQ's zone menu; no automatic JSON importer is included in this release.

## Peripheral normalization

Create: Radars tracks must provide usable `id`, `position` and numeric `scannedTime`. Its time unit is not assumed to be UTC: AACS watches token changes and stamps them with local UTC. The first cached token is not accepted until it changes. SABLE / Sable:ship and legacy untyped ship tracks are accepted; radar players, generic entities and contraptions are skipped. The adapter does not trust radar velocity units or use radar `getPosition()` to establish the station's location.

Player Detector observations use range lookup followed by `getPlayer()` when present or `getPlayerPos()` otherwise. Missing UUIDs are rejected; usernames alone do not authorize access. Dimension must match station configuration.

A future radar adapter should emit `{kind,id,namespace,dimension,x,y,z,time,source}` with validated world coordinates and a genuinely fresh observation time. Do not turn self-reported radio coordinates into trusted observations. Every new adapter requires identity/freshness testing.

## Network protocol

Rednet protocol: `aacs.secure.v1`. Packet format:

```text
AACS1|realm|from|to|sequence|utcMilliseconds|ciphertextHex|hmacHex
```

Every endpoint shares a different OS-generated 32-byte key with HQ. HMAC-SHA256 derives separate direction-specific encryption/MAC keys using realm and endpoints. ChaCha20 encrypts JSON; HMAC-SHA256 authenticates the complete header and ciphertext before decryption. The 96-bit nonce encodes the monotonically increasing sequence. A node reserves 128 sequence numbers durably before using them; reboot skips unused reserved numbers. Receivers persist a high-water mark before delivering a valid message to the application.

This is a custom encrypt-then-MAC protocol, not ChaCha20-Poly1305, TLS or a security-reviewed standard deployment. See SECURITY.md for its actual threat model and limits. In particular, never restore old counters while retaining keys.

Application messages: `observations` and `sync` (station), `rpc`/`reply` (registration), `policy_part` (HQ), `beacon`/`beacon_ack` (beacon/HQ). Unknown roles/operations cannot execute arbitrary Lua. Replies use the same authenticated pairwise link. Public/registrar RPCs persist one pending request, retry three times and retain its operation ID after an unacknowledged outcome.

HQ sends policies as digest-checked 4,000-character chunks; only complete, valid snapshots apply. Policy lease is 60 real seconds; refresh requests are every 20 seconds. Large snapshots take multiple timer cycles. No hard real-time latency is promised. Freshness windows use `os.epoch("utc")`; server clock jumps can temporarily disrupt delivery/expiry.

## Bounds and scaling

Testing-release caps: 32 peers, 256 vessel records, 256 player records, 64 zones, 512 permits, 128 retained applications and 512 live contacts per tracker. Stations emit up to 128 observations per scan in batches of 24. Position samples log every 10 seconds; contact expiry is 20 seconds. Estimated segment crossings use consecutive observations at most 10 seconds apart, not predicted future paths.

Maximum packet size is 25,000 bytes, plaintext 12,000 bytes. Receive crypto budgets are 20 attempts per pinned peer and 80 globally per real second. Policy snapshots are at most 256,000 characters in up to 64 chunks. Increasing every cap without profiling can exceed ComputerCraft storage/CPU/network budgets. HQ is a single authority, not a redundant cluster.

High traffic can exceed these budgets; fewer stations/contacts and slower scans may be necessary. Unloaded computers do not operate. Network gaps are not automatically filled from station logs. This release has no map editor, remote enrollment service, automatic history synchronization, weapon adapter, target acquisition or ballistic solver.

## Station chat protocol (0.2.0-beta.1)

Station observations include bounded Chat Box readiness/public-hail capability. Trusted stations relay `pilot_chat` with the server-event account UUID/name, command and timestamp. HQ routes `chat_notice` with a unique ID, optional recipient, priority, expiry and replacement thread. Stations send `chat_result` after API acceptance or final failure; only a matching sending station can complete a pending dispatch. These operations travel inside the existing pairwise protected wire format.

HQ owns approvals (`database.pilots`), ephemeral two-hour check-ins, national contact-state summaries and command deduplication. Sensor bindings to one registration merge contact identity across stations. The default namespace intentionally keeps unbound opaque tracks separate. Chat notices are derived from HQ's merged current contacts and current registry, not from independent station alarm messages.

Limits: HQ notice queue 128; pending sends 64; up to four dispatches per one-second update; station queue 32; station deduplication cache 128; command relay maximum four per second per station and one per account per two seconds; HQ command deduplication suppresses repeated identical relays within three seconds. Each Chat Box sends no faster than once per 1.5 seconds by default and retries failed calls at most three times. All notices expire after 20 seconds; public violation hails are additionally globally limited to one per 30 seconds. New unsent summaries replace older summaries for the same contact/recipient. Queue overloads and outages can lose notices; no durable-delivery guarantee is made.

Configure a station's `chatBox` exact peripheral name, `chatPublicHails` boolean and `chatIntervalSeconds` (1–30). The public-hail switch also gates manual public controller broadcasts from that station. Private notices do not require the public switch. Diagnostics expose peripheral/readiness/queue/error/sent-count fields without peer keys.

## Review fixes in 0.2.1

`chat_cancel` invalidates a dispatched queued notice by ID, including a bounded tombstone if cancellation arrives before the notice. A newer contact summary cancels outstanding summaries at any previous sending station. Checkout/expiry/revocation cancels pending vessel messages for that pilot. `chat_reset` clears prior queues when HQ observes a fresh Chat Box connection; already sent messages cannot be recalled. Driver notice versions are taken from the authenticated wire sequence, which persists across HQ restart.

Full queues admit a higher-priority notice by displacing their lowest-priority routine item; they still drop notices under overload. Snapshot growth above 256,000 bytes is rejected before a database change is committed, while reductions of an already oversized imported snapshot remain possible. HQ reports an unavailable policy instead of crashing if an old database is over the transfer limit; the receiving station marks its cache stale.

Tracker refresh reclassifies bindings that changed/expired even without a new radar sample. An older incoming observation cannot delete the previous alias before rejection. Report CSVs append message ID, pilot UUID, username, station and message fields after the original columns.
