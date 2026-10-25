# Recovery, backups and maintenance

## Normal outages

**HQ offline:** stations retain local history and stale cached rules. Restart HQ with its current database, keys and transport state; do not restore old state just because it was briefly offline. Observe stations obtaining a fresh policy. Generate local station reports for the gap—there is no automatic history backfill.

**Station restart:** saved replay counters are retained; unused reserved sequence numbers are skipped. A radar track needs a newly advancing scan token after restart before being trusted as fresh. Existing cached permissions retain their original expiry.

**Pending registration:** use the terminal's R option to retry the persisted operation ID. Confirm its actual result at HQ before starting a new application.

## Run lock

AACS creates `/aacs/data/run.lock` to prevent accidentally running two instances with the same replay/cipher state. Normal exit removes it. The generated startup uses `boot`, which clears a crash-left lock during computer startup.

If you do not use the supplied startup and have an old lock, first stop every AACS process (rebooting is safest), then run:

```text
/aacs/start.lua unlock
```

Confirm `UNLOCK`, then start normally. Never use unlock or the boot command to run a second concurrent copy. Never clone a live node to another computer.

## Interrupted or corrupt writes

A `.new` file, a missing live file with a `.bak` present, or a checksum failure stops loading. This is intentional. AACS will not silently restore an older replay counter or reset credentials.

1. Stop the affected node(s). Keep a protected copy of their complete state for diagnosis.
2. Determine whether the problem concerns the central database, policy cache, pending application or **transport security state**.
3. If `transport.json` or its consistency is uncertain, generate a **fresh network deployment with a new realm and fresh keys**. Do not delete the counter and keep the old key. This test release favors a full coordinated re-key over an unsafe partial reset.
4. For a damaged HQ database, an administrator may recover a checksum-valid `.bak` into the new deployment's HQ data after inspection. Recent registrations/permits may have been lost. Review them rather than assuming the older state is authoritative.
5. Discard old station policy caches when moving to the newly keyed realm. Recheck permissions and peer revocations.
6. Run self-tests and repeat the acceptance checks before reconnecting nodes.

A failed write can leave an operation committed but its acknowledgement undelivered. Check records and use the saved operation ID. The receipt mechanism is bounded and is not a distributed transaction log.

## Backups

Stop AACS or stop the server before copying a consistent backup. Back up the central database, configurations, transport state, logs and reports securely. Backups contain credentials and surveillance records.

**Restore is not the same as restart.** Restoring an old computer image with its old secret/counters can reuse encryption nonces and accept previously delivered traffic. Re-key after rollback of security state. Full-world rollbacks are included: outside observers may still hold previously captured packets.

Do not replace a current `transport.json` with the fresh zero-counter file generated for an old existing key. Do not overwrite it when updating Lua code.

## Stolen or compromised computer

At HQ, choose the revoke/remove menu and revoke the node's **peer name** immediately. Disconnect or remove its physical network access. Investigate all observations/registrations the endpoint was authorized to submit. If it was a registrar, inspect recent approvals. If it was HQ, assume all peer secrets were exposed and re-provision the whole network.

This version has persistent revocation but no live key-enrollment/rotation server. To reintroduce an affected peer safely, use a deliberate fresh deployment rather than copying another node's key. For a staged new-node expansion while preserving an existing realm, a competent operator can generate a new independent pairwise key and matching state/config, but that workflow is not automated or supported by the first-run provisioner; a coordinated reprovision is the documented path.

## Storage pressure

Check computer storage before creating large reports. Copy finished reports out, then delete unneeded report files. Event/audit logs rotate automatically; the registry does not. Archive resolved applications through HQ's revoke/remove menu. Retire obsolete vessels and remove obsolete bindings/permits deliberately; do not hand-edit live data while the service runs.

A disk-full error stops the affected operation; do not interpret a stopped station as clear airspace. Hardware protection/alarms outside ComputerCraft are your responsibility.
