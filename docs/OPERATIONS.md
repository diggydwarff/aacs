# Operating AACS

## National registry workflow

1. A citizen or foreign operator submits an application at a public kiosk and receives an `APP-...` receipt.
2. ADOT checks the supplied vessel/owner details in game. Typed ownership, nation and UUID fields are not authentication.
3. HQ or a protected registrar approves the application, assigning an `ARD-...` number. Repeating the same approval returns the existing registration.
4. An HQ operator observes the physical craft at a known station, confirms which track belongs to it and binds that exact sensor key to the ARD registration.
5. Issue zone-specific, time-limited permits where needed. Civilian/citizen/nation labels alone do not grant restricted access.

Each vessel's registration is central. Radar bindings are station-scoped by default. This is intentional: two stations reporting the string `42` might not be referring to the same physical object. An operator can bind separately verified contacts to the same ARD registration. Their national histories then merge under that registered subject. Unknown tracks are not guessed together based on proximity.

Binding lifetimes accept 1–525,600 real minutes, defaulting to the maximum of 365 days. Deadlines use UTC and continue while HQ is offline. Existing bindings retain their original expiry on upgrade; selecting the same observed ship and registration under HQ menu 5 renews the deadline from the current time. Manual unbinding still removes a year-long binding immediately. Pilot approvals and zone permits have their own shorter limits.

On rebuilding, splitting, reassembling, transferring ownership or changing physical identity, inspect the craft again. Remove old bindings and retire/re-register a vessel when appropriate. This version's menu has registration and status changes, not a full ownership-transfer editor.

## Roles

**HQ console:** full local national administration. Protect physical access. There is no remotely invokable national-admin role.

**Registrar:** may list vessels/applications and submit, create, approve or reject registrations. No zone, permit, binding or peer-administration rights. Its terminal is staff-only.

**Kiosk:** applications and own-receipt status only. A kiosk does not automatically issue a transponder or copy secret keys to applicants.

**Station:** observations, policy synchronization, authenticated pilot-chat relay and HQ-directed Chat Box sends. It cannot write the national registry, approve pilots or grant permits.

**Beacon:** credential/claimed UUID reporting and acknowledgement/warnings only. Its key is tied to its node, not trusted physical location.

## Player registration

Use the Player Detector observation to obtain the actual Minecraft UUID, then register that UUID at HQ. Usernames are display information and can change. Player-only zones require a deliberate `players` or `both` scope; ordinary aircraft zones default to `ships`.

A player standing near a craft is not automatically its owner or pilot. AACS makes no player-to-ship occupancy inference.

## Four zone classes

- **Unrestricted:** logging without an access requirement.
- **Controlled:** an active identified registration is sufficient.
- **Restricted:** active registration plus an unexpired permit for that exact zone.
- **Prohibited:** the same explicit-permit rule, with the highest alert severity. This accommodates exceptional government-approved access without silently treating all military/citizen craft as authorized.

Zone coordinates are world coordinates. Boxes use inclusive min/max X/Y/Z. Cylinders use X/Z center, horizontal radius and inclusive Y bounds. Dimension IDs are explicit. Outside configured zones, contacts are still logged but are not in violation of a configured airspace rule.

Overlaps are cumulative. A valid permit for one Prohibited zone does not waive an overlapping Restricted zone. Suspended/hostile/retired records cannot use permits to regain access. Unrestricted space remains open even to an identified hostile record; "hostile" is an administrative registry status, not a global shoot-on-sight command.

Permits use real UTC minutes. Changing Minecraft time does not extend them. Revocation changes the database immediately at HQ; a disconnected station cannot know a new revocation until it reconnects. Its policy becomes explicitly stale after the current 60-second lease.

## Station operation

A station reads its configured sensors about every two seconds by default, logs a position about every ten seconds per contact, and logs important changes separately. Radar data must supply a valid ID, position and `scannedTime` token. After startup or a track's disappearance/reappearance, a changed token is required before the track is accepted. A stuck token ages out.

SABLE / Sable:ship radar contacts and legacy untyped ship entries are accepted; radar player/entity/contraption entries are skipped. Player tracking uses the dedicated Player Detector. Test what your radar supplies for Sable craft. An empty successful `getTracks()` response proves only that the API call worked—not that the radar is functioning or that the airspace is clear.

A station caches the last complete authenticated policy snapshot. Missing parts are not applied. With HQ offline, it keeps observing and writing local events and labels its rules stale. It does **not** collect an unlimited upload queue, and HQ does not automatically ingest the outage gap later. Local station reports are the fallback evidence.

`Q` stops a station or beacon. Use the HQ/registration menu's Exit command on those roles. Do not run another copy from a second multishell tab.

## Alerts and warnings

The local alarm output goes high when a current tracked contact violates the locally available zone rules. The separate fault output indicates an expired HQ policy or detected sensor/API errors. A lamp is a good first test load.

The outputs are not safety-rated and not guaranteed to clear on every server crash/unload/power-loss behavior. They do not have a hardware watchdog. **Do not attach them to weapons.** On normal exit/error handling AACS requests both outputs off.

A beacon assigned to a vessel receives a signed-link acknowledgement and may receive a zone warning when the independently observed registered vessel is in violation. Unknown/unregistered craft cannot reliably receive targeted warnings through this mechanism. Station Chat Boxes add private pilot notices and optional public hails. See PILOT_GUIDE.md. Public hails are disabled by default and globally limited to one per 30 seconds.

## Reports

HQ Menu 7 creates:

- a complete matching event/position CSV from retained logs;
- a visit CSV pairing observed entries and exits and marking missing coverage;
- a printable summary with event counts and the last 120 matching non-position events.

Use a subject such as `vessel:ARD-0001`, `player:<uuid>`, or an exact `ship:<namespace>:<track-id>`. For a zone-filtered report, only rows explicitly associated with that zone match; movement samples and loss records without a zone may be omitted. Generate an unfiltered subject report for a fuller investigation.

Dates are UTC. Visit duration is the interval between **sampled observations**, not an exact boundary-crossing time. A lost contact is not a confirmed exit or landing. A straight-line estimated crossing between samples is labeled as an estimate. High speed, turning between samples, lag and coverage gaps limit reconstruction.

A station can create reports from its own retained local events using:

```text
/aacs/start.lua report vessel:ARD-0001 24
```

Exported CSV values are quoted; text starting with spreadsheet-formula characters is prefixed to prevent accidental formula execution. Negative numeric fields are consequently also exported as safe text.

For printing:

```text
/aacs/start.lua print /aacs/data/reports/report-YYYYMMDD-HHMMSS.txt
```

If supplies run out, refill and use the stated starting page. If the printer's output tray fills while completing a page, empty it and finish that already-started page with `peripheral.find("printer").endPage()` from the Lua prompt, then resume at the next stated page. Do not start a new job over a page still being printed.

Logs rotate: default event log = current 48 KiB segment plus three archives. Audit logs have their own bounded rotation. Reports do not auto-delete, so periodically copy wanted reports off the computer and free storage. History beyond retained segments is not recoverable from AACS alone.

## Lost registration acknowledgements

The network terminal persists its pending request before sending. It retries automatically up to three times with the same operation ID. If HQ never acknowledges, the screen reports an unknown outcome rather than promising failure.

Choose **R — Retry unacknowledged network request** after connectivity returns. This reuses the saved request ID. HQ keeps a bounded idempotency receipt history; repeated application approval also returns its existing ARD number. Do not repeatedly create fresh applications just because a reply was lost. For an old request beyond the receipt window, check the HQ application/vessel records before retrying or discarding it.

## Station Chat Boxes and pilot communication

Use [PILOT_GUIDE.md](PILOT_GUIDE.md) for the complete workflow. HQ P approves/revokes account-to-vessel associations, C sends controller messages, and M reads the recent pilot-message/acknowledgement inbox. Approvals persist; live check-in sessions do not survive HQ restarts. Stations use the Chat Box event UUID, never a chat-supplied claimed UUID. Readiness, queues and errors are saved locally in `/aacs/data/chat-status.json`.

HQ logs `pilot_checkin`, `pilot_checkout`, `pilot_ack`, `pilot_message`, `chat_sent`, `chat_failed`, `chat_unknown`, `chat_cancelled` and `chat_unroutable`. These are available in retained event/report exports. `chat_sent` records API acceptance, not proof of receipt or reading. The chat message inbox holds the latest 64 entries in this HQ session; rotated event logs have their own retention limits.

A chat cancellation record means cancellation was requested, not proof an earlier message was never delivered. Suspended registrations retain pilot communication under an existing approval so warnings can still reach the pilot; access remains denied. If a binding changes while a radar contact remains visible, the pilot receives an identity-association notice rather than a false contact-lost or exit notice.
