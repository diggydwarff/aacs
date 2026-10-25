# AACS — Ardennian Airspace Control System

**0.2.3-beta.1 · ComputerCraft / CC:Tweaked · Minecraft NeoForge 1.21.1 target**

AACS connects a central HQ to radar stations. Each station can have its own Advanced Peripherals Chat Box for pilot communication. HQ keeps the vessel registry, pilot approvals, airspace zones and temporary clearances.

**Start with [QUICKSTART.md](QUICKSTART.md).** It includes exact fresh-install commands for HQ **112** and Capital station **108**, with Minecraft kept online. Shut down the affected ComputerCraft computers before a fresh install.

## Included

- Create: Radars ship tracking, including `SABLE` / `Sable:ship` contacts.
- Optional Player Detector tracking, separate from vessel identification.
- HQ registration and numbered radar-to-vessel binding for up to 365 real days.
- A Chat Box on each station; private pilot messages coordinated by HQ.
- Pilot check-in approved through HQ using the actual chat-event account UUID.
- Zone information, entry/exit notices, clearance changes and warnings repeated every 30 seconds while a violation remains observed.
- Pilot acknowledgements and two-way controller messages.
- Optional public hails for vessels without a checked-in pilot; disabled by default.
- Four airspace classes, altitude limits, cumulative overlapping rules and temporary permits.
- Live terminal/monitor views with separate ship-name and ARD-ID columns, names sized to the screen width, and a changing monitor clock and frame counter.
- Authenticated, encrypted station/HQ links with persisted replay protection.
- Bounded logs, CSV movement/visit exports and printable reports.
- Fresh deployment, backups, code-only updates, diagnostics and automatic tests.

## Read these

| File | Purpose |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | Fresh setup from the beginning; exact server/Windows commands. |
| [docs/STATION_SETUP.md](docs/STATION_SETUP.md) | Radar, modem, monitor and Chat Box wiring; repeat for each station. |
| [docs/PILOT_GUIDE.md](docs/PILOT_GUIDE.md) | Pilot chat commands and controller approval workflow. |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Registration, permissions, daily use and reports. |
| [docs/UPGRADING.md](docs/UPGRADING.md) | Preserve the current registry instead of starting over. |
| [docs/SECURITY.md](docs/SECURITY.md) | Trust assumptions and actual security limits. |
| [docs/TEST_RESULTS.txt](docs/TEST_RESULTS.txt) | Automated validation and remaining live checks. |

## Important behavior

Radar identifies an observed ship, not its driver. A controller must bind the physical radar contact to its registration and approve the pilot's account. A pilot then checks in. Owning a vessel, typing its UUID or transmitting a name does not automatically authorize it.

Unrestricted zones are open. Controlled zones require an active identified registration. Restricted and prohibited zones require an active registration and an explicit current zone permit. Acknowledging a warning never grants clearance.

Registered contacts bound to the same registration at multiple stations receive one national set of notices. Unknown tracks remain station-scoped; their IDs are not assumed to identify the same vessel across radars. Public hails have an additional global 30-second rate limit.

Automatic pilot notices require a working HQ link and a current sending station. There is no offline national chat fallback. A station continues local observation/logging during an HQ outage, clearly marks its policy stale after 60 seconds, and expires queued notices rather than replaying an outage backlog.

A Chat Box reporting success means its send API accepted the message. It does not prove a pilot read it; pilots can acknowledge warnings separately. Server Chat Box range, permission and cooldown settings still apply.

No automatic weapon control is included. Use alarm outputs for lamps or sirens.

This is a test release. The supplied Lua/host tests use fixtures, not a running Minecraft server; live testing in your modpack is still required. No live keys or private deployments are included in this ZIP.

## Display update 0.2.3

The live table separates vessel names from their ARD registrations. Names expand to use larger monitor widths; only names that exceed the available column width are shortened with an ellipsis. Coordinate columns retain complete values, and small screens fall back to a compact identity/status table. Resizing a monitor takes effect on the next frame.

Use [docs/UPGRADING.md](docs/UPGRADING.md) to update code while preserving registrations, bindings and settings.

## Binding update 0.2.2

Ship bindings now accept 1–525,600 real minutes, with 365 days as the default. Press Enter at the binding-duration prompt for a full year, or enter a shorter whole-minute duration. Expiry uses real UTC time, including time while the computer is off.

Use [docs/UPGRADING.md](docs/UPGRADING.md) to update without stopping Minecraft or resetting your registry. Existing bindings retain their current expiry; select the same observed ship and registration under HQ menu 5 to renew one. Pilot approvals and zone permits keep their separate limits.

## Reviewed build 0.2.1

This build handles both AP chat-event orders, cancels superseded pending notices across stations, and resets old station queues when HQ reconnects. Wire sequence numbers keep notice ordering valid across HQ restarts. Critical warnings can displace routine messages from a full queue.

Expired/changed radar bindings are reflected without waiting for a new scan, and reclassification is distinguished from radar contact loss. An approved pilot can still receive warnings if their vessel registration is suspended; the suspension continues to deny access. Message reports retain chat text, account fields and acknowledgement IDs. Install/update tools reject unsafe symlinks and unexpected startup/settings path types.
