# Update to AACS 0.2.3 while keeping the current registry

Minecraft can stay online. Exit AACS on the computers being updated; the updater preserves registrations, bindings, zones, permits, private configuration and transport counters. This is a code update, so do not use `--fresh` or `--reset-aacs`.

## 1. Upload the ZIP

Download `AACS_0.2.3_display_columns.zip`. In Windows Command Prompt:

```cmd
cd /d "%USERPROFILE%\Downloads"
scp AACS_0.2.3_display_columns.zip griffin@192.168.68.56:/tmp/AACS_0.2.3_display_columns.zip
```

## 2. Stage the updater over SSH

Exit AACS with **Q** on HQ **112** and station **108**. Include any other AACS computer IDs in the command if you have more nodes. Minecraft and unrelated computers can remain running.

```bash
cd /var/opt/minecraft/crafty/crafty-4/servers/e5886f3a-0bca-4a66-9295-a2f2cf54d4fb || exit 1
sudo python3 /tmp/AACS_0.2.3_display_columns.zip --computers 108 112
```

This stages only the new `aacs_install.lua` in each computer root and backs up any previous installer under `aacs-update-backups/`. It refuses a target with an AACS run lock. Exiting normally with Q clears that lock.

## 3. Apply on each updated ComputerCraft computer

```text
aacs_install.lua --upgrade
/aacs/start.lua selftest
reboot
```

The display and binding changes need no setup or configuration migration. If upgrading from before station chat support, run `/aacs/start.lua setup` on each station to select its Chat Box while retaining its existing monitor/radar values.

Reboot HQ first, then stations. The normal AACS startup starts the updated code. If you use a custom startup, run `/aacs/start.lua run` after reboot.

## 4. Check the new display columns

The live table now has separate **NAME** and **ARD ID** columns. Names use the width left after complete registrations, coordinates and state. Wider monitors show longer names automatically; narrower screens use an ellipsis when needed. Small displays use a compact identity/status table if the coordinates will not fit. Resize the monitor and the next draw uses its new width. Existing vessel names and registrations are unchanged.

## 5. Use or renew a year-long binding

At HQ choose **5 — Bind observed ship to registration**. Select the fresh observed ship, enter its existing ARD registration, then press Enter at the lifetime prompt for **525,600 real minutes (365 days)**. Shorter durations accept any whole number from 1 to 525,600 minutes.

Existing bindings retain their saved expiry; the update does not extend them automatically. Repeating menu 5 for the same ship and registration renews the deadline from the time HQ accepts the new operation. No vessel re-registration is needed. Expiry continues while computers or Minecraft are offline because it uses real UTC time.

Pilot approvals and zone permits retain their independent limits. A year-long binding can still be removed immediately under HQ **9 → binding**. If the vessel's UUID/track ID changes, inspect the new contact and update the binding.

Do not run fresh provisioning to add a transponder or station to a live realm. It generates different keys/realm and is a reset workflow. Add peers deliberately while preserving existing transport counters and private configuration.
