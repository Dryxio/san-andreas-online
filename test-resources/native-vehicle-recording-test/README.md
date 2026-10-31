# Native vehicle recording test

This resource isolates GTA:SA's direct recorded-car playback from the Tagging
Up Turf mission. It uses Rockstar recording `207`, whose 35 frames move the
Greenwood from approximately `(2339.67, -1488.19, 23.61)` to
`(2381.07, -1528.44, 23.66)` in about eight seconds.

## Protocol

1. Start `native-vehicle-recording-test` and run `/nativecarrec`.
2. Confirm the Greenwood follows a smooth fixed trajectory at `2.0x` while
   Sweet remains in passenger seat 1 and the driver's seat remains empty.
3. Wait for `PASS`; it requires a natural native completion in 3-7 seconds,
   a server-observed endpoint within six metres, the same vehicle syncer, and
   Sweet still seated.
4. Run `/nativecarreccleanup` to restore the player's previous position.

Creating `headless.request` in the deployed resource invokes the same test on
the first connected player and is the non-interactive VM entry point.

The client reports request, load, start, natural completion, streaming loss,
and ownership loss separately. Cleanup stops an active native slot before the
server destroys the vehicle. Gameplay verification remains manual: Codex only
builds and deploys this resource, then asks the user to run the protocol.

## API under test

```text
requestVehicleRecording(recordingId)
recordingId = loadVehicleRecording(rrrBytes)       -- or false
isVehicleRecordingLoaded(recordingId)
startVehiclePlayback(vehicle, recordingId [, useCarAI=false [, looped=false]])
setVehiclePlaybackSpeed(vehicle, speed)
stopVehiclePlayback(vehicle)
isVehiclePlaybackActive(vehicle)
```

All functions are client-only and return a boolean. Direct playback requires a
streamed, unfrozen, non-blown vehicle owned by the calling client as a local
element or current unoccupied-vehicle syncer. An empty driver seat or a locally
synchronized script-ped driver is accepted; player drivers are rejected. This
isolated harness deliberately uses the empty-seat case, while Tagging Up Turf
uses Sweet as the script-ped driver from the original mission. The game layer
rejects unknown IDs, unloaded buffers, duplicate vehicle playback, and a full
16-slot native pool before calling GTA.

## Assembly gate

The compact US executable with SHA-256
`72ae59e44c761389e354a50dc6215e964fe771121e2f4b1877273a493ceecc9b` was
checked through the auto-re-agent/Ghidra workflow. The relevant native entry
points are request `0x45A020`, loaded test `0x45A060`, direct start `0x45A980`,
stop `0x45A280`, and active test `0x4594C0`. Opcode `05EB` calls the direct
start with both `useCarAI` and `looped` false. GTA owns exactly 16 simultaneous
slots and does not guard a full pool, duplicate vehicles, unknown recording
numbers, or unloaded buffers; Neon adds those checks without copying the
reconstructed playback loop.

Recording timestamps are game milliseconds: recording `207` ends at `7719`.
The playback loop multiplies `currentTime - PPPPreviousTime` by `0.25`, but the
PPP sample is four timer updates old, so that factor averages four frame deltas
rather than slowing playback by four. Timer truncation and Lua polling explain
the approximately 8.1-second wall-clock result observed by the harness.

Manual validation observed natural completion at `8087 ms` and `8088 ms` at
the default speed. The `2.0x` harness additionally validates opcode `06FD`.
Tagging Up Turf then completed the same recording in `8040 ms` with `0.00 m`
server-observed endpoint error before restoring Sweet as passenger and passing
the mission.

## Resource recordings and AI playback

`loadVehicleRecording(data)` loads a resource's own recording: the raw bytes of
a GTA `.rrr` file, i.e. N >= 2 `CVehicleStateEachFrame` records of 32 bytes
(`uint32` time in ms, `int16[3]` velocity x16383.5 in GTA units per frame,
`int8[3]` right and `int8[3]` up vectors x127, steering x20, gas x100,
brake x100, handbrake byte, `float[3]` position). Times must strictly increase
and positions be finite. It returns a recording number (50000 and up) owned by
the calling resource and freed when the resource stops, or `false`. Data sits
in a free GTA `CPath` slot after the IMG-registered ones (475 slots in total),
so GTA's own lookup, playback and reference counting apply. `requestVehicleRecording`
on such a number only reports that it is resident.

`startVehiclePlayback(vehicle, id, true)` uses GTA's AI playback (0x45A980 with
`useCarAI`, then `CHANGE_CAR_PLAYBACK_TO_USE_AI` 0x45A360):
`MISSION_FOLLOW_RECORDED_PATH` starts at the frame closest to the car, steers
towards the next frame at least 2 m ahead, weaves through traffic, keeps
collisions and targets the recorded speed times `setVehiclePlaybackSpeed`.
Frame times are ignored in this mode. It stops at the last frame; record every
lap in one recording. As with rigid playback, an ownership change stops the
slot; restarting on the new syncer resumes from the closest frame.
