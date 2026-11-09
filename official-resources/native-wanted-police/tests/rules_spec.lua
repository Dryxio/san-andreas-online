-- Run from the repository root: lua official-resources/native-wanted-police/tests/rules_spec.lua
-- Checks rules.lua against the values read in the GTA SA 1.0 US binary.
dofile('official-resources/native-wanted-police/rules.lua')
local R = NativeWantedRules
local passed = 0
local function check(name, condition)
    if not condition then error('FAILED: ' .. name, 2) end
    passed = passed + 1
end

-- Thresholds are inclusive (UpdateWantedLevel 0x561C90).
check('49 chaos is 0 stars', R.levelForChaos(49) == 0)
check('50 chaos is 1 star', R.levelForChaos(50) == 1)
check('179 chaos is 1 star', R.levelForChaos(179) == 1)
check('180 chaos is 2 stars', R.levelForChaos(180) == 2)
check('550 is 3', R.levelForChaos(550) == 3)
check('1200 is 4', R.levelForChaos(1200) == 4)
check('2400 is 5', R.levelForChaos(2400) == 5)
check('4600 is 6', R.levelForChaos(4600) == 6)
check('5 stars allow 8 cops and 3 cars', R.caps[5].cops == 8 and R.caps[5].cars == 3)
check('1 star caps 1 cop', R.caps[1].cops == 1)

-- Weights (ReportCrimeNow 0x562120 jump table).
local expected = {[1] = 0, [2] = 5, [3] = 45, [4] = 30, [5] = 80, [6] = 15, [7] = 10, [8] = 5, [9] = 5, [10] = 18,
                  [11] = 80, [12] = 400, [13] = 20, [14] = 80, [15] = 20, [16] = 400, [17] = 25, [18] = 35,
                  [19] = 100, [20] = 70, [21] = 2, [22] = 2}
for crimeType, weight in pairs(expected) do check('weight ' .. crimeType, R.weights[crimeType] == weight) end

-- Detection radii (0x531FC0).
check('explosion radius 60', R.detectionRange(17) == 60)
check('heli radius 60', R.detectionRange(12) == 60)
check('plane radius 60', R.detectionRange(16) == 60)
check('vehicle destroyed radius 30', R.detectionRange(20) == 30)
check('default radius 14', R.detectionRange(4) == 14)

-- A crime with no police nearby is queued and counted 500 ms later.
local w = R.new(0)
local changed, immediate = R.report(w, 4, 'ped1', {}, 1000)
check('queued crime is not immediate', immediate == false and w.chaos == 0)
R.tick(w, 1400, {region = 'la'})
check('not reported before 500 ms', w.chaos == 0)
R.tick(w, 2000, {region = 'la', policeNearby = true})
check('the queue only runs on the 1 s wanted tick', w.chaos == 0)
R.tick(w, 2401, {region = 'la', policeNearby = true})
check('queued crime counted after 500 ms', w.chaos == 30)
check('30 chaos is no star', w.level == 0)

-- The same (type, victim) inside 10 s is counted once.
R.report(w, 4, 'ped1', {}, 2500)
R.tick(w, 3200, {region = 'la', policeNearby = true})
check('duplicate ignored', w.chaos == 30)
-- After the entry expires (10 s) the same crime counts again.
R.tick(w, 11100, {region = 'la', policeNearby = true})
R.report(w, 4, 'ped1', {}, 11200)
R.tick(w, 11800, {region = 'la', policeNearby = true})
check('counts again after 10 s', w.chaos == 60 and w.level == 1)

-- Police present: immediate and at least one star.
w = R.new(0)
changed, immediate = R.report(w, 2, 'ped2', {policePresent = true}, 100)
check('immediate with police', immediate and w.chaos >= 50 and w.level == 1)
check('noDrop(1) writes 70 chaos then the crime does not lower it', w.chaos == 70)

-- Firing a weapon alone adds nothing unless police are near.
w = R.new(0)
R.report(w, 1, 'crime1', {}, 0)
R.tick(w, 1600, {region = 'la', policeNearby = true})
check('firing alone gives nothing', w.chaos == 0 and w.level == 0)
R.report(w, 1, 'crime1b', {policePresent = true}, 2000)
check('firing near police gives a star', w.level == 1)

-- Minimum stars: punching a cop >= 1, shooting/stabbing a cop >= 2.
w = R.new(0)
R.report(w, 3, 'cop1', {}, 0)
check('punch cop 1 star', w.level == 1)
w = R.new(0)
R.report(w, 5, 'cop1', {}, 0)
check('shoot cop 2 stars', w.level == 2 and w.chaos == 200)
w = R.new(0)
R.report(w, 19, 'cop1', {}, 0)
check('stab cop 2 stars', w.level == 2)

-- Gang/dealer victims: x0.333.
w = R.new(0)
R.reportNow(w, 4, {policeDontCare = true}, 0)
check('gang victim weight x0.333', w.chaos == 9)

-- Queue holds 16 entries; a 17th distinct crime is dropped.
w = R.new(0)
for i = 1, 17 do R.report(w, 2, 'v' .. i, {}, 0) end
check('queue capped at 16', #w.queue == 16)

-- Decay (CWanted::Update 0x562C90).
w = R.new(0)
R.setLevel(w, 1, 0)
check('setLevel(1) is 70 chaos', w.chaos == 70)
R.tick(w, 1000, {region = 'la'})
check('tick needs more than 1000 ms', w.chaos == 70)
R.tick(w, 1001, {region = 'la'})
check('1 star in the city: -1', w.chaos == 69)
R.tick(w, 2002, {region = 'countryside'})
check('1 star in countryside: -2', w.chaos == 67)
R.tick(w, 3100, {region = 'la', policeNearby = true})
check('no decay with police within 18 m', w.chaos == 67)
check('police nearby keeps the decay clock', w.lastDecay == 2002)
R.tick(w, 3300, {region = 'la', inLawVehicleOrAircraft = true})
check('no decay in a police vehicle or aircraft', w.chaos == 67 and w.lastDecay == 3300)

w = R.new(0)
R.setLevel(w, 2, 0)
R.tick(w, 1100, {region = 'la'})
check('2 stars never decay in the city', w.chaos == 200)
R.tick(w, 2200, {region = 'desert', interior = true})
check('2 stars never decay inside', w.chaos == 200)
R.tick(w, 3300, {region = 'desert'})
check('2 stars decay outside in the desert', w.chaos == 198)
R.tick(w, 4400, {region = 'desert', policeNearby = true})
check('2 stars rural decay also needs no police within 18 m', w.chaos == 198)

-- Decaying below a threshold drops a star.
w = R.new(0)
w.chaos = 50; w.level = 1
R.tick(w, 1100, {region = 'la'})
check('49 chaos drops to 0 stars', w.level == 0)

-- Parole (Pay 'n' Spray): a crime within 20 s restores the old chaos.
w = R.new(0)
R.setLevel(w, 3, 0)
R.clearOnParole(w, 1000)
check('parole clears', w.level == 0 and w.chaos == 0)
R.report(w, 2, 'p1', {policePresent = true}, 5000)
check('crime during parole restores level 3', w.level == 3 and w.chaos >= 570)
w = R.new(0)
R.setLevel(w, 3, 0)
R.clearOnParole(w, 1000)
R.tick(w, 21100, {region = 'la'})
R.report(w, 2, 'p1', {policePresent = true}, 22000)
check('parole expires after 20 s', w.level == 1)

-- Maximum level (SetMaximumWantedLevel 0x561E70).
w = R.new(0)
R.setMaximum(w, 2, 0)
R.reportNow(w, 12, {}, 0)
check('maximum 2 caps chaos at 365', w.chaos == 365 and w.level == 2)
R.setLevel(w, 5, 0)
check('setLevel respects the maximum', w.level == 2)

-- Weather regions (0x72A640).
check('Grove Street is LA', R.region(2495, -1687) == 'la')
check('Doherty is SF', R.region(-2050, 150) == 'sf')
check('The Strip is LV', R.region(2030, 1500) == 'lv')
check('Fort Carson weather region is countryside', R.region(-200, 1000) == 'countryside')
check('Las Barrancas is desert', R.region(-750, 1500) == 'desert')
check('Red County is countryside', R.region(700, -500) == 'countryside')

-- Busted fines and stations.
check('fine at 1 star', R.bustedFine(1) == 100)
check('fine at 6 stars', R.bustedFine(6) == 1500)
check('nearest station to Grove is LSPD', R.nearestStation(2495, -1687, 13)[5] == 'Los Santos')
check('nearest station to the Strip is LVPD', R.nearestStation(2030, 1500, 10)[5] == 'Las Venturas')
check('seven stations', #R.policeStations == 7)

-- Damage -> queued crime (ReportCriminalEvent 0x4B3440).
check('fist on cop queues 3', R.damageQueuedCrime('cop', 0) == 3)
check('knife counts as hitting (weapon < 10)', R.damageQueuedCrime('civilian', 4) == 2)
check('chainsaw counts as hitting', R.damageQueuedCrime('cop', 9) == 3)
check('dildo counts as shooting (10-41)', R.damageQueuedCrime('civilian', 10) == 4)
check('pistol on cop queues 5', R.damageQueuedCrime('cop', 22) == 5)
check('flamethrower on cop queues 5', R.damageQueuedCrime('cop', 37) == 5)
check('run over ped queues 10', R.damageQueuedCrime('civilian', 50) == 10)
check('run over cop queues 11', R.damageQueuedCrime('cop', 49) == 11)
check('fall damage is no crime', R.damageQueuedCrime('civilian', 54) == nil)
check('explosion damage queues nothing', R.damageQueuedCrime('civilian', 51) == nil)
check('gangs: police do not care', R.policeDontCare('gang'))
check('criminals and dealers: police do not care', R.policeDontCare(R.pedClassForModel(28)) and R.policeDontCare(R.pedClassForModel(254)))
check('civilians count fully', not R.policeDontCare(R.pedClassForModel(7)))
check('cop model class', R.pedClassForModel(285) == 'cop')
check('Grove gang model', R.pedClassForModel(105) == 'gang')
check('Patriot is not a police vehicle', R.lawVehicles[470] == nil and R.lawVehicles[596] and R.lawVehicles[497])

-- Queue-only crimes (RegisterCrime): never immediate, no minimum stars.
w = R.new(0)
changed, immediate = R.report(w, 5, 'cop9', {policePresent = true, queueOnly = true}, 0)
check('queued damage crime is not immediate', not immediate and w.chaos == 0 and w.level == 0)
R.tick(w, 1001, {region = 'la', policeNearby = true})
check('queued damage crime counts later', w.chaos == 80)

-- A duplicate with police present still forces one star (ReportCrime).
w = R.new(0)
R.report(w, 2, 'd1', {}, 0)
R.tick(w, 1001, {region = 'la', policeNearby = true})
check('first punch queued and counted', w.chaos == 5 and w.level == 0)
R.report(w, 2, 'd1', {policePresent = true}, 1100)
check('duplicate near police still gives a star', w.level == 1)

-- The duplicate filter survives a level jump (several evidence sources).
w = R.new(0)
R.report(w, 4, 'ped7', {policePresent = true}, 0)
local afterFirst = w.chaos
R.report(w, 4, 'ped7', {policePresent = true}, 50)
check('same shot from a second source is not counted twice', w.chaos == afterFirst)

-- Parole keeps the queue (0x5625A0): a crime queued before the spray brings
-- the old level back once it reports.
w = R.new(0)
R.setLevel(w, 3, 0)
R.report(w, 2, 'q1', {}, 100)
R.clearOnParole(w, 200)
R.tick(w, 1100, {region = 'la', policeNearby = true})
check('queued crime after the spray restores the level', w.level == 3)

-- Map levels (map.zon) and the station choice (0x460A50, x6 across levels).
check('Grove is level LA', R.mapLevel(2495, -1687) == 1)
check('the Strip is level LV', R.mapLevel(2030, 1500) == 3)
check('Doherty is level SF', R.mapLevel(-2050, 150) == 2)
check('Red County is countryside', R.mapLevel(700, -500) == 0)
check('(1000, -900) is LS, busted at LSPD not Dillimore', R.nearestStation(1000, -900, 20)[5] == 'Los Santos')
check('countryside picks the plain nearest', R.nearestStation(650, -560, 15)[5] == 'Dillimore')

-- Loadouts and the 1-star nightstick rule.
check('1 star unarmed suspect: nightstick', R.copLoadout(1, false).melee == true)
check('1 star armed suspect: pistol', R.copLoadout(1, true).weapon == 22)
check('4 stars SWAT micro uzi armour 50', R.copLoadout(4).weapon == 28 and R.copLoadout(4).armor == 50)
check('cop ammo 1000', R.copLoadout(2).ammo == 1000 and R.copLoadout(6).ammo == 1000)
check('5 stars FBI MP5', R.copLoadout(5).model == 286 and R.copLoadout(5).weapon == 29)
check('6 stars army M4', R.copLoadout(6).model == 287 and R.copLoadout(6).weapon == 31)
check('LS cop model', R.copModel(2, 1) == 280)
check('SF cop model', R.copModel(3, 2) == 281)
check('LV cop model', R.copModel(1, 3) == 282)
check('countryside sheriff 283 (288 is never the default)', R.copModel(2, 0) == 283)
check('tier beats region', R.copModel(5, 1) == 286)
check('flamethrower is not instant-hit', not R.isArmedWeapon(37))
check('pistol is armed', R.isArmedWeapon(22))

-- Street cops joining a pursuit (0x562F60 / 0x562B00 / 0x68BBD0).
local function alive(...) local l = {} for i, d in ipairs({...}) do l[i] = {distance = d, alive = true} end return l end
local ok, dropped = R.pursuitJoin(0, {}, 5)
check('cap 0 refuses (0 stars)', not ok)
ok, dropped = R.pursuitJoin(3, alive(40, 60), 80)
check('room left: joins, nobody dropped', ok and #dropped == 0)
ok, dropped = R.pursuitJoin(3, alive(40, 60, 30), 80)
check('full and farther than everyone: refused', not ok)
ok, dropped = R.pursuitJoin(3, alive(40, 60, 30), 50)
check('full: the farthest pursuer is displaced', ok and #dropped == 1 and dropped[1] == 2)
local withDead = alive(40, 60, 30); withDead[3].alive = false
ok, dropped = R.pursuitJoin(3, withDead, 90)
check('a dead pursuer is displaced first, even for a farther newcomer', ok and dropped[1] == 3)
ok, dropped = R.pursuitJoin(1, alive(0.5), 0.8)
check('newcomer distance raised to 1 m: a 0.5 m pursuer stays', not ok)
ok, dropped = R.pursuitJoin(2, alive(40, 60, 70), 10)
check('over cap after a level drop: displaced down to cap - 1', ok and #dropped == 2 and dropped[1] == 3 and dropped[2] == 2)
check('on foot: any distance', R.footCopCanTarget(200, nil))
check('parked car: any distance', R.footCopCanTarget(200, 0))
-- 0.5 per step is 25 m/s (90 km/h): only within 8 m.
check('car at 90 km/h, 7 m: targeted', R.footCopCanTarget(7, 0.25))
check('car at 90 km/h, 9 m: ignored', not R.footCopCanTarget(9, 0.25))

-- Police cars (version 2).
check('no police car at 1 star', not R.canDispatchCar(1, 0, 0, 1e9))
check('2 stars: a car after more than 8 s', R.canDispatchCar(2, 0, 0, 8001) and not R.canDispatchCar(2, 0, 0, 8000))
check('3 stars: after more than 5 s', R.canDispatchCar(3, 0, 0, 5001) and not R.canDispatchCar(3, 0, 0, 5000))
check('4+ stars: no delay', R.canDispatchCar(4, 0, 0, 0) and R.canDispatchCar(6, 0, 0, 0))
check('car cap per level (2 at 2 stars)', R.canDispatchCar(2, 1, 0, 1e9) and not R.canDispatchCar(2, 2, 0, 1e9))
check('car cap 3 at 5 stars', R.canDispatchCar(5, 2, 0, 1e9) and not R.canDispatchCar(5, 3, 0, 1e9))
check('no car while the foot pursuit is full', not R.canDispatchCar(2, 0, 3, 1e9))
check('area cop cars', R.policeCarModel(2, 1, 0, false) == 596 and R.policeCarModel(3, 2, 0, false) == 597 and
    R.policeCarModel(2, 3, 0, false) == 598 and R.policeCarModel(2, 0, 0, false) == 599)
check('4 stars: Enforcer on rand(0,3) == 2 only', R.policeCarModel(4, 1, 2, false) == 427 and R.policeCarModel(4, 1, 1, false) == 596)
check('5 stars: always the FBI Rancher', R.policeCarModel(5, 1, 0, false) == 490 and R.policeCarModel(5, 2, 2, true) == 490)
check('6 stars: Barracks or Rhino', R.policeCarModel(6, 1, 0, true) == 433 and R.policeCarModel(6, 1, 0, false) == 432)
local seats, cop = R.policeCarCrew(596, 1)
check('cop car: driver and passenger, area cop', #seats == 2 and cop == 280)
seats, cop = R.policeCarCrew(599, 0)
check('Ranger: country sheriff', #seats == 2 and cop == 283)
seats, cop = R.policeCarCrew(427, 1)
check('Enforcer: four SWAT', #seats == 4 and cop == 285)
seats, cop = R.policeCarCrew(490, 1)
check('FBI Rancher: four FBI', #seats == 4 and cop == 286)
seats, cop = R.policeCarCrew(432, 1)
check('Rhino: one soldier', #seats == 1 and cop == 287)
seats, cop = R.policeCarCrew(433, 1)
check('Barracks: two soldiers', #seats == 2 and cop == 287)
check('no shotgun at 2 stars', R.policeCarShotgunSeat(2, 596, 0, 0) == nil)
check('3 stars: driver shotgun on the first 25 % roll', R.policeCarShotgunSeat(3, 596, 0.2, 0.9) == 0)
check('then the passenger on the second', R.policeCarShotgunSeat(3, 596, 0.3, 0.1) == 1)
check('both rolls fail: no shotgun', R.policeCarShotgunSeat(3, 596, 0.3, 0.3) == nil)
check('no shotgun roll for the Enforcer', R.policeCarShotgunSeat(4, 427, 0, 0) == nil)
check('mission at 1 star: block', R.policeCarMission(1, 3) == 'block')
check('2 stars: block on 0-2, ram on 3', R.policeCarMission(2, 2) == 'block' and R.policeCarMission(2, 3) == 'ram')
check('3 stars: block on 0-1', R.policeCarMission(3, 1) == 'block' and R.policeCarMission(3, 2) == 'ram')
check('4-6 stars: block only on 0', R.policeCarMission(4, 0) == 'block' and R.policeCarMission(6, 1) == 'ram')
check('speed 25 at 1 star, 34 at 2', R.policeCarSpeed(1, 1.1) == 25 and R.policeCarSpeed(2, 1.1) == 34)
check('3 stars: handling top speed x 54', math.abs(R.policeCarSpeed(3, 1) - 54) < 1e-6)
check('6 stars: x 78', math.abs(R.policeCarSpeed(6, 1) - 78) < 1e-6)
-- handling+0x88 (0x6F5080), from handling.cfg values.
local laTop = R.handlingTopSpeed(200, 25, 2.0, 0x10200008)
check('LSPD cruiser: engine beats drag, one 0.01 step below 200/180', math.abs(laTop - (200 / 180 - 0.01)) < 1e-6)
check('so 3 stars is about 59.4, not 60', math.abs(R.policeCarSpeed(3, laTop) - 59.46) < 0.01)
check('Rhino: 80/180 - 0.01', math.abs(R.handlingTopSpeed(80, 40, 5.0, 0x308840) - (80 / 180 - 0.01)) < 1e-6)
local dragBound = R.handlingTopSpeed(400, 10, 3.0, 0)
check('drag-bound: steps down to where 0.0004 x accel / 6 >= drag / 2000 x v^2',
    dragBound > 0.6566 and dragBound < 0.6767 and 10 * 0.0004 / 6 >= 3 / 2000 * dragBound ^ 2)
check('OFFROAD_ABILITY (0x1000000): max velocity x 0.8333', math.abs(R.handlingTopSpeed(180, 20, 2, 0x1000000) - 0.8333333) < 1e-6)
-- The cop-bike switch (0x40A150) and the bike (0x407C50, 0x41C070).
check('bike while the switch is on, under 3 stars', R.policeCarModel(2, 1, 0, false, true) == 523 and
    R.policeCarModel(3, 1, 0, false, true) == 596)
seats, cop = R.policeCarCrew(523, 1)
check('police bike: one motorbike cop', #seats == 1 and cop == 284)
local bike = {on = false, flipAt = 0}
R.copBikeSwitch(bike, 2, 1, 1000, 0)
check('switch flips when due, next in 30-50 s', bike.on == true and bike.flipAt == 31000)
R.copBikeSwitch(bike, 2, 1, 20000, 0.5)
check('not before', bike.on == true and bike.flipAt == 31000)
R.copBikeSwitch(bike, 2, 1, 31000, 0.999)
check('then back off', bike.on == false and bike.flipAt == 31000 + 30000 + 19980)
bike.on = true
R.copBikeSwitch(bike, 3, 1, 32000, 0)
check('forced off at 3 stars', bike.on == false)
bike.on = true
R.copBikeSwitch(bike, 2, 0, 32000, 0)
check('forced off in the countryside', bike.on == false)
check('close at 2 stars, suspect on foot within 20 m: 5', R.policeCarCloseSpeed(2, 34, true, 15, 0.1) == 5)
check('close at 2 stars, suspect in a car 15 m away: 30', R.policeCarCloseSpeed(2, 34, false, 15, 0.3) == 30)
check('close at 1 star, on foot 30 m: 13', R.policeCarCloseSpeed(1, 25, true, 30, 0.1) == 13)
check('3+ stars keep their speed in a car', R.policeCarCloseSpeed(4, 80, false, 5, 0.3) == 80)
check('a suspect standing still within 30 m: at most 10', R.policeCarCloseSpeed(5, 80, true, 25, 0.01) == 10)
check('bail: suspect on foot within 10 m', R.shouldBail(9, true, false, 0) and not R.shouldBail(10, true, false, 0))
check('bail: car slow for more than 2.5 s', R.shouldBail(5, false, false, 2501) and not R.shouldBail(5, false, false, 2500))
check('bail: car on its roof', R.shouldBail(5, false, true, 0))
check('no bail from a moving car', not R.shouldBail(5, false, false, 0))
check('driver waits 3-5 s the first time', R.driverExitDelay(false, 0) == 3000 and R.driverExitDelay(false, 0.999) == 4998)
check('0.25-1.5 s after driving again', R.driverExitDelay(true, 0) == 250 and R.driverExitDelay(true, 0.999) == 1498)
-- 0x68FF6A: |v|^2 x 50 > 1, i.e. faster than 0.1414 per step (about 7 m/s).
check('suspect car faster than about 7 m/s gets away', R.suspectCarGetsAway(0.142, 5) and not R.suspectCarGetsAway(0.141, 5))
check('a creeping car (1-5 m/s) does not', not R.suspectCarGetsAway(0.1, 5) and not R.suspectCarGetsAway(0.03, 5))
check('or more than 10 m from the cop (d^2 > 100)', R.suspectCarGetsAway(0, 10.01) and not R.suspectCarGetsAway(0, 10))
check('re-entry within 4 m of the car (d^2 < 16)', R.reenterDistance == 4)
check('slow threshold: block 0.04, ram 0.05', R.bailSlowSpeedFor('block') == 0.04 and R.bailSlowSpeedFor('ram') == 0.05)

print(('rules_spec: %d checks passed'):format(passed))
