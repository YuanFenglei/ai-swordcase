extends RefCounted
## Starling follow/approach/attack/return behavior. No world, level, reward or save access.
const C = preload("res://full_game/catalog.gd")
const Save = preload("res://full_game/combat_save.gd")
const Entry = preload("res://full_game/enemy_entry.gd")
const Queries = preload("res://full_game/target_queries.gd")
const Characters = preload("res://full_game/character_system.gd")
const Spatial = preload("res://full_game/spatial_adapter.gd")
var _characters: Characters
var _targets: Queries
var _spatial: Spatial


func bind(characters: Characters, targets: Queries, spatial: Spatial) -> void:
	_characters = characters
	_targets = targets
	_spatial = spatial

const STATES := ["follow", "acquire", "approach", "attack", "return", "wander"]
const ARRIVE_DISTANCE := 0.12
const COMBAT_DIAMETER := 1.45
const COMBAT_DIAMETER_PER_STAGE := 0.30


static func config(slot: Dictionary) -> Dictionary:
	return C.PetBehavior.effective(C.SPECIES[slot.species], slot)


static func facing(slot: Dictionary) -> Vector2:
	var direction: Vector2 = slot.get("facing", Vector2.UP)
	return direction.normalized() if direction.length_squared() > 0.00001 else Vector2.UP


static func face(slot: Dictionary, direction: Vector2) -> Vector2:
	if direction.length_squared() > 0.00001:
		slot.facing = direction.normalized()
	return facing(slot)


static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	return (
		value.get("state", "") in STATES
		and Save.point(value.get("pos"))
		and Save.number(value.get("target"), -1, 9007199254740991)
		and floor(float(value.target)) == float(value.target)
		and Save.number(value.get("think"), 0, 2.0)
		and (not value.has("policy") or value.policy is String)
	)


## Callers inside one AI step pass the slot's effective settings; others let it be recomputed.
func keep_in_bounds(slot: Dictionary, settings: Dictionary = {}) -> void:
	var player: Vector2 = _characters.player_position()
	var offset: Vector2 = Vector2(slot.ai.pos) - player
	if settings.is_empty():
		settings = config(slot)
	var radius := maxf(settings.move_radius, player.distance_to(_characters.home(slot, -1, settings)))
	if offset.length() <= radius:
		return
	var bounded := player + offset.limit_length(radius)
	# The hero moving/teleporting or a shrinking radius can invalidate the old position.
	# Restore the hard boundary. If the radial point is blocked, recall to the safe hero anchor.
	if not _spatial.line_clear(player, bounded) or _spatial.constrain_motion(player, bounded) != bounded:
		bounded = player
	slot.ai.pos = bounded
	slot.ai.target = -1
	slot.ai.think = 0.0


func move(slot: Dictionary, goal: Vector2, dt: float, settings: Dictionary = {},
	avoid_teammates: bool = false) -> void:
	var origin: Vector2 = slot.ai.pos
	if settings.is_empty():
		settings = config(slot)
	var player: Vector2 = _characters.player_position()
	goal = player + (goal - player).limit_length(settings.move_radius)
	var distance := origin.distance_to(goal)
	if distance <= 0.0001 or dt <= 0:
		return
	var step := minf(distance, float(settings.move_speed) * dt)
	var direction := origin.direction_to(goal)
	var nearby: Array[Vector3] = []
	if avoid_teammates:
		nearby = _nearby_teammates(slot, origin, step)
	var overlap := _overlap(origin, nearby)
	var blocked_by_teammate := false
	for angle in [0.0, PI / 4.0, -PI / 4.0, PI / 2.0, -PI / 2.0]:
		var next := origin + direction.rotated(angle) * step
		next = player + (next - player).limit_length(maxf(settings.move_radius, origin.distance_to(player)))
		if _overlap(next, nearby) > overlap + 0.00001:
			blocked_by_teammate = true
			continue
		var lateral := blocked_by_teammate and absf(angle) == PI / 2.0
		if (next.distance_to(goal) < distance or lateral) and _can_move(origin, next):
			slot.ai.pos = next
			face(slot, next - origin)
			return


func _can_move(origin: Vector2, next: Vector2) -> bool:
	return _spatial.line_clear(origin, next) and _spatial.constrain_motion(origin, next) == next


func _nearby_teammates(slot: Dictionary, origin: Vector2, step_size: float) -> Array[Vector3]:
	var nearby: Array[Vector3] = []
	for other in _characters.roster():
		if other.id == slot.id:
			continue
		var average_stage := (float(slot.stage) + float(other.stage)) * 0.5
		var spacing := COMBAT_DIAMETER + (average_stage - 1.0) * COMBAT_DIAMETER_PER_STAGE
		var point: Vector2 = other.ai.pos
		var nearby_radius := spacing + step_size
		if origin.distance_squared_to(point) < nearby_radius * nearby_radius:
			nearby.append(Vector3(point.x, point.y, spacing))
	return nearby


func _overlap(point: Vector2, nearby: Array[Vector3]) -> float:
	var total := 0.0
	for teammate in nearby:
		var overlap := maxf(0.0, teammate.z - point.distance_to(Vector2(teammate.x, teammate.y)))
		total += overlap * overlap
	return total


func _separate(slot: Dictionary, target: Vector2, reach: float, dt: float, settings: Dictionary) -> bool:
	if dt <= 0.0:
		return false
	var origin: Vector2 = slot.ai.pos
	var step_size := minf(float(settings.move_speed) * dt, COMBAT_DIAMETER * 0.25)
	var nearby := _nearby_teammates(slot, origin, step_size)
	var best_overlap := _overlap(origin, nearby)
	if best_overlap <= 0.0001:
		return false
	var in_range := origin.distance_to(target) <= reach
	var player := _characters.player_position()
	var direction := (target - origin).orthogonal().normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	var best := origin
	# Sideways first, so a stacked pair can still split at the edge of attack range.
	for turn in [0, 1, -1, 2, -2, 3, -3, 4]:
		var offset := direction.rotated(float(turn) * PI / 4.0) * step_size
		var limit := maxf(settings.move_radius, origin.distance_to(player))
		var next: Vector2 = player + (origin + offset - player).limit_length(limit)
		if in_range and next.distance_to(target) > reach:
			continue
		var overlap := _overlap(next, nearby)
		if overlap >= best_overlap - 0.00001:
			continue
		if _can_move(origin, next) and _spatial.line_clear(next, target):
			best = next
			best_overlap = overlap
	if best == origin:
		return false
	slot.ai.pos = best
	return true


func return_home(slot: Dictionary, dt: float, settings: Dictionary = {}, travelled := 0.0) -> void:
	slot.ai.target = -1
	var index := _characters.roster().find(slot)
	if travelled <= 0.00001:
		_wander(slot, index, dt, settings)
		return
	var home := _characters.home(slot, index, settings)
	var player := _characters.player_position()
	settings.move_radius = maxf(settings.move_radius, player.distance_to(home))
	if not _can_move(player, home):
		var offset := home - player
		var side := -1.0 if index % 2 else 1.0
		for turn in [side, -side, 2 * side, -2 * side]:
			var alternate := player + offset.rotated(float(turn) * PI / 4.0)
			if _can_move(player, alternate):
				home = alternate
				break
	if travelled > 0.00001 and dt > 0.0:
		settings.move_speed += travelled / dt
	move(slot, home, dt, settings)
	slot.ai.state = "follow" if Vector2(slot.ai.pos).distance_to(home) <= ARRIVE_DISTANCE else "return"


func _wander(slot: Dictionary, index: int, dt: float, settings: Dictionary) -> void:
	var player := _characters.player_position()
	var radius: float = settings.move_radius
	var fraction := sqrt((index + 0.5) / _characters.roster().size())
	# Distribute the party across the disk, with a separate strolling rhythm per pet.
	var phase := float(slot.id) + _characters.elapsed() * (0.42 + 0.03 * (int(slot.id) % 7))
	var angle := index * 2.39996323 + 0.36 * sin(phase)
	var extent := radius * (0.22 + 0.65 * fraction + 0.10 * sin(phase * 1.7))
	var offset := Vector2.from_angle(angle) * extent
	var goal := player + offset
	if not _can_move(player, goal):
		goal = player
		for turn in [PI / 4.0, -PI / 4.0, PI / 2.0, -PI / 2.0, PI]:
			var alternate := player + offset.rotated(turn)
			if _can_move(player, alternate):
				goal = alternate
				break
	var outside := player.distance_to(slot.ai.pos) > radius
	slot.ai.state = "return" if outside else "wander"
	if not outside:
		settings.move_speed = minf(settings.move_speed, 2.2)
		var point: Vector2 = slot.ai.pos
		for neighbor in _nearby_teammates(slot, point, 0.0):
			var away := point - Vector2(neighbor.x, neighbor.y)
			goal += away.normalized() * (neighbor.z - away.length())
	move(slot, goal, dt, settings)


func tick(dt: float, travelled := 0.0) -> void:
	_characters.adopt_roster()
	for slot in _characters.roster():
		step(slot, dt, travelled)


func step(slot: Dictionary, dt: float, travelled := 0.0) -> void:
	# Effective settings and reach only change with stage, overrides or upgrades, never inside one step.
	var settings := config(slot)
	keep_in_bounds(slot, settings)
	var ai: Dictionary = slot.ai
	var policy: String = str(settings.targeting_template) + ":" + str(settings.tie_break)
	if ai.get("policy", "") != policy:
		ai.policy = policy
		ai.target = -1
		ai.think = 0.0
	ai.think = maxf(0.0, float(ai.think) - dt)
	if _spatial.player_sheltered() or not C.SPECIES[slot.species].attack.enabled:
		return_home(slot, dt, settings, travelled)
		return
	var reach: float = _targets.attack_range(slot)
	var target := _targets.locked(slot, settings, reach)
	var lost_range: bool = (
		not target.is_empty()
		and ai.state == "attack"
		and _targets.distance_to(slot, target) > reach
	)
	# Returning is a movement state, never a gate on acquiring another target.
	if ai.think <= 0 or target.is_empty() or lost_range:
		target = _targets.choose(slot, "chase", settings, reach)
		ai.target = -1 if target.is_empty() else int(target.id)
		ai.think = settings.think_interval
	var outside := _characters.player_position().distance_to(ai.pos) > float(settings.move_radius) + 0.001
	if target.is_empty() or travelled > 0.00001 or outside:
		return_home(slot, dt, settings, travelled)
		if not target.is_empty():
			ai.target = target.id
		return
	_engage(slot, target, reach, dt, settings)


func _engage(slot: Dictionary, target: Dictionary, reach: float, dt: float, settings: Dictionary) -> void:
	var ai: Dictionary = slot.ai
	var separated := _separate(slot, target.pos, reach, dt, settings)
	if _targets.distance_to(slot, target) > reach:
		ai.state = "approach"
		if separated:
			face(slot, Vector2(target.pos) - Vector2(ai.pos))
			return
		var approach_distance := maxf(reach * 0.5, reach - 0.25)
		var goal: Vector2 = (
			target.pos + Vector2(target.pos).direction_to(ai.pos) * approach_distance
		)
		move(slot, goal, dt, settings, true)
		if _targets.distance_to(slot, target) > reach:
			return
	ai.state = "attack"
	face(slot, Vector2(target.pos) - Vector2(ai.pos))


func firing_target(slot: Dictionary) -> Dictionary:
	var settings := config(slot)
	keep_in_bounds(slot, settings)
	if not C.SPECIES[slot.species].attack.enabled:
		return {}
	# Re-evaluate on each new cast, even during pursuit/return. Released effects are untouched.
	var target := _targets.choose(slot, "attack", settings)
	if not target.is_empty():
		slot.ai.target = int(target.id)
		slot.ai.state = "attack"
		face(slot, Vector2(target.pos) - Vector2(slot.ai.pos))
	else:
		slot.ai.target = -1
	return target
