# Primary references

Consulted for the target integration on 22 October 2026. These references document APIs and known reports; they are not a claim that this bundle was tested in those mods or approved by their authors. Pin and record the versions actually installed on your server.

## Sensor APIs

- Create: Radars — CC:Tweaked compatibility wiki: https://github.com/Arsenalists-of-Create/Create-Radar/wiki/CC:Tweaked-compat . Documents `getTracks()`, track fields, radar peripherals and existing controller methods. The package intentionally does not invoke fire/target-control methods.
- Create: Radars — maintainer issue tracker: https://github.com/Arsenalists-of-Create/Create-Radar/issues . Relevant open reports observed during preparation include #140 (Sable sublevels), #131 (radar world position on sublevels), #128 (velocity) and #127 (stale/out-of-range tracks). Reports identify test risks, not proof every installation fails.
- Advanced Peripherals Player Detector, 0.8 docs: https://docs.advanced-peripherals.de/0.8/peripherals/player_detector/ . `getPlayer()`, range functions and UUID/world-position data.
- Advanced Peripherals Player Detector, 0.7 docs: https://docs.advanced-peripherals.de/0.7/peripherals/player_detector/ . Older naming and `getPlayerPos()` differences; only versions returning trustworthy UUIDs can be used for player authorization.
- CC: Sable sublevel API: https://techtastic.github.io/CC-Sable/modules/sublevel.html . Optional onboard `getUniqueId()` and pose reading. Self-reported values are not independently trusted physical identity.

## CC:Tweaked

- Rednet and its security warning: https://tweaked.cc/module/rednet.html . Rednet alone does not authenticate senders or protect against eavesdropping.
- Printer lifecycle and methods: https://tweaked.cc/peripheral/printer.html . A new page is needed before page-size/cursor operations; paper, ink and output capacity matter.
- Filesystem: https://tweaked.cc/module/fs.html . State/log IO.
- Startup behavior: https://tweaked.cc/reference/startup.html . Disk startup precedes normal startup when allowed.
- Persistent settings: https://tweaked.cc/module/settings.html . Disabling disk startup must be saved.
- Textutils: https://tweaked.cc/module/textutils.html . JSON and terminal text operations.
- OS/time/events: https://tweaked.cc/module/os.html . UTC epoch and timers.
- Supported Lua features: https://tweaked.cc/reference/feature_compat.html . Check the installed runtime, including `bit32` support.

## Algorithms and test vectors

- RFC 8439: https://www.rfc-editor.org/rfc/rfc8439 . ChaCha20 algorithm and public test vectors. This implementation uses ChaCha20 **with HMAC-SHA256**, not the RFC's Poly1305 AEAD construction.
- RFC 4231: https://www.rfc-editor.org/rfc/rfc4231 . HMAC-SHA256 public test cases.
- FIPS 180-4, Secure Hash Standard: https://csrc.nist.gov/pubs/fips/180-4/upd1/final . SHA-256 reference. This package is not a FIPS-validated cryptographic module.

All implementation-specific claims should be checked against the supplied source, test output and SECURITY.md. Passing vector tests does not independently validate the complete application protocol.

## Chat Box APIs

- Advanced Peripherals 0.7 Chat Box: https://docs.advanced-peripherals.de/0.7/peripherals/chat_box/ — chat event UUID, hidden `$` messages, `sendMessageToPlayer` and cooldown-aware sending. This matches the methods reported by the user's `chat_box_0`.
- Advanced Peripherals 0.8 Chat Box: https://docs.advanced-peripherals.de/0.8/peripherals/chat_box/ — consolidated `sendMessage(message, options)` targeting. The adapter uses method detection and tests both forms with fixtures. Actual installed-mod behavior still needs in-world validation.
