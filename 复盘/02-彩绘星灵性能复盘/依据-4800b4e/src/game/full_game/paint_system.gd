extends RefCounted
const StartupTrace = preload("res://full_game/startup_trace.gd")
const Attributes = preload("res://full_game/attack_attributes.gd")
const NodeActivation = preload("res://full_game/node_activation.gd")
const Coordinates = preload("res://full_game/paint_coordinates.gd")
const State = preload("res://full_game/paint_state.gd")
const Protection = preload("res://full_game/paint_protection.gd")
const Space = preload("res://full_game/paint_space.gd")
const Projectiles = preload("res://full_game/paint_projectiles.gd")
const Targets = preload("res://full_game/paint_targets.gd")
const C = preload("res://full_game/catalog.gd")
const Stamps = preload("res://full_game/paint_stamps.gd")
const Motion = preload("res://full_game/brush_motion.gd")
const Characters = preload("res://full_game/character_system.gd")
var data: Dictionary = {}
var world_radius: float
var characters: Characters
signal ground_cell_changed(key: String, tile: Dictionary)
signal hero_contact(hit: Dictionary, bullet: Dictionary)
signal changed
signal node_painted(id: int)
signal coverage_changed(id: int, value: float)
# Flight contacts can paint the same cell repeatedly. Keep each event for paint diagnostics.
var _settling_flights := false
var _flight_events: Array[Callable] = []
var _flight_dirty := false
var dirty: bool:
	set(value):
		if value and _settling_flights:
			_flight_dirty = true
		elif value:
			changed.emit()
var ground_revision := 0
var damaging_cells: Dictionary = {}
var changed_cells: Dictionary = {}
var changes_since := -1
var space := Space.new()


func mark_cell(key: String) -> void:
	changed_cells[key] = true
	ground_revision += 1
	var tile: Dictionary = data.ground.get(key, {})
	if _settling_flights:
		_flight_events.append(ground_cell_changed.emit.bind(key, tile))
	else:
		ground_cell_changed.emit(key, tile)


func mark_node(id: int) -> void:
	if _settling_flights:
		_flight_events.append(node_painted.emit.bind(id))
	else:
		node_painted.emit(id)


func begin_flight_updates() -> void:
	_settling_flights = true


func publish_flight_updates() -> void:
	_settling_flights = false
	if not _flight_dirty and _flight_events.is_empty():
		return
	var events := _flight_events
	_flight_events = []
	_flight_dirty = false
	for event in events:
		event.call()
	changed.emit()


func attach(state: Dictionary, radius: float, actors: Characters) -> void:
	var _startup_span := StartupTrace.scope("paint_system.gd:attach")
	data = state
	world_radius = radius
	characters = actors
	# Lifecycle callers migrate before attachment. Normal ticks and queries never migrate.
	Targets.reset(self)
	space.ensure_state(data, world_radius)
	Stamps.prune(data)
	damaging_cells.clear()
	for key in data.ground:
		if float(data.ground[key].damage) > 0.0:
			damaging_cells[key] = true


func source_position(source: Dictionary) -> Vector2:
	return characters.source_position(source)


func attack_range(source: Dictionary) -> float:
	return float(Attributes.ordinary(source, data.upgrades).range)


func available_node(node: Dictionary) -> bool:
	return NodeActivation.available(node, int(data.planet_clears))


func tick(dt: float) -> void:
	Projectiles.tick(self, space, dt)
	Targets.update_progress(self, space)
	_cleanup_bodies()


func launch(source: Dictionary, target: Dictionary) -> void:
	var origin := space.terrain.position(source_position(source), 0.9)
	Projectiles.launch(self, origin, target.world_pos, source)


func brush_trace(effect: Dictionary, point: Vector2) -> Dictionary:
	if effect.brush in ["circle", "triple"]:
		var start := Motion.flight_point(effect.pos, point, world_radius, 0.0, space.terrain)
		for step in range(1, Motion.FLIGHT_STEPS + 1):
			var t := float(step) / Motion.FLIGHT_STEPS
			var end := Motion.flight_point(effect.pos, point, world_radius, t, space.terrain)
			var hit := space.trace(start, end, int(effect.source))
			if not hit.is_empty():
				var fraction := start.distance_to(hit.position) / maxf(start.distance_to(end), 0.00001)
				hit.travel = (step - 1 + clampf(fraction, 0, 1)) / Motion.FLIGHT_STEPS
				return hit
			start = end
	else:
		var hit := _stroke_trace(effect, point)
		if not hit.is_empty():
			return hit
	var pos := space.terrain.position(point)
	return {"surface": "ground", "position": pos,
		"normal": space.terrain.surface_normal(pos.normalized()), "travel": 1.0}


func _stroke_trace(effect: Dictionary, point: Vector2) -> Dictionary:
	var origin := space.terrain.position(effect.pos, 0.35)
	# Follow the sphere on long sweeps, then settle onto any low relief at the endpoint.
	var steps := clampi(ceili(Vector2(effect.pos).distance_to(point) / 5.0), 1, 8)
	for i in range(1, steps + 1):
		var p := Vector2(effect.pos).lerp(point, float(i) / steps)
		var end := space.terrain.position(p, 0.35)
		var hit := space.trace(origin, end, int(effect.source))
		if not hit.is_empty():
			return hit
		origin = end
	return space.trace(origin, space.terrain.position(point), int(effect.source))


func legacy_contact(effect: Dictionary, cell: Vector2, sample: Dictionary, part: int) -> void:
	var point: Vector2 = sample.get("point", cell)
	var hit := brush_trace(effect, point)
	if hit.surface == "ground":
		# The coarse two-layer/damage grid also owns the transparent gaps inside each stamp.
		point = Coordinates.planar_near(hit.position, world_radius, point)
		if not State.ground(self, point, {"color": effect.color, "damage": effect.dot,
			"hero_ink": effect.get("hero_ink", false),
			"life": 0.0, "source": effect.source, "round": effect.round, "stamp_id": effect.get("stamp_id", "")}):
			return
	elif sample.is_empty() or not State.apply_hit(self, space, hit, effect, 0.35):
		return
	if sample.is_empty():
		return
	_record_impact(effect, hit, cell, sample, part)


func _record_impact(effect: Dictionary, hit: Dictionary, cell: Vector2, sample: Dictionary, part: int) -> void:
	if not effect.has("impacts"):
		effect.impacts = []
	var at := float(sample.visible_at) if hit.surface == "ground" else float(effect.age)
	var event := {"surface": hit.surface, "position": hit.position, "normal": hit.normal,
		"part": part, "at": at, "cell": cell, "actor": hit.get("actor", 0), "uv": hit.get("uv", Vector2.ZERO)}
	for existing in effect.impacts:
		if existing.surface == hit.surface and int(existing.part) == part:
			var plan: Dictionary = effect.get("flights", {}).get(str(part), {})
			var planned := not plan.is_empty() and Vector2(plan.point).is_equal_approx(sample.point)
			if at < float(existing.at) or (planned and at == float(existing.at)):
				existing.merge(event, true)
			return
	if effect.impacts.size() < 12:
		effect.impacts.append(event)


func restore() -> void:
	State.restore(self, space)
	_cleanup_bodies()


func _cleanup_bodies() -> void:
	State.clear_friendly_bodies(data)
	var living := {}
	for list in [data.enemies, data.corpses]:
		for actor in list:
			living[str(int(actor.id))] = true
	for id in data.paint.bodies.keys():
		if int(id) > 0 and not living.has(id):
			data.paint.bodies.erase(id)


func pigment_at(point: Vector2) -> int:
	return preload("res://full_game/pigment_query.gd").top(self, point)


func has_ground_paint() -> bool:
	return not data.ground.is_empty()


func sample(point: Vector2) -> Dictionary:
	var key := "%d,%d" % [floori(point.x * 2.0), floori(point.y * 2.0)]
	if not data.ground.has(key) and point.length() > PI * world_radius:
		var folded := Coordinates.planar(Coordinates.position(point, world_radius), world_radius)
		key = "%d,%d" % [floori(folded.x * 2.0), floori(folded.y * 2.0)]
	return data.ground.get(key, {})
