# MTA Mobile two-session gameplay test

Use this resource on a **private, single-tester Neon server** to check whether an Android player can join, run a client script, spawn and reconnect. It selects the first player who joins after startup. It can spawn that player in Los Santos. Packet logging and the server's admission policy stay under the server operator's control.

## Run on a phone

1. Copy this directory to `mods/deathmatch/resources/android-session-test`. In the server console run `refresh`, ensure the shipped `scoreboard` resource is running, then run `start android-session-test`. Start the test before the phone joins.
2. Join from the phone. Wait for the client-resource chat message and confirm the player and world are visible. After the first rendered frame, both resource-start acknowledgements and a player spawn, the server logs `observing 60 seconds`. Stay in the game. A minute later it asks the same player for another rendered frame. A reply within 15 seconds produces the `ready` message. A stalled client produces `INCOMPLETE`.
3. After the server logs `session=1 ready`, disconnect normally. Wait for `session=1 quit`, reconnect from the same installation, and repeat the visual check. After `session=2 ready`, disconnect normally again. The server logs `PASS two joined sessions with resource execution and spawn` after that second quit. A kick or connection loss ends the run as `INCOMPLETE`, including after a spawn.
4. Run `stop android-session-test` after the test. Restart the resource to begin a fresh run after an interrupted attempt.

The server uses the tester's serial in memory to correlate the two sessions. The callback is a client report. A pass describes gameplay for that run. Android device attestation and the anti-cheat decision require independent evidence. If the phone times out before the join event, record the client error and the number of joins the server observed.

## Run the event tests

From this directory run `lua5.1 tests/session.lua`. It loads the same server and client Lua files as the game. The fixtures cover event ordering, early and duplicate frame reports, the wrong participant, the one-minute deadline, a spawn from another resource, an interrupted first session, and a kick after spawning on either connection. A physical phone run exercises networking and rendering.

### Private USB route for a physical Android test

Use this when the phone can fetch resources over Wi-Fi but a UDP round-trip control fails. The helper carries complete UDP datagrams over an ADB reverse TCP connection. Both listeners bind to loopback. This tests gameplay and default server policy over a controlled route. It does not measure normal Internet UDP latency or loss.

1. On the machine that can reach the private server, run `python3 tools/usb/host.py SERVER_IPV4 GAME_PORT`. If that machine is remote, forward TCP 42673 to its loopback listener over SSH. Also forward a local TCP port to the game's configured HTTP endpoint.
2. From `tools/usb`, compile `LocalGameLink.java` with `javac --release 8 LocalGameLink.java`, then run the Android SDK build tool `d8 --min-api 26 --output game-link.jar LocalGameLink.class`. Push the jar with `adb push game-link.jar /data/local/tmp/neon-game-link.jar` and run `adb shell chmod 444 /data/local/tmp/neon-game-link.jar`.
3. Run `adb reverse tcp:42673 tcp:42673`. Forward the **HTTP port the game actually advertises** with `adb reverse tcp:ADVERTISED_HTTP_PORT tcp:LOCAL_HTTP_PORT`. For an HTTP server on the ADB host, the local port is its listening port. Use a separate lab instance and the server's normal packetlogger, anti-cheat and HTTP settings.
4. Run `adb shell 'CLASSPATH=/data/local/tmp/neon-game-link.jar app_process / LocalGameLink'` and join `127.0.0.1:22003` from the launcher. Match the first and second session markers on the server. Use a separate test-resource run for a desktop control because the resource binds the first participant.
5. Stop the test helper, remove both reverse mappings with `adb reverse --remove tcp:PORT`, remove the device jar, and stop the host listener and any SSH forwarding.
