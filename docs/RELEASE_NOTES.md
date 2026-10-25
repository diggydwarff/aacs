# 0.2.3-beta.1 — adaptive display columns

- Give ARD registrations their own **ARD ID** column on the live station and HQ tables.
- Let the ship-name column use remaining screen width instead of a fixed 23-character combined label.
- Keep complete registration numbers and coordinate values aligned in their own columns.
- Recalculate the layout each frame so monitor resizing takes effect immediately.
- Mark shortened names with an ellipsis and use a compact identity/status table on small screens.
- Preserve the existing 365-day binding limit and all saved vessel/configuration data.

# 0.2.2-beta.1 — year-long ship bindings

- Raise the HQ-enforced binding maximum from seven days to 525,600 real minutes (365 days).
- Default new bindings and renewals to one year; explain real-time units in the HQ prompt.
- Keep existing expiry timestamps, registrations, network keys and configuration during a code update.
- Preserve expiry, immediate manual unbinding, reassignment checks and idempotent renewal behavior.
- Add regression cases for duration boundaries, persistence, renewal, expiry and unrelated permission limits.
- Update setup and upgrade guides for a code-only update while Minecraft stays online.

Existing bindings are not automatically extended. Renew a binding through HQ menu 5 using the same observed ship and registration. Pilot approvals and zone permits retain their separate limits.

# 0.2.1-beta.1 — pre-deployment review

- Fix newer Advanced Peripherals chat-event argument order; reject events without a real player UUID.
- Cancel superseded queued warnings across station handoffs and on pilot checkout/approval expiry/revocation.
- Clear old queues on HQ reconnect; use persisted wire sequence numbers for notice ordering across restarts.
- Let critical warnings displace lower-priority routine queue entries.
- Refresh expired/changed physical bindings without a fresh scan; preserve the last contact on rejection of an older observation.
- Distinguish identity changes from contact loss and preserve communication for an approved pilot flying a suspended registration.
- Keep recent acknowledgement IDs when renewing a check-in.
- Include pilot messages/account fields/acknowledgement IDs in exported reports.
- Reject policy growth above transfer capacity before committing and fail safely on an oversized imported policy.
- Tighten deployment/update path checks and clean up failed staging folders.
- Update all setup guides and provide repeatable capacity/signed-network scenario checks.

150 Lua checks and 9 host deployment tests passed. Capacity checks, exact-source installer checks and a 180-step signed-network simulation passed. The simulation used 6 vessels, 2 stations, 786 signed packets, 184 accepted chat messages, 7 cross-station cancellations and 10 replay rejections. This remains fixture testing, not a live Minecraft/peripheral or independent security audit.

# 0.2.0-beta.1 — station Chat Box communication

- Each station can use its own named Advanced Peripherals Chat Box.
- HQ coordinates private vessel notices and suppresses duplicate command relays across stations.
- HQ-approved pilot account associations, check-in/out and two-hour sessions.
- Zone lists/geometry/altitude/rules, status queries, boundary notices, clearance changes and repeated violation warnings.
- Warning acknowledgements, pilot messages, HQ inbox and controller replies.
- Optional public hails with global rate limiting; private targeting never guesses a pilot from proximity.
- Bounded cooldown-aware queues, retries, duplicate suppression, notice expiry and Chat Box diagnostics.
- Fresh-install executable ZIP with complete backups and code-only upgrade mode.
- Rewritten README and fresh setup, station, pilot and upgrade guides.
- Includes earlier Sable track acceptance, named contacts, numbered contact selection and monitor reconnection/heartbeat changes.

Automated validation: 132 Lua checks, seven host deployment tests, exact-source installer verification and executable-ZIP deployment/update/reset checks. No live Minecraft or real Chat Box validation was available during this update. See TEST_RESULTS.txt.

# 0.1.0-test

Initial testing package: national HQ, regional radar/player stations, public ADOT applications, protected registrar, optional credential beacon, four 3D airspace classes, expiring permits, manual physical-contact binding, movement/incident/visit reports and CC printer output.

Includes pairwise encrypted/authenticated links, persistent replay counters, role-limited messages, locally generated keys, in-game setup/diagnostics, offline installer, deployment tool, recovery guide and test suite.

Validation: 79 automated Lua checks passed; all packaged Lua parsed; offline install/update and six-node provisioning were exercised in isolated host-side tests. These were not tests inside Minecraft. Exact output is in TEST_RESULTS.txt.

No automatic weapon firing, independent security audit, server-side physical IFF attestation, live key enrollment, redundant HQ or automatic outage-history backfill is included. Peripheral compatibility, performance and physical access protection require in-world commissioning.


## Radar compatibility hotfix — 2026-10-23

- Accept Create: Radars tracks reported as category `SABLE` with entity type `Sable:ship`.
- Keep players, mobs and Create contraptions separate from vessel tracks.
- Retain scan-token warm-up, freshness checks, coverage limits and manual identity binding.
- Request detailed Advanced Peripherals `getPlayer` results so dimension validation has the required field.
- Preserve returned peripheral error messages and include configured sensor errors in diagnostics.
- Label the optional onboard-beacon check separately; a ground computer need not be on a Sable sublevel.
- Code-only upgrades preserve configuration, registry, credentials and transport counters.

Validation: 86 standalone tests passed. New cases cover the reported Sable track format, mixed contacts, expiry, coverage, detailed player data and diagnostic error output. Live testing in the user's modpack remains required.


## Contact list and binding update — 2026-10-23

- Page live contacts to fit a standard computer terminal; N/P changes pages, R refreshes, and S shows stations.
- Select a numbered vessel directly when binding; no sensor-key transcription is required.
- Keep numbering stable until an explicit refresh while sensor updates continue in the background.
- Recheck contact freshness after the registration form is completed.
- Show registered vessel names on HQ and station displays and in contact lists.
- Include a Python-runnable archive updater that stages the in-game installer on selected computers. It preserves private configuration and transport state.

Validation: 95 tests passed, including paging, concurrent updates, stale contacts, cancellation, full-key details and binding the selected ship.


## Monitor recovery update — 2026-10-23

- Retry the configured monitor on every display frame instead of looking it up only once at startup.
- Recover from late attachment, removal, replacement and monitor write errors.
- Refresh the monitor terminal surface on connection while restoring its original text scale.
- Show the writing computer, configured monitor, current UTC update time and frame counter.
- Show an explicit monitor-offline status on the station terminal.
- Save monitor write health to /aacs/data/monitor-status.json and include it in diagnose.
- Keep the configured monitor target; do not fall back to another connected display.

Validation: 103 tests passed, including late monitor connection, reconnection, write failure recovery, text-scale restoration, advancing frames with static contacts, matching vessel names on both displays, and continued radar reports during display recovery.
