# Testing and commissioning

## What was actually tested

The bundled suite was executed in standalone Lua 5.3 (`texlua`) with isolated ComputerCraft filesystem, peripheral, event-loop and network test doubles. The exact final output is in `TEST_RESULTS.txt`. No Minecraft instance, real Create: Radars network, live Advanced Peripherals detector, Sable vessel, CC printer or multiplayer attack simulation was available during development.

Passing tests are evidence about the tested code paths—not evidence that a particular modpack works, a security audit, a performance guarantee or a reason to connect a cannon.

Run on an otherwise idle CC computer:

```text
/aacs/start.lua selftest
/aacs/start.lua demo
/aacs/start.lua diagnose
```

The tests restore their mocked globals after each check. Do not run them concurrently with a live AACS process in another tab. The demo is synthetic and does not grant real permits or command peripherals. Diagnostics write raw sensor/API details to `/aacs/diagnostics.txt`; redact private locations before sharing it.

On a desktop with Lua 5.2/5.3 and `bit32`, from the package root:

```sh
lua tools/run_tests.lua
# Alternatively, when LuaTeX is installed:
texlua tools/run_tests.lua
```

`tools/test_json.lua` is only a standalone test helper; production uses CC's `textutils` JSON implementation. Therefore run the suite inside CC too.

## Covered by the automated suite

Cryptographic vectors cover SHA-256, HMAC-SHA256 RFC 4231 and ChaCha20 RFC 8439. Protocol checks cover encrypted round trips, altered tags, wrong keys/realms, sender-ID impersonation, direction/reflection, replay after reboot, sequence reservation, expired/future packets and bounds. Storage tests cover checksums, missing state and interrupted replacements.

Application tests cover role restrictions, kiosk approval denial, registrar scope, idempotent retries, central approvals, permit expiry/revocation, physical-binding expiry, overlapping zones, dimensional scope, geometry, track deduplication, stale contacts and estimated crossings. Event-loop tests cover a station receiving and applying policy chunks, HQ accepting station observations but rejecting beacon sensor injection, and retrying a persisted request after a missing acknowledgement. Reports exercise CSV escaping, observed visit durations, coverage gaps, printer lifecycle and pagination.

Binding-duration regressions cover the one-year UI default, the one-minute minimum, durations beyond the old seven-day cap, the exact 525,600-minute maximum and rejection above it. They also cover invalid inputs without database changes, HQ restart and station-cache persistence, millisecond-accurate expiry at 365 days, renewal versus idempotent retry, explicit unbinding before reassignment, preservation of existing deadlines, and unchanged pilot-approval and permit limits.

## In-world acceptance checklist — do not skip

Record the exact Minecraft, loader and mod versions tested. Use an expendable area with indicator lamps and all cannon controls disconnected.

| Test | Expected result |
|---|---|
| Start HQ and two separately provisioned stations | Each authenticates under its own name; stations obtain a current policy. |
| Run `selftest` on each CC installation | Zero failures; no live files or peripherals affected. |
| Fly an obvious test craft through each radar | World coordinates match observation; `scannedTime` changes; track ID is recorded. |
| Stop/remove radar scanning or move out of range | Old scan tokens stop renewing; contact eventually becomes lost, not a fabricated exit. |
| Walk through detector coverage | Correct player UUID, name, dimension and world position are recorded. |
| Submit from public kiosk | APP receipt is issued; no direct approval or surveillance access is offered. |
| Review full application at registrar | Owner, nation, type, purpose and description can be viewed by entering its ID in the list. |
| Approve and inspect/bind actual craft at HQ | ARD registration is associated only with the selected fresh sensor key. |
| Try another craft with the same display name/transponder label | It must NOT inherit the first craft's observed identity. If it does, stop commissioning the radar binding. |
| Controlled zone, unknown then bound active craft | Unknown raises an alert; approved/bound registration is allowed. |
| Restricted/prohibited zone without and with permit | Registration alone is denied; the correct current zone permit allows entry. |
| Two overlapping restricted zones | A permit for only one does not waive the other. |
| Permit expiry/revocation and suspended registration | Alerts return after policy propagation; stale stations clearly indicate stale rules. |
| Fast traversal with endpoints outside a small zone | A straight-line crossing may be logged as estimated; it is not a confirmed flight path. |
| Separate player/ship scope | Airspace-only zones do not unexpectedly restrict pedestrians. |
| Ship unload/reload, rebuild and server restart | Check whether the radar ID persists, changes or is reused; remove/rebind uncertain identities. |
| Disconnect HQ | Stations keep local observations, label policy stale after its lease and assert the configured fault indicator. |
| Reconnect HQ | New observations resume; prior outage history is available locally, not silently backfilled. |
| Reboot each node | Counter state persists; no request is replayed and scans require fresh tokens. |
| Export and print | TXT, event CSV and visits CSV are saved; page wrapping and supplies/resume work on the actual printer. |
| Fill printer output tray | Printing stops with recovery instructions rather than claiming the page was delivered. |
| Revoke an expendable kiosk/beacon | HQ refuses further messages from it, including after HQ reboot. |
| Inspect claims/access protections | Untrusted players cannot modify HQ/stations, attach wired modems, steal disks or alter peripherals. |

## Adversarial and failure checks

Use only your own isolated test network. Capture and resend a valid test packet: it should be rejected. Change its ciphertext, claimed sender or role without the key: it should not authorize an operation. A legitimate kiosk credential must still be unable to approve, create permits or inject sensor observations. Do not confuse a changed Rednet computer ID with a valid cryptographic identity.

Simulate corrupt state only on disposable copies. A `.new` file/checksum mismatch should stop that node, not reset counters. Re-provision after a security-state rollback; never bring a deliberately rolled-back copy online with a live key.

Flood resistance, exact CPU budgets, chunk unloading, server rollback behavior and all interacting mod combinations require separate live tests. This release does not promise continuous service under attack or automatic recovery from full disks.

## Suggested commissioning record

Record the tested mod versions, station coordinates/coverage, sensor names, test craft radar IDs before/after restart, sample intervals, observed policy latency, report output, and failures. Do not include private keys. Keep the completed checklist with your server documentation before expanding beyond the test area.

## Station chat acceptance

1. Give every station a named Chat Box and send a private `chat-test` to an online account.
2. Attempt check-in before pilot approval: verify denial and a numbered recent request at HQ.
3. Approve through HQ P, check in again, query status/zones/zone geometry.
4. Fly a bound vessel across restricted boundaries; verify private entry/exit, permit grant/expiry and 30-second reminder timing.
5. Overlap two stations bound to the same registration: verify one national message stream.
6. Acknowledge a warning; verify HQ M/log entry and unchanged permit status. Send a pilot `say` message and reply with HQ C.
7. Lose radar coverage; verify contact-lost wording, without a claimed boundary exit.
8. Detach/reconnect the configured Chat Box; verify scans continue, error status appears and the sender recovers.
9. Stop HQ; verify local observations continue and old queued notices expire. Restart HQ and check in again.
10. With public hails disabled, verify unknown ships are not privately assigned to nearby players or globally broadcast. Enable hails deliberately and test global rate limiting.
