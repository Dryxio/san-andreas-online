# Native wanted and police (version 1)

Server-authoritative wanted levels for every player, with GTA San Andreas's
own crime rules, foot cops that chase one named suspect each, and arrests
validated by the server. Tracking issue: #91.

Start it like any other resource (`start native-wanted-police`). Players get
stars from crimes, cops on foot come for them, and a cop that knocks them down
arrests them: **BUSTED**, a fine by stars, weapons taken, respawn at the
nearest police station. A gamemode can replace that outcome (see events).

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
- **Cops on foot, out of view.** They appear on GTA's own off-screen
  pedestrian spots, after every player within 150 m confirms the spot is off
  their screen, and close in. The model follows the area (LS, SF, LV or
  country sheriff). At 1 star they use the nightstick, unless you carry a gun.
  At exactly 4, 5 and 6 stars they are SWAT, FBI and army.
- **Every player has their own wanted level.** Two suspects next to each
  other never share cops.
- **Other players see your stars** above your head (setting `overheadStars`).
- **Arrest.** A cop that knocks you down within 3 m starts the arrest; you
  keep your hands up for 4 s, then **BUSTED**. The fine is $100 at 0-1 star,
  then $200, $400, $600, $900 and $1,500 at 6 stars (never below $0), weapons
  are taken, and you respawn at the nearest police station on your island.
  Dying (wasted) clears your stars.

## Exports (server)

| Function | What it does |
| --- | --- |
| `reportNativeCrime(player, crimeType [, victim])` | Report a crime (types 1-22, see `rules.lua`). Returns `false` when refused. |
| `getNativeWantedState(player)` | `{level, chaos, maximum, enabled, units, arrest, parole, backoff}` |
| `setNativeWantedEnabled(player, enabled)` | Turn wanted on or off for a player (off clears it). |
| `clearNativeWanted(player [, reason])` | Clear the stars. `reason = "parole"` is Pay 'n' Spray: a crime in the next 20 s brings the old level back. |
| `setNativeWantedLevel(player, level)` | Force a level (0-6), as GTA's `SetWantedLevel`. |
| `setNativeWantedMaximum(player, level)` | Cap the level (0-6). |
| `getNativePoliceUnits(player)` | The cops chasing that player. |
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
`neon:policePhase` on cops.

Set `neon:playerOwned = true` on vehicles that belong to a player (personal
cars, job vehicles): getting into them is then not car theft.

## Settings (`meta.xml`)

`maxCops` (24), `maxCopsPerSuspect` (10), `pvpCrimes` (true: hurting players
is a crime), `copLostDistance` (220 m), `ownerRange` (90 m),
`overheadStars` (true), `bustedText` (true).

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
- Cops are ordinary MTA peds made by this resource. They never borrow
  traffic peds. GTA's own cop tasks are never used: they read the local
  player's wanted level and need real GTA cops. Instead each cop gets
  `setPedKillOnFoot` aimed at its suspect. The binary shows GTA's "kill
  criminal" reaction cannot start on a Neon ped (every MTA player and ped is a
  player-type `CPlayerPed`, which that task refuses).
- One client runs each cop: preferably another player within 90 m of the cop,
  else the suspect. A watchdog checks every cop keeps closing in. A cop that
  stalls for 7 s moves to another player (who is then skipped for 20 s);
  after three stalls it is replaced. A cop that moves faster than it can run
  also changes owner.
- Cops leave only when no nearby player has them on screen (90 s limit, and
  at most twice `maxCops` waiting).

## Limits of version 1

- No police cars, roadblocks or helicopters yet. Foot cops arrive at about the
  rate solo sends cars (one every 6 s at 1 star, down to 1.5 s at 4+). The
  stars GTA gives for police cars in service (stealing one, hitting one, a car
  alarm near a cop) come with them.
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
- Not yet tested in game.

## Tests

From the repository root:

```bash
lua official-resources/native-wanted-police/tests/rules_spec.lua
lua official-resources/native-wanted-police/tests/server_spec.lua
```
