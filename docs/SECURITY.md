# Security model and limits

## What this release does—and does not—claim

AACS is newly written, unaudited application code for a Minecraft server. It has automated tests, not a security certification. No honest implementation can promise that ComputerCraft machines, their radio links and a third-party physics/radar stack are "unhackable."

This release aims to reject unauthorized network writes, forgery without the relevant secret, old packets, modified packets and cross-role misuse. It intentionally does not turn uncertain identification into automatic weapon firing.

## Protections implemented

- **Independent endpoint keys.** Each station, kiosk, registrar and beacon shares a different 256-bit secret with HQ. No nationwide shared password is placed aboard every vessel.
- **Encrypted, authenticated payloads.** ChaCha20 encrypts each JSON payload; full-length HMAC-SHA256 authenticates the complete header and ciphertext. Encryption and MAC keys are separately derived for each direction and pair using HMAC with distinct labels. This is an encrypt-then-MAC construction, **not** ChaCha20-Poly1305 and not a formally reviewed protocol.
- **Persistent replay defense.** Sender sequences are reserved in blocks before use. Receiver high-water marks are persisted before a message is delivered to application code. Restarting normally does not reset them. Older out-of-order packets are dropped too; availability is deliberately sacrificed rather than accepting replay.
- **Freshness limits.** Packets more than 30 seconds from the receiver's UTC clock are rejected. Policy expiry and permits use UTC wall time, not Minecraft daylight.
- **Pinned peers and scope.** Peer identity/role/computer ID come from a provisioned local configuration, not packet claims. A computer-ID match alone is not authentication. Stations cannot register themselves, grant clearances or change national policy.
- **Public registration is pending-only.** Application details are assertions, not verified ownership. A kiosk can submit or check its own receipts; a protected registrar can approve records but cannot grant zone access or modify infrastructure.
- **No remote code execution facility.** The protocol accepts a bounded set of data messages. There is no remote shell, `eval`, downloaded updater, received Lua chunk or command-dispatch-to-shell feature.
- **Bounded inputs.** Packet lengths, JSON payloads, operation strings, field lengths, batch sizes, record counts and cryptographic processing rates have limits.
- **Explicit revocation.** HQ can disable an individual peer. The revocation persists. Other endpoints have different keys.
- **Startup hardening.** AACS saves `shell.allow_disk_startup=false`. This reduces accidental/malicious disk startup, but is not an access-control boundary against someone who can already operate or modify the computer.
- **Corruption checks.** Structured state has SHA-256 checksums and temporary/backup replacement. Interrupted or corrupt state is refused rather than silently reset. These are corruption checks, not protection from a person who can rewrite the disk.

The cipher and MAC implementations are checked against public RFC test vectors. This catches implementation errors covered by those vectors; it does **not** prove the whole protocol secure.

## Trust boundaries

### Protect the computer and the world

Anyone who can read `/aacs/config.json` can steal that node's secret. Anyone who can edit the running program can bypass its checks. ComputerCraft has no OS privilege separation here. Staff-only machines must be protected by server-enforced claims/access restrictions that actually block interaction, breaking, disk access, turtles, wired-modem attachment and alternate access routes in your modpack.

Treat HQ as the most sensitive computer: it holds every peer key and the central registry. Protect registrar and station machines too. A compromised station can falsify its own sensor reports. Pairwise credentials restrict that compromise; they cannot make a dishonest sensor truthful.

A public kiosk is deliberately low privilege. An attacker controlling it may submit junk applications, inspect that kiosk's receipts or jam its link. They cannot become a registrar merely by changing the `role` field in an outbound message. A compromised registrar, however, can approve registrations because that is its assigned privilege.

Server operators, filesystem administrators, backups and sufficiently powerful mods remain trusted. AACS does not defend against an administrator modifying the world or CC storage.

### Physical vessel identity is not cryptography alone

An onboard computer owner can change its Lua and claim any callsign, position or UUID. A valid MAC proves possession of a particular key, **not** that the computer is physically on the advertised vessel.

Accordingly:

- Beacon claims are logged as claims and never become sensor observations.
- Beacons cannot create/modify radar bindings or clearances.
- Radar identity binding is a protected HQ operation performed on a fresh observed contact after physical inspection.
- Bindings expire after their chosen lifetime, up to 365 real days, and are tied to a specific sensor namespace and track ID. A longer lifetime does not make a recycled or changed track ID trustworthy; inspect and remove obsolete bindings when a vessel's physical identity changes.
- Player identity comes from a trusted Player Detector's UUID field, not a typed username.
- Detecting a nearby player does not establish who owns/pilots a nearby radar track.

If the radar's reported ID itself is spoofable, recycled or unstable, the Lua registry cannot fix that. A truly tamper-resistant link between a registry entry and a physics object needs verified server-side mod support. That is the specific remaining case where a small companion mod could be justified.

### What can still go wrong

**Radio jamming / denial of service:** authentication does not stop flooding, event-queue exhaustion, packet loss, chunk unloading or destruction of equipment. Rate limits bound AACS's own processing; they cannot guarantee delivery under attack. A spoofed sender can also consume a pinned peer's receive budget. Wired protected infrastructure reduces exposure but is not magic.

**Confidentiality:** payloads are encrypted in transit. Node names, timing, message lengths and routing are visible. Database files, private configs, reports and local logs are **not encrypted at rest**. Anyone with filesystem access can read them. No forward secrecy is provided: compromise of a key can expose past captured traffic for that link.

**Key compromise / replay-state rollback:** restoring an old computer image with the same keys can reuse ChaCha nonces or replay counters. Never clone a live credential or roll back transport state while retaining keys. Re-provision fresh keys/realm after a security-state rollback. See RECOVERY.md.

**Incorrect sensors:** fresh timestamps do not prove that a mod's data is correct. A radar bug could report a ghost contact with advancing timestamps. Fixed coordinate bounds and first-token warm-up only catch some classes of failure.

**Log tampering:** logs are not a tamper-proof ledger. A local attacker can alter/delete them. Checksummed state is not evidence against someone who possesses the disk. Archive important reports in protected server backups; use a separate audited logging service if independently verifiable records become necessary.

**Software defects:** tests do not cover all paths, hardware configurations or adversarial conditions. This release should be reviewed and exercised in your actual pack before being treated as a national enforcement system.

## Weapon-control boundary

There are **no** `fireOn()`, `keepFiring()`, target-selection, ballistic or automatic engagement calls in production code. Redstone outputs mean `alarm` and `fault`, nothing more. A stale cached policy can continue producing an informational alarm; it must never be interpreted as a firing authorization.

A future cannon adapter would need verified per-target selection, identity stability, independent expiry/watchdog behavior, manual arm/disarm, loaded-chunk testing and handling for target changes between checking and firing. A global redstone "there is an intruder" signal is not sufficient: an autonomous turret could be aimed at a different, friendly contact.

## Key handling checklist

Keep the deployment output private. Distribute each machine's folder only to that machine. Do not share config files in support requests. Do not reuse beacon keys for stations. Do not overwrite live `transport.json` during a code update. Revoke a stolen computer immediately. Re-key after restoring old security state. Disable disk startup and verify physical protections rather than relying on a fullscreen menu.

## Pilot chat boundary (0.2.0-beta.1)

A station relays the actual `chat` event username/UUID over its authenticated HQ link. HQ checks a local-admin-created, unexpired UUID-to-vessel pilot approval before creating a live check-in session. Neither a typed ship UUID nor the registration number grants a pilot association or zone permit. No chat command executes Lua, edits a registry, grants clearance or approves another account.

Stations are trusted infrastructure: a compromised station/key can lie about observed chat events, sensor data and send results. Protect their computers and wired peripheral networks. HQ chooses one station to send each registered-vessel notice; the receiving station accepts sends only through its pinned HQ link. Message queues, command budgets, retries and notice lifetimes are bounded. Physical computer access, malicious mods/admins, queue flooding and network jamming remain outside the protocol's protection.

Pilot sessions last at most two real hours and require check-in after HQ restart. Authorizations persist until expiry/revocation. Revocation prevents new HQ routing on its next update and requests cancellation of pending vessel notices. A previously dispatched station notice may remain until its 20-second expiry when cancellation cannot reach the station. Chat is not a guaranteed or confidential channel against a server operator or other mods. Public hails deliberately disclose the hail text and approximate contact location to public chat; enable them only when wanted.
