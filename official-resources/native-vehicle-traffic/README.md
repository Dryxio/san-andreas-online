# Native vehicle traffic V2

This resource keeps ambient road vehicles network-owned while using GTA only
for its road placement and owner-local driving AI.

Scope: stock civilian road cars, vans, trucks, motorcycles, BMX bicycles and
quads in world 0. Each atomic unit contains a network vehicle, one script-ped
driver and optional script-ped passengers. The common owner runs GTA's native
`DriveWander`; observers receive ordinary ped/vehicle sync and never run the
driving task. Owner epochs, streamed leases, contextual models, GTA lane
placement, smooth handoff, density bubbles, player passenger entry/takeover,
stuck recovery, destruction and cleanup are part of the same lifecycle.

Drivers and passengers keep their existing ped elements when a player steals
the driver’s seat or an incident ends road driving. GTA can drag the occupant
out, get them upright, and choose a flee, fight or vehicle-recovery reaction.
Other clients receive the normal MTA ped/vehicle synchronization. Surviving
passengers and visible bodies have independent ownership and cleanup, so a
passenger travelling away cannot make a nearby former driver disappear.
Player entry into a free passenger seat keeps the road activity running.
Extracting an occupied passenger is not exposed by stock MTA's entry protocol;
it redirects passenger requests to a free seat before this resource's handler.

Retained actors choose a ready owner within 220 units in the same world. They
are removed after 60 seconds without a nearby player; their departure never
deletes the retained vehicle. `cartraffic cleanup` also clears retained actors.
Stopping the resource releases their profiles and streaming references.

Ownership handoff preserves supported remaining flee, fight, leave, enter and
reclaim tasks, preferring persistent intent over a temporary avoidance reaction.
This is semantic continuation: native timers restart and decorative pauses,
heading changes and fist gestures are omitted. Unsupported responses, missing
targets or unavailable streaming cannot be restored; the client reports a
restore timeout when a received continuation remains unavailable. A newly
selected native response takes precedence over an older snapshot.

The contact bridge covers stock unarmed occupants hitting remote players and
remote players' unarmed hits supplying missing NPC reactions. It validates the
owner, epoch, distance, cadence and native damage factor. Cross-owner NPC-to-NPC
and armed damage relays are not provided by this resource.

Boats, aircraft, trailers, parked car generators, mission routes, emergency
response and service-specific gameplay remain outside this civilian-road
checkpoint. Model distribution follows GTA popcycle/car-group context through
an explicit road-safe pool because MTA deliberately disables the retail
ambient vehicle streamer.

The exact test executable audited for the road oracle is the VM-local
`gta_sa.exe` with SHA-256
`A559AA772FD136379155EFA71F00C47AAD34BBFEAE6196B0FE1047D0645CBD26`.
`CCarCtrl::GenerateCarCreationCoors2` at `0x424210` is called only on the
candidate owner and returns scalar position, heading, lane, speed and style
data. Native path addresses and autopilot internals are never serialized.
Vehicle and occupant models are explicitly loaded before proposal. Server-side
creation remains atomic: vehicle plus every occupant, or zero.

Script-created Wander vehicles pass through GTA's generic road rejoin. Neon
validates the resulting directed edge against the retail lane-bit selection.
If GTA selects an unrelated neighbouring edge, Neon compares loaded directed
segments against the vehicle's lane position, heading and height, and changes
the route only when the candidate is materially better. The closed regression
covers both LS Airport tunnel carriageways, five San Fierro freeway candidates
captured from the public build 183 session, and a multi-branch road join. This
keeps initial spawns and ownership handoffs on the legal carriageway without
transporting process-local path pointers.

Runtime controls:

```text
cartraffic start [target-per-player] [global-cap]
cartraffic demo on|off
cartraffic status
cartraffic stop
cartraffic cleanup
```

Production traffic starts automatically at sixteen vehicles per spatial player
bubble, with a global circuit breaker of 160 vehicles. Players within 180 world
units share one bubble; isolated groups receive separate budgets. When the
global cap is reached, units are distributed fairly between bubbles instead of
being concentrated around the largest group. Vehicle creation shares a
416-element server-side ped fence with the walking population and reserves
every required driver before it admits optional passengers. Staff may use
`cartraffic start [target-per-bubble] [global-cap]` to change the live profile.
Traffic control and test commands reject players without server-staff rights.
New players enter the traffic owner/observer pool only after their client has
confirmed that every synchronized-traffic event handler is ready.

New units remain invisible during their short synchronized-owner staging
window. Once the owner proves that `DriveWander` is installed, it applies the
road-aligned cruise velocity from the settled vehicle matrix and the server
reveals the complete vehicle/occupant unit. This prevents frozen, partially
settled cars from appearing before their native driving state is active.

With `native-ped-traffic` running, `/trafficdemo on` is the coordinated visual
demo preset: with exactly two clients it targets 16 road vehicles while the ped
resource targets 32 on-foot NPCs. Demo vehicles keep their drivers but omit
optional passengers so the combined ped-pool budget is deterministic.
`/trafficdemo off` destroys the demo units and restores the population settings
that were active beforehand.

With exactly two clients in world 0, the checkpoint harness is:

```text
cartraffic test all
cartraffic test smooth
cartraffic test ownerquit
cartraffic test lifecycle
cartraffic test density
cartraffic test spatial
cartraffic test passengers
cartraffic test classes
cartraffic test interaction
cartraffic test highway
cartraffic test soak [cycles]
cartraffic cleanup
```

`all` covers the base fixture and a distinct A-to-B handoff. `smooth` performs
A-to-B-to-A transfer with velocity restoration and bounded pose/heading jumps.
`ownerquit` pauses at `owner-quit-ready`; terminate that exact client process to
exercise a real disconnect and require resumed motion on the survivor.
`lifecycle` forces one stuck recovery and destruction. `density` fills four
simultaneous units. `spatial` separates the two player bubbles, merges them and
checks cap 2-to-1-to-2 reconciliation. `passengers` validates atomic seats and
handoff. `classes` covers car, van, truck, motorcycle, BMX and quad.
`interaction` uses GTA's real enter/exit tasks for a player passenger ride and
driver takeover; it does not synthesize lifecycle events or warp the player
into the vehicle. It respawns its players, so it also works without a gamemode,
and retains a rear-seat NPC while the human uses the front passenger seat.

`highway` deterministically replays both legal lane poses from the LS Airport
tunnel regression. Each vehicle must travel at least 25 metres in its expected
direction without a sustained U-turn or leaving its carriageway.

`soak` deliberately cycles the core fixture/handoff/passenger/lifecycle paths
and reports `PASS-soak-core`. A V2 freeze additionally requires the individual
`classes`, `interaction`, `spatial` and `ownerquit` verdicts. Every terminal
test passes only after exact participants acknowledge task shutdown, restored
mission-actor state, released streaming leases and empty local registries.
Observer samples are monotonic and correlated to unique recent server poses.

Detailed logs are off by default (`*debug=false` in `meta.xml`). Server staff
can use `/cartraffic debug on|off`; the choice persists across resource restarts.
Failures, test verdicts and explicit status output remain available with debug
off. Tests temporarily enable client diagnostics and detailed server traces.

With debug or a test enabled, the authoritative trace is the server log's
`[car-traffic]` JSON stream. Native
placement is probabilistic, so individual `candidate-retry` entries are normal;
only a terminal `PASS-*` or `FAIL` entry is a harness verdict.

With debug enabled, production also emits `population-snapshot` every 15 seconds. It records the
desired and live population, allocation and distance range for every spatial
bubble, lifecycle and motion states, ped-pool pressure, and event/reason counts
since the previous snapshot. `motion-anomaly` means owner samples remained
aligned against the vehicle heading for at least two seconds; it is rate-limited
per unit and followed by `motion-recovered` when forward travel resumes.

## Network reporting

Periodic owner/observer samples are grouped per client every 500 ms, with at
most 32 samples per event. Only the newest pending sample for each unit, epoch
and role is kept; released units and old epochs are discarded. Lifecycle
acknowledgements and failures are sent immediately. The server retains the
per-unit sender, epoch and sequence checks. Detailed client diagnostics are
sent only with debug enabled or during a test.

Production candidate retries back off from 150 ms to at most 1 second after
repeated misses or visibility vetoes. Population targets and candidate
reservation limits are unchanged; harness retries retain their 50 ms interval.

Run `lua official-resources/native-vehicle-traffic/tests/transport_test.lua` from
the repository root for mocked transport and logging checks. The fixture
reduces 32 periodic events (16 vehicles over two sampling cycles) to two
batches. This measures event envelopes, not total bytes or live-server load;
spawn bursts and other resources still count toward the server event limit.

## Occupant continuation API

Client-side `table|false getPedNativeVehicleResponse(ped, token)` captures up to
eight remaining supported native response steps for a synchronized script ped.
The token must belong to this resource's native event-profile lease. An empty
table means no remaining semantic step; `false` means unavailable or unsupported.
Each step contains `type`, optional element references `target` and `vehicle`,
and eight numeric `values`. Treat this as an opaque, version-specific descriptor;
do not build native task data from arbitrary network messages.

Client-side `bool restorePedNativeVehicleResponse(ped, steps, token)` requires a
living synchronized ped with an active resource-owned profile, available native
targets, empty native response slots and valid supported descriptors. It returns
`false` when those conditions fail. It creates native tasks with registered
entity references; pointers and animation memory are never transported. A
ScreamInCarThenLeave snapshot is rejected if the ped has already left that car.

These functions are registered in `Client/mods/deathmatch/logic/luadefs/CLuaPedDefs.cpp`;
the native implementation is in `Client/game_sa/CPedSA.cpp`. The focused client
and server lifecycle tests are `tests/occupant_client_spec.lua` and
`tests/occupant_lifecycle_spec.lua`. The two-client `cartraffic test interaction`
harness additionally checks that the former driver remains the same element
three seconds after the player takes the vehicle. Each connected client must
then report the original driver and passenger streamed and visible, with the
former driver outside the original vehicle.
