# AACS 0.2.3-beta.1 — fresh setup

This guide starts a new network using **HQ computer 112** and **Capital station 108**. Change those numbers if `id` on the actual computers shows different IDs. A wired peripheral name such as `computer_49` is not the computer's filesystem ID.

You can keep the Minecraft server running. **For a fresh install, stop AACS and shut down the affected ComputerCraft computers before copying files.** Do the peripheral configuration in game after powering them back on.

A fresh start creates new keys and a new empty registry. Existing AACS folders/startup files are backed up before replacement when `--reset-aacs` is used. To keep the current registrations, use [docs/UPGRADING.md](docs/UPGRADING.md) instead.

## 1. Place and connect the equipment

| Location | Equipment |
|---|---|
| HQ 112 | Advanced Computer and network modem. Optional monitor/printer. |
| Capital 108 | Advanced Computer, network modem, connected working radar, Chat Box, optional monitor. |
| Each additional station | The same station equipment and its own unique computer ID. |
| Optional kiosk/registrar | Computer and modem for public applications/staff registration. |
| Optional onboard transponder | Computer and modem aboard the ship; CC: Sable for local UUID lookup. Not needed for private pilot chat. |

Use wired modems and networking cable to expose the radar bearing, monitor and Chat Box to the station. Enable each peripheral modem by right-clicking it. Stations and HQ must also be able to exchange rednet messages; Ender Modems are convenient if permitted by your pack. Keep the computers, sensors and required network chunks loaded.

Use fixed ground radars initially. The Capital radar position previously identified was **X -2073, Y 167, Z -1218**; verify it is still the same bearing. These are world coordinates, not ship storage/sublevel coordinates.

Run `id` on each computer once so its save folder exists. Do not guess its ID.

## 2. Stop the target computers

On HQ, choose **Q** in the main menu. On the station, press **Q**. Exit the Lua prompt with `exit()` if necessary. In the ComputerCraft shell on **both** targets:

```text
shutdown
```

Keep them off until the SSH installation finishes. AACS's `run.lock` must be gone; exiting AACS with Q clears it. If a previous crash left a lock, boot that computer and use `/aacs/start.lua unlock` only after confirming no AACS process is running, then shut it down again.

## 3. Download and upload the ZIP

Download **AACS_0.2.3_display_columns.zip** to Windows Downloads.

In **Windows Command Prompt**:

```cmd
cd /d "%USERPROFILE%\Downloads"
scp AACS_0.2.3_display_columns.zip griffin@192.168.68.56:/tmp/AACS_0.2.3_display_columns.zip
```

Enter your SSH password when prompted. If using PowerShell instead, first run `cmd` so these exact commands use Command Prompt syntax.

## 4. Install the fresh network over SSH

On the server:

```bash
cd /var/opt/minecraft/crafty/crafty-4/servers/e5886f3a-0bca-4a66-9295-a2f2cf54d4fb || exit 1
sudo python3 /tmp/AACS_0.2.3_display_columns.zip --fresh --hq 112 --station capital=108 --reset-aacs
```

`--reset-aacs` deliberately replaces the current AACS installation/startup with a fresh network. It backs up each old `aacs` directory, `startup.lua` and `.settings` under **aacs-fresh-backups/** before replacing them. Existing unrelated programs and settings are preserved; AACS setup saves its required disk-startup setting.

The command prints a private `aacs-private-...` directory containing the generated node images and a backup directory. Keep both private: they contain keys. Do not share them with players. The public source ZIP contains no live keys.

It verifies all target folders and refuses if AACS still has a run lock, IDs are duplicated, or a target is missing. It writes fresh runtime/config/state directly; there is no in-game installer step for this fresh method. Files are owned by the existing computer-folder owner.

**More stations:** include every intended node in the same fresh command, for example:

```bash
cd /var/opt/minecraft/crafty/crafty-4/servers/e5886f3a-0bca-4a66-9295-a2f2cf54d4fb || exit 1
sudo python3 /tmp/AACS_0.2.3_display_columns.zip --fresh --hq 112 --station capital=108 --station border=120 --kiosk adot=121 --reset-aacs
```

Only use 120/121 if they are the actual IDs of your placed, shut-down computers. Do not run this second example after installing the first unless you intend another reset. Adding a node to an already operating realm requires deliberate peer provisioning; rerunning fresh provisioning starts a different realm.

## 5. Configure HQ in game

Power on **112**. Its AACS menu may start automatically; choose Q to get to the shell. Run:

```text
/aacs/start.lua selftest
/aacs/start.lua setup
```

All tests must pass. HQ setup asks for its optional monitor. Use the exact discovered peripheral name, leave it blank on a fresh node for no display, or enter `-` to disable an existing monitor. **HQ does not need a Chat Box; each station has one.**

Start HQ:

```text
/aacs/start.lua run
```

## 6. Configure each station in game

Power on **108**. On a fresh node, the message asking you to configure sensors is expected. Run:

```text
/aacs/start.lua selftest
/aacs/start.lua setup
```

For the existing Capital installation, use these values **only if setup still discovers the same names**:

| Prompt | Capital value / explanation |
|---|---|
| Monitor | `monitor_14` — the intended wall monitor. |
| Radar(s) | `create_radar:radar_bearing_0` — the bearing exposing `getTracks`. |
| Player Detector | Optional. Leave blank initially if only testing ships. |
| Player detection radius | `128`; used only if a Player Detector is configured. |
| Ground station world x/y/z | `-2073`, `167`, `-1218`, after verifying the bearing's location. |
| Maximum plausible radar distance | Your tested coverage boundary, e.g. `4096`. This does not extend actual mod radar range. |
| Alarm/fault sides | Leave blank initially; later use lamps/sirens. |
| Chat Box | `chat_box_0`, if discovered. Enter `-` to disable. |
| Allow public hails? | `y` to warn unidentified/unassigned vessels in public chat; `n` for private notices only. |

The Player Detector is not required to identify a pilot: pilot chat events contain the account UUID. Radar players and nearby players are never automatically assumed to be flying a ship.

Test one private message to your actual Minecraft username:

```text
/aacs/start.lua chat-test YourMinecraftUsername
```

Replace `YourMinecraftUsername`. Check that you receive the message. If the API rejects it, inspect the Chat Box's server range/permission/cooldown settings. The program supports the existing `sendMessageToPlayer` API and the newer options-table `sendMessage` API through method detection.

Start the station:

```text
/aacs/start.lua run
```

Wait for **HQ POLICY CURRENT**. The native screen footer should show **Chat ready**. The monitor should have a changing UTC clock and frame counter identifying **PC 108 | monitor_14**. Repeat station setup for every station using its own discovered names and actual position.

## 7. Register and bind a vessel

On HQ **112**:

1. Choose **2 — Vessel registrations / applications**, then **6 — Register a vessel directly**.
2. Enter the ship's name, type, owner, nation and purpose. The optional typed ship UUID is a claim; it does not create a physical binding.
3. Record the returned registration, for example `ARD-0001`.
4. Fly/move the vessel into working radar coverage.
5. Choose **5 — Bind observed ship to registration**. Select its numbered contact after verifying the position, enter the actual ARD registration and a binding duration.

Binding duration accepts 1–525,600 real minutes. The default and maximum are **365 real days** (525,600 minutes); press Enter for a year. These are real UTC deadlines, including time while HQ is off. Bind the independently verified contact at **each** station to the same registration. This lets HQ merge the registered vessel across stations and suppress duplicate notices. Unknown tracks remain station-scoped.

Existing bindings keep their saved expiry after an upgrade. To extend one, select that observed ship and the same registration again under menu 5, then enter the desired lifetime. Renewal runs from the time HQ accepts it; replaying the same network request does not extend it again.

The named vessel should now appear in live contacts and the station's display after its policy refresh. You do not need a transponder for that name or for checked-in pilot chat.

## 8. Approve and check in the pilot

In Minecraft chat, the pilot types:

```text
$atc checkin ARD-0001
```

Use the actual vessel registration. The first attempt asks for HQ approval.

On HQ, choose **P — Pilot approvals**, then **1 — Approve a recent pilot check-in request**. Select the numbered request, verify the actual player/vessel association, approve it and choose a lifetime. This uses the Chat Box event's account UUID, not a UUID claimed in the chat text.

The pilot repeats the same check-in command after approval. The private confirmation includes the current radar/airspace status. A check-in lasts up to **two real hours**, capped by the approval's expiry. Repeat check-in to renew; use `$atc checkout` when finished. HQ restarts require pilots to check in again; the approvals themselves persist.

Several approved pilots may check in for one vessel. Every checked-in account receives its notices. An approval alone does not assert who is aboard; controllers must verify the association. One account has one current vessel approval.

## 9. Define airspace and clearance

On HQ, choose **4 — Create / replace a zone**. Set its ID, name, class, dimension, shape and inclusive world-coordinate/altitude boundaries. Use **ships** for aircraft zones.

| Class | Rule |
|---|---|
| unrestricted | Open; observation still logged. |
| controlled | Active identified registration required. |
| restricted | Active identified registration plus an explicit zone permit. |
| prohibited | Explicit zone permit and active identified registration; highest alert level. |

Choose **6 — Grant temporary zone clearance**, enter `vessel:ARD-0001`, the zone ID and real minutes. All overlapping zone rules apply. Registering, checking in, saying “approved” in chat or acknowledging a warning does not create a permit.

For a test, create a small restricted box near the radar. Have the bound vessel fly from outside to inside, then outside again. Check the private entry/warning and exit notices. Grant a short permit and let it expire while the vessel remains observed.

## 10. Pilot and controller communication

Pilot commands:

```text
$atc help
$atc checkin ARD-0001
$atc status
$atc zones
$atc zones 2
$atc zone capital
$atc ack
$atc say Requesting clearance for capital
$atc checkout
```

Replace `capital` with a configured zone ID. `$` hides the command from normal global chat where supported by the Chat Box mod. Plain `atc ...` also works but may be public. Wait at least three seconds between commands; requests/messages use cooldown-aware queues.

HQ **M** shows the current session's last 64 pilot messages/acknowledgements; retained event logs also record them. It is an inbox, not a guarantee that a human controller has read a message. HQ **C** sends a controller reply to a vessel registration, a Minecraft username, or `ALL`. Public messages need public hails enabled on an available station and confirmation in the HQ menu. Grant actual permits using menu 6.

More detail: [docs/PILOT_GUIDE.md](docs/PILOT_GUIDE.md).

## 11. What to verify before relying on it

- Each station's named Chat Box can send a private test message.
- Check-in reaches HQ; approval is required; private replies reach the correct account.
- The same registered vessel seen by overlapping radars gets one national notice stream.
- Entry, leaving, permit expiry and 30-second warning reminders work in your world.
- Losing coverage says **contact lost**, not that the vessel left or landed.
- A warning acknowledgement appears at HQ and does not change clearance.
- The intended monitor's clock/frame counter advances.
- Restarting HQ retains the registry/approvals but requires a new pilot check-in.

Automated tests use fixtures and do not validate your running modpack. Check mod settings and behavior in world.

## Optional application terminals and onboard beacon

When generating a fresh realm, include the actual kiosk/registrar/beacon computer IDs with `--kiosk NAME=ID`, `--registrar NAME=ID` and `--beacon NAME=ID` in that same command. Each gets its own private node image and startup. Keep registrar computers staff-only; public kiosks cannot approve registrations or edit national rules.

On an onboard beacon, install its matching node, attach a suitable modem and run selftest/setup. CC: Sable is needed for its local ship UUID lookup. At HQ choose **B — Associate a beacon credential**, enter its provisioned node name and the vessel registration, then run the beacon. It sends its credential and shows HQ acknowledgements/warnings. It remains separate from both the independently inspected radar binding and the pilot's chat check-in.

## Troubleshooting

Stop the station with Q, then run:

```text
/aacs/start.lua diagnose
```

The report is saved to `/aacs/diagnostics.txt` and contains coordinates; keep it private. It includes exact sensor errors, monitor availability/last draw and Chat Box availability/last status.

If chat fails, first run `chat-test` for a known online username. Confirm the station says Chat ready and HQ policy is current, then check pilot approval, active check-in and the exact bound vessel. For a warning without a pilot, public hails must be enabled; public hails are globally limited to one every 30 seconds.

If the monitor stays frozen, inspect **Last monitor write**. Advancing frames with state `ok` means server-side draw calls completed; it does not prove the client displayed them or identify the physical monitor for you. Check the exact wired peripheral, competing writers and client rendering.

If there are no ship contacts, verify the radar itself has advancing `scannedTime` values, correct vertical/horizontal detection settings and a working bearing. Initial cached radar data needs a subsequent scan before AACS trusts it.

During HQ/network failure, local observation continues but automatic national chat notices stop. Queued notices expire in 20 seconds. A restored link does not replay a backlog of old warnings.

For manual/extracted deployments on another server, see [docs/STATION_SETUP.md](docs/STATION_SETUP.md). For code-only upgrades, see [docs/UPGRADING.md](docs/UPGRADING.md).

## Reviewed behavior in 0.2.1

Both supported Chat Box event orders are normalized before account validation. When a newer airspace notice replaces a queued warning, HQ requests cancellation at the old station as well as replacing its own queue entry. Checkout, approval expiry and revocation also request cancellation. Cancellation cannot recall a message already sent or reach a disconnected station; queued notices still expire after 20 seconds. HQ reconnection clears previous-session station queues.

Binding expiry/changes immediately reclassify retained contacts. Pilot communication remains available under an existing approval when the vessel registration is suspended; that does not restore airspace clearance. All nodes should run this reviewed build before testing chat.
