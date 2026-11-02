# Native wanted and police (version 2)

Server-authoritative wanted levels for every player, with GTA San Andreas's
own crime rules, police cars and cops that chase one named suspect each, and
arrests validated by the server. Tracking issue: #91.

Start it like any other resource (`start native-wanted-police`). Players get
stars from crimes, street cops and police cars come for them, and a cop that
knocks them down, or catches them in a stopped car, arrests them: **BUSTED**,
a fine by stars, weapons taken, respawn at the nearest police station. A
gamemode can replace that outcome (see events).

Police cars need a client built after 2026-11-02 to ram and block (GTA's car
missions on the suspect's vehicle). Older clients still get the cars; they
drive to the suspect instead.

## What players get

- **Stars from crimes, as in solo.** Each crime adds GTA's "chaos" points, and
  the stars follow GTA's thresholds (50, 180, 550, 1,200, 2,400, 4,600). A cop
  within range of the offender (14 m; 30 m for a destroyed vehicle; 60 m for
  explosions and aircraft) makes a crime count at once with at least one
  star. No civilian witness is needed: an unseen crime still counts half a
  second later. A cop you hit or shoot is usually within that range, so the
  first star comes at once.
  - Shooting: firing near a cop, plus each ped hit (cops count for more).
  - Hitting, knifing, running people over, explosions, destroying vehicles,
    punching cars, aiming at a cop, getting into a vehicle for the first time
    (GTA counts that as car theft).
  - Crimes against gang members, dealers and criminals count a third.
- **Stars go down as in solo.** One star fades when no cop (or police car
  driven by a cop) is within 18 m. Two stars or more only fade outside in the
  countryside or desert, also only without a cop within 18 m. In Los Santos,
  San Fierro, Las Venturas or inside, they stay until you are busted, die, or
  the gamemode clears them (Pay 'n' Spray, bribe). Riding a police vehicle,
  helicopter or plane stops the fading.
- **Street cops join the chase.** With `native-ped-traffic` running, a cop
  already walking the street goes after the nearest wanted player, as in
  solo: no distance limit beyond the cop being there (`copLostDistance`
  here), up to the level's pursuit cap (1, 3, 4, 6, 8, 10 cops). When the
  chase is full, a closer street cop replaces the farthest pursuer. A foot
  cop ignores a suspect driving past and goes for one that stops (GTA's
  speed x distance limit). The cop the player sees is the one that comes.
- **Police cars from 2 stars, as in solo.** At 1 star only cops already on
  the street come. From 2 stars cars are sent, at most 2 at 2-4 stars and 3
  at 5-6, the next one more than 8 s after the last at 2 stars, 5 s at 3, at
  once from 4. They appear on GTA's own road spots out of everyone's view.
  - **Which car:** LSPD, SFPD or LVPD cruiser, or the Ranger in the
    countryside, with two cops of that area. At 4 stars one car in three is a
    SWAT Enforcer (four SWAT), at 5 stars always an FBI Rancher (four
    agents), at 6 stars army Barracks (two soldiers) or a Rhino. From 3 stars
    one cop in four of a cruiser carries a shotgun.
  - **How it drives:** it blocks your car 3 times in 4 at 2 stars, half the
    time at 3 stars and once in 4 from 4 stars, and rams it otherwise. It
    never rams a bike, and its siren comes on up close. Its speed follows
    the level; at 2 stars it slows down near you.
  - **Getting out:** within 10 m, when you are on foot, your car is on its
    roof, or it has stood still for 2.5 s, the car stops. The passenger gets
    out at once, the driver after 3-5 s, unless you drive off first. On foot
    they chase you like any cop.
  - **Getting back in:** when you drive away (or are more than 100 m off in
    a car), the driver runs back to his car if it is within 16 m and drives
    after you again. Passengers stay on foot.
- **Cops on foot, out of view**, only where no police car can be placed (no
  road nearby, two failed placements in a row). They appear on GTA's own
  off-screen pedestrian spots, after every player within 150 m confirms the
  spot is off their screen, and close in. The model follows the area (LS,
  SF, LV or country sheriff). At 1 star they use the nightstick, unless you
  carry a gun. At exactly 4, 5 and 6 stars they are SWAT, FBI and army.
- **Every player has their own wanted level.** Two suspects next to each
  other never share cops.
- **Other players see your stars** above your head (setting `overheadStars`).
- **Arrest.** A cop that knocks you down within 3 m starts the arrest; you
  keep your hands up for 4 s, then **BUSTED**. In a car that has stood still
  for 2.5 s, a cop on foot within 4 m pulls you out first (you are taken out
  after 3 s if your client does not leave the car). The fine is $100 at 0-1 star,
  then $200, $400, $600, $900 and $1,500 at 6 stars (never below $0), weapons
  are taken, and you respawn at the nearest police station on your island.
  Dying (wasted) clears your stars.

## Exports (server)

| Function | What it does |
| --- | --- |
| `reportNativeCrime(player, crimeType [, victim])` | Report a crime (types 1-22, see `rules.lua`). Returns `false` when refused. |
| `getNativeWantedState(player)` | `{level, chaos, maximum, enabled, units, cars, arrest, parole, backoff}` |
| `setNativeWantedEnabled(player, enabled)` | Turn wanted on or off for a player (off clears it). |
| `clearNativeWanted(player [, reason])` | Clear the stars. `reason = "parole"` is Pay 'n' Spray: a crime in the next 20 s brings the old level back. |
| `setNativeWantedLevel(player, level)` | Force a level (0-6), as GTA's `SetWantedLevel`. |
| `setNativeWantedMaximum(player, level)` | Cap the level (0-6). |
| `getNativePoliceUnits(player)` | The cops chasing that player (on foot or in a car). |
| `getNativePoliceCars(player)` | The police cars chasing that player. |
| `requestNativePoliceBackoff(player, ms)` | Cops break off for a while; the stars stay. |

## Events (server, source = the player)

| Event | Arguments | Cancel to |
| --- | --- | --- |
| `onNativeCrimeValidated` | `crimeType, victim, origin` | ignore the crime (police job, safe zone) |
| `onNativeCrimeReported` | `crimeType, victim, immediate` | |
| `onNativeWantedLevelChange` | `oldLevel, newLevel, reason` | |
| `onNativeSuspectEscaped` | `oldLevel` | |
| `onNativePlayerArrestAttempt` | `cop` | refuse this arrest |
| `onNativePlayerArrested` | `level, fine, stationName, x, y, z, rotation` | apply your own outcome (the stars are cleared either way); the coordinates are the station's respawn point |
| `onNativePoliceUnitStateChange` (source = cop) | `suspect, phase` | |

`victim` is `false` when the crime has none.

Element data (written by the server with client changes denied):
`neon:wantedLevel` on players; `neon:police`, `neon:policeSuspect`,
`neon:policePhase` on cops; `neon:policeCar`, `neon:policeCarPhase` on police
cars.

Set `neon:playerOwned = true` on vehicles that belong to a player (personal
cars, job vehicles): getting into them is then not car theft.

## Settings (`meta.xml`)

`maxCops` (24), `maxCopsPerSuspect` (10), `pvpCrimes` (true: hurting players
is a crime), `copLostDistance` (220 m), `ownerRange` (90 m),
`overheadStars` (true), `bustedText` (true), `streetCops` (true: street cops
from `native-ped-traffic` join the chase), `policeCars` (true: cars from 2
stars; false: version 1's foot cops at every level), `maxCars` (12),
`maxCarsPerSuspect` (3). Settings changes apply without a restart.

## How it works

- `rules.lua` reproduces GTA's wanted rules. Every value and rule was read in
  the GTA SA 1.0 US binary (not taken from gta-reversed); the addresses are
  listed at the top of the file, and the tests check them.
- The server keeps one ledger per player. GTA's own wanted system stays off
  (MTA disables it) because it can only hold one suspect, and every Neon ped
  points at the local player's wanted data. `setPlayerWantedLevel` is only
  used to show the suspect's own HUD stars.
- Crimes are reported the way GTA reports them: a bullet impact reports
  "firing" and "shooting a ped"; every hit reports "damaging a ped", plus a
  queued crime chosen by weapon (hitting, shooting or running over, cop or
  not); being run over and stealth kills report their own crimes. One hit
  often arrives from several places (bullet sync, the victim's syncer, the
  death event); it is counted once.
- Damage the server cannot see is reported by the victim's syncer, the
  victim player or the attacker. The server checks who may report it, that
  the attacker is close enough and holds that weapon, and a rate limit.
  Collisions are never taken from the damaged car's own driver. Victim types
  come from the ped's model, never from element data.
- Cops are ordinary MTA peds: the ones this resource creates, and street
  cops taken over from `native-ped-traffic` through its `releaseTrafficCop`
  export (the traffic resource drops the cop's record and ambient profile,
  then it belongs to this resource only; two resources never drive the same
  ped). The join rule is GTA's: `CTaskComplexWanderCop` (0x674D80),
  `CanCopJoinPursuit` (0x562F60), `ComputePursuitCopToDisplace` (0x562B00)
  and `CTaskComplexPolicePursuit::SetPursuit` (0x68BBD0).
- Police cars follow solo's rules read in the binary:
  `CCarCtrl::GenerateOneRandomCar` 0x430050 (when a car is sent), 0x421980
  and 0x407C50 (which model), `CCarAI::AddPoliceCarOccupants` 0x41C070 (who
  rides), 0x41C9D0 and 0x41CAA0 (ram or block, speed), `CCarAI::UpdateCarAI`
  0x41DA30 and 0x41D3D0 (close range, getting out), `CTaskComplexCopInCar`
  0x68FD50 (driver delay, getting back in). Solo's police missions 2 and 4
  read the local player, so the car is given the car-target missions 15 and
  17 (ram or block the suspect's vehicle), which follow the road the same
  way; up close, blocking steers the same, ramming without solo's side
  offset. The server decides when a car stops, who gets out and who gets
  back in; the client that syncs the car runs its driver and carries out
  the orders. A car and its crew always have the same owner.
- GTA's own cop tasks are never used: they read the local
  player's wanted level and need real GTA cops. Instead each cop gets
  `setPedKillOnFoot` aimed at its suspect, and is a mission actor
  (`setPedMissionActor`) so it shoots at that target: MTA otherwise sends a
  script ped's shots through the player branch of `FireInstantHit`
  (0x74034C), which ignores the AI's target. The binary shows GTA's "kill
  criminal" reaction cannot start on a Neon ped (every MTA player and ped is a
  player-type `CPlayerPed`, which that task refuses).
- One client runs each cop: preferably another player within 90 m of the cop,
  else the suspect. A watchdog checks every cop keeps closing in. A cop that
  stalls for 7 s moves to another player (who is then skipped for 20 s);
  after three stalls it is replaced. A cop that moves faster than it can run
  also changes owner.
- Cops leave only when no nearby player has them on screen (90 s limit, and
  at most twice `maxCops` waiting).

## Limits of version 2

- No roadblocks, helicopters, police bikes or boats yet. Cops in cars never
  shoot from them (solo does not either; only bike cops and the boat gunner
  do).
- A car alarm going off near a cop does not count yet.
- Police cars only drive where GTA has road paths. Off-road, foot cops stand
  in.
- A police car a player takes becomes an ordinary vehicle that this resource
  no longer removes; cops still inside get out.
- From 3 stars, police cars run a few percent faster than solo's: GTA scales
  the drag-limited top speed, the server can only read the handling top
  speed.
- Hitting a police car counts as crime 8 when the server sees the shot, the
  attacker reports it, or the client running the car reports a collision
  with the attacker's vehicle within 12 m. A police car that rams the
  suspect also counts against him, as the collision is the same.
- Setting fire to people and cars (crimes 13-15) is not detected yet.
- A cheating client can hide its own crimes. A malicious syncer can only
  blame a player who was close enough and held that weapon.
- When the suspect is the only player nearby, their own client runs the cops.
  The watchdog replaces cops that do not chase, but a cheater can still keep
  them idle.
- The arrest uses GTA's hands-up task (or its animation on builds before
  2026-11-01), not the native "being arrested" task. The 4 s hold before
  BUSTED is a Neon choice. A suspect who stands still next to a cop for 2.5 s
  is also arrested, so a client that never reports being knocked down cannot
  avoid it.
- Cops only work in dimension 0, outside interiors. Going inside sends them
  away; the stars stay.
- A street cop that leaves the chase does not go back to traffic: it walks
  away and is removed once nobody sees it, and traffic spawns new people as
  usual. `native-vehicle-traffic` has no police cars yet, so only cops on
  foot join.
- Police cars are not yet tested in game.

## Tests

From the repository root:

```bash
lua official-resources/native-wanted-police/tests/rules_spec.lua
lua official-resources/native-wanted-police/tests/server_spec.lua
lua official-resources/native-ped-traffic/tests/release_contract.lua
```
