# Pilot and controller guide — AACS 0.2.3-beta.1

## Pilot start

Your vessel needs an ARD registration and an HQ-verified radar binding. Your Minecraft account must also be approved to pilot that vessel. A transponder is optional for these chat functions.

In Minecraft chat:

```text
$atc checkin ARD-0001
```

Use your actual registration. On the first attempt, ask a controller to approve the recent check-in at HQ menu **P**, option **1**. Repeat check-in once approved. Your account is identified by the Chat Box event's UUID; a UUID typed in your message does not authenticate you.

The check-in lasts up to two real hours, capped by the approval expiry. Repeat check-in to renew. Check in again after an HQ restart. Use checkout when you finish flying.

The `$` prefix hides the command from normal public chat where supported by Advanced Peripherals. `atc ...` without `$` also works but may be visible to everyone. Wait at least three seconds between commands. Responses use a queue and may take longer if several pilots send commands at once.

## Commands

| Command | Meaning |
|---|---|
| `$atc help` | List commands. |
| `$atc checkin ARD-0001` | Request/activate your approved vessel association. |
| `$atc checkout` | Stop private vessel notices to this account. |
| `$atc status` | Current observed position, zones and clearance for your checked-in vessel. |
| `$atc zones` | Enabled zone list, page 1. |
| `$atc zones 2` | Next numbered page. |
| `$atc zone capital` | Exact geometry, altitude limits, dimension, scope and rule for zone `capital`. IDs are case-sensitive. |
| `$atc ack` | Acknowledge your latest warning. |
| `$atc ack ATC-...` | Acknowledge a particular recent warning ID addressed to your active check-in. |
| `$atc say Requesting clearance for capital` | Record a message for controllers at HQ. Maximum 160 characters. |

An acknowledgement is a receipt, not a permit. An outgoing message being recorded does not prove a human controller has read it. Unresolved warnings keep repeating even after acknowledgement.

## Automatic notices

- **Detected within:** first observation already inside a zone, or continuity is insufficient to assert a crossing.
- **Entering / observed leaving:** a change between sufficiently recent, consistent observations under the same policy revision.
- **Clearance now valid / no longer valid:** a permit or rule evaluation changed while contact remained observed.
- **WARNING:** current observed contact violates a configured rule. Reminders are limited to approximately every 30 seconds while the violation persists; additional changes can trigger a new notice.
- **Contact lost:** radar no longer has a fresh contact. It does not mean the vessel left the zone or landed.

Overlapping zones are combined into a contact summary; for very long summaries use `status`/`zone` and contact control for details. Aircraft moving completely through a zone between samples may not receive an entry notice; do not depend on sampled radar for guaranteed boundary detection.

If no approved pilot is checked in, a controller can message a known username directly. Optional public hails can warn unassigned/unknown contacts by name/coordinates. Radar proximity is never used to guess a pilot account.

## Controller workflow

1. HQ **2 → 6**: register the vessel (or review/approve an application).
2. HQ **5**: inspect and bind the correct physical radar contact to its registration at each station.
3. Pilot sends `checkin`; HQ **P → 1**: review the numbered recent request, verify the association, approve it.
4. Pilot repeats `checkin`.
5. HQ **4**: create the airspace zones; HQ **6**: grant actual temporary zone permits.
6. HQ **M**: read the latest 64 pilot messages and warning acknowledgements from this HQ session.
7. HQ **C**: send a message to an ARD registration, exact Minecraft username, or `ALL`. A registration targets its currently checked-in pilots. `ALL` needs confirmation and an available station with public hails enabled.

Pilot approvals persist, are time-limited and can be revoked under **P → 4**. Revocation removes the live pilot session on the next HQ update and requests cancellation of queued vessel notices. Already sent messages cannot be recalled; an unreachable station may retain a notice until its 20-second expiry. One account has one vessel approval; multiple approved accounts may check in for one vessel. Approval is a controller's association, not proof of physical occupancy.

To grant clearance, use HQ menu **6**, subject `vessel:ARD-0001`, zone ID and duration. Sending “approved” in a controller message alone does not change the permit database.

## Availability

Chat coordination requires HQ online, a working authenticated station link, a loaded sending station/Chat Box, and a target reachable under the mod's server settings. A Chat Box send success is not proof of reading. Queued notices expire after 20 seconds; they are not a durable emergency-delivery service.

The onboard beacon may additionally show a warning on its own screen when associated at HQ. It does not replace the physical radar binding or automatically identify the current pilot.

## Registration suspension

If your account approval is still valid, a suspended vessel can still receive private warnings and check in for communication. Suspension does not grant access: controlled/restricted/prohibited zone checks continue to reject a suspended registration. Only a controller's registry/permit changes affect clearance.

Renewing the same active check-in keeps recent warning IDs available for acknowledgement. Checkout/revocation asks stations to cancel queued vessel notices, subject to link availability and the 20-second expiry.
