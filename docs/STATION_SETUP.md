# Station equipment and setup

Use this for every station. For the exact Windows/SSH fresh installation on chunky, use [../QUICKSTART.md](../QUICKSTART.md).

## Equipment and wiring

A station needs a ComputerCraft computer, working radar, and a Chat Box. A monitor and Player Detector are optional. Use an Advanced Computer if possible.

Connect the radar **bearing/base exposing `getTracks`** to a wired modem, enable that modem's peripheral access, then connect the cable network to a wired modem on the computer. Do the same for the monitor and Chat Box. A modem placed near a block is not enough; enable the peripheral modem and confirm the computer discovers its name.

Each station should use its own Chat Box. Configure the exact peripheral name; AACS does not choose an arbitrary box at runtime. For Capital the known names are:

| Peripheral | Name |
|---|---|
| Radar bearing | `create_radar:radar_bearing_0` |
| Wall monitor | `monitor_14` |
| Chat Box | `chat_box_0` |

Names may change when blocks are rebuilt. Use diagnostics/setup to discover them again. AACS retries the configured monitor/Chat Box if it disconnects and returns under that same name.

Station-to-HQ communications use rednet over their configured modems. Use a working wired network or suitable wireless/Ender modems for national coverage. Radio Silence, underwater networking rules, distance limits and unloaded chunks may affect wireless connectivity; AACS does not bypass those mechanics or provide chunk loading.

The radar must already rotate, have the required dishes/source/network, and detect targets on its own. AACS reads its tracks; it does not extend its range, vertical scan height, terrain visibility or underwater detection rules. If radar data is stale or absent, fix the radar/mod configuration first.

## Station configuration

On the computer, stop AACS with Q:

```text
/aacs/start.lua diagnose
/aacs/start.lua setup
```

Use world coordinates of the fixed radar, not coordinates inside a Sable storage plot. For the previously identified Capital bearing these were X -2073, Y 167, Z -1218. Confirm the bearing is still there.

The maximum plausible radar distance is a sanity boundary. It rejects observations too far from your configured station location. It does not set the physical radar's detection range.

Set the Chat Box name when prompted. Enter `-` to disable it; Enter keeps the displayed default. Choose whether public hails are allowed. Private notices work with public hails disabled. Unknown/unassigned vessels can only be hailed publicly, and only while HQ and a suitable Chat Box are working.

Leave alarm/fault sides blank initially. Connect only indicators/sirens when enabling them. A Chat Box failure is shown separately from a sensor failure; it does not stop radar scanning.

Player Detector is optional. It tracks player UUIDs independently; it is not an occupancy sensor and does not automatically identify a ship's pilot. On versions requiring detailed player data, AACS requests it. Server random-position-error/range settings can still affect accuracy.

## Test the Chat Box

With AACS stopped:

```text
/aacs/start.lua chat-test YourMinecraftUsername
```

Supply an online player's exact username. Check the recipient's chat. A return of “accepted” only means the mod accepted the send call.

AACS uses `sendMessageToPlayer` when available. Otherwise it uses `sendMessage(message, {player=..., prefix="AACS"})`. Public sends use the corresponding broadcast form. Methods returning `nil,error`, false or throwing are treated as failures. Messages are queued, sent no faster than once per 1.5 seconds by default, and retried up to three attempts. Server cooldown/range restrictions still apply.

Run the node:

```text
/aacs/start.lua run
```

Expect HQ POLICY CURRENT and Chat ready. If a box fails, diagnostics save its exact error/queue status to `/aacs/data/chat-status.json`. No peer keys are included in this status file.

## More than one radar station

Each station has its own namespace by default, e.g. `radar-capital` and `radar-border`. A controller must independently inspect and bind the vessel's observed contact at each station to the same ARD registration.

HQ then merges the registered subject and chooses one available Chat Box for each notice, preferring the station supplying the contact. Other stations can hear the pilot's same chat command; HQ deduplicates the relays. It does not ask every station to broadcast the same notice.

Unknown contacts are not automatically merged across namespaces. Optional public hails are globally limited to one every 30 seconds in addition to each box's queue/cooldown.

## Manual deployment from an extracted package

For a new network, run Python 3.9+ from the extracted AACS directory on your PC/server:

```text
python3 tools/provision.py --hq 112 --station capital=108 --output aacs-deployment
```

On Windows use `py -3` instead of `python3`. Add the other `--station NAME=ID`, `--kiosk NAME=ID`, `--registrar NAME=ID` or `--beacon NAME=ID` arguments when generating the network.

Each generated node directory is a complete computer root. Copy only the matching node's contents to `<world>/computercraft/computer/<ID>/` while that computer is off. Keep the whole deployment private. Copying one node's keys/state into a different computer is invalid.

Alternatively, the package's `tools/deploy.py` installs a generated private deployment into a supplied `--computer-root` directory, with the same preflight/backup behavior as the ZIP's fresh installer. It is intended for dedicated powered-off computers. See `python3 tools/deploy.py --help`.

For disk/file-transfer installation, run `aacs_install.lua` on a fresh computer to install code, then transfer only that node's generated `/aacs/config.json` and `/aacs/data/transport.json`. Set the dedicated computer's `/startup.lua` to:

```lua
shell.run("/aacs/start.lua", "boot")
```

Run selftest, setup, then start HQ before stations. Never regenerate transport counters by hand.

## Reviewed compatibility

The adapter accepts both `chat` event layouts: older AP `(username, message, UUID)` and newer AP `(UUID, username, message)`. Command events without an actual player UUID, including `/say`, cannot check in a pilot. New notice ordering uses the authenticated wire sequence, and HQ sends cancellation/reset commands to prevent old queued notices surviving a station handoff or HQ reconnect where the link is reachable.
