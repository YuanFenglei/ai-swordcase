extends RefCounted
## Brush release snapshots and swept contacts, independent of damage/level/reward ownership.
signal enemy_hit(enemy: Dictionary, damage: float, color: int, origin: Variant)
const C = preload("res://full_game/catalog.gd")
const Attributes = preload("res://full_game/attack_attributes.gd")
const Motion = preload("res://full_game/brush_motion.gd")
const Characters = preload("res://full_game/character_system.gd")
const Spatial = preload("res://full_game/spatial_adapter.gd")
const Paint = preload("res://full_game/paint_system.gd")
const Stamps = preload("res://full_game/paint_stamps.gd")
const Contacts = preload("res://full_game/brush_contacts.gd")
const ContactMask = preload("res://full_game/brush_contact_mask.gd")
const Spray = preload("res://full_game/spray_attack.gd")
const CELL := 0.5
const SPAN_MARGIN := 0.02
const NO_MASK: Array = []
var data: Dictionary = {}
var characters: Characters
var spatial: Spatial
var pigment: Paint
var visual_sequences: Dictionary = {}
# One [ContactMask.inputs() copy, mask] per in-flight stamp until it expires; rebuilt on any input change.
var _masks: Dictionary = {}
var contacts := Contacts.new()


func bind(state: Dictionary, actors: Characters, geometry: Spatial, paint: Paint) -> void:
	data = state
	characters = actors
	spatial = geometry
	pigment = paint
	visual_sequences.clear()
	contacts.clear()
	_masks.clear()


func paint(
	brush: String,
	origin: Vector2,
	direction: Vector2,
	color: int,
	instant: float,
	dot: float,
	life: float,
	source: int,
	active: bool,
	extra: Dictionary = {}
) -> void:
	if direction.length_squared() < 0.00001:
		direction = Vector2.UP
	var bound = 22.0 if active else 17.0
	var mods = {} if active else data.upgrades.duplicate()
	mods.merge(extra, true)
	var effect = {
		"pos": origin,
		"kind": "brush",
		"brush": brush,
		"direction": direction.normalized(),
		"cells": [],
		"color": color,
		"life": Motion.DURATION,
		"age": 0.0,
		"active": active,
		"mods": mods,
		"instant": instant,
		"dot": dot,
		"paint_life": life,
		"source": source,
		"round": data.round,
		"target": origin + direction.normalized() * float(mods.get("target_distance", 4.5)),
		"node": data.node.get("id", -1),
		"cursor": 0,
		"hits": [],
		"core_done": false
	}
	# Cosmetic selection is snapshotted, so pause/save/load cannot reroll a released splash.
	var visual_key := "%s:%s:%s" % [data.seed, data.planet, source]
	var sequence := int(visual_sequences.get(visual_key, absi(source)))
	effect.visual_variant = sequence
	visual_sequences[visual_key] = sequence + 1
	# Snapshot the near bonus, just like power, colour and shape at release.
	var slot = characters.find_slot(source)
	effect.near_bonus = 0.0
	if not active and not slot.is_empty():
		effect.near_bonus = Attributes.ordinary(slot, data.upgrades).near_bonus
	if source == -1 and mods.get("hero_ink", false):
		effect.hero_ink = true
		mods.erase("hero_ink")
	if mods.has("spray_kind"):
		var kind := int(mods.spray_kind)
		mods.erase("spray_kind")
		Spray.prepare(effect, kind, pigment.world_radius, pigment.space.terrain)
	else:
		_queue_cells(effect, bound)
	data.effects.append(effect)
	Stamps.register(data, effect)
	if not effect.has("spray") and brush in ["circle", "triple"]:
		_plan_flights(effect)


func _queue_cells(effect: Dictionary, bound: float) -> void:
	var bounds := _release_bounds(effect, bound)
	var piece := _ground_piece(effect)
	var first := floori(bounds.position.y / CELL)
	var last := ceili(bounds.end.y / CELL)
	var times := PackedFloat64Array()
	for x in range(floori(bounds.position.x / CELL), ceili(bounds.end.x / CELL) + 1):
		# Rows outside the padded piece cannot pass the exact query; the visiting order is unchanged.
		var rows := _column_rows(piece, (x + 0.5) * CELL, first, last)
		for y in range(rows.x, rows.y + 1):
			var point = Vector2(x + 0.5, y + 0.5) * CELL
			if (
				C.ground_inside(effect.brush, point, effect.pos, effect.direction, effect.mods, effect.active)
				and spatial.line_clear(effect.pos, point)
			):
				effect.cells.append(point)
				times.append(Motion.arrival(effect, point))
	_sort_by_arrival(effect.cells, times)


# One convex world piece containing C.ground_inside() for this release, padded by SPAN_MARGIN local
# metres (far above float error): [centre x, centre y, radius, planes], where a plane [nx, ny, limit]
# keeps nx * x + ny * y <= limit. Rings and triples use one enclosing disk. Unknown brushes get [].
func _ground_piece(effect: Dictionary) -> Array:
	var g := C.geometry(effect.brush, effect.mods, effect.active)
	var m := SPAN_MARGIN
	var centre := Vector2(0, g.distance)
	var radius := INF
	var planes := []
	match effect.brush:
		"bucket":
			# Cells also need q.y >= 0, so a fan wider than a half-plane is bounded by that half-plane.
			var half := minf(g.angle, PI * 0.5)
			centre = Vector2.ZERO
			radius = g.reach + m
			planes = [[Vector2(cos(half), -sin(half)), m], [Vector2(-cos(half), -sin(half)), m]]
		"horizontal":
			planes = [[Vector2.RIGHT, g.length + m], [Vector2.LEFT, g.length + m],
				[Vector2.DOWN, g.distance + g.width + m], [Vector2.UP, g.width - g.distance + m]]
		"vertical":
			planes = [[Vector2.RIGHT, g.width + m], [Vector2.LEFT, g.width + m], [Vector2.DOWN, g.reach + m],
				[Vector2.UP, m]]
		"ring":
			radius = g.ring_radius + g.ring_width + m
		"circle":
			radius = g.radius + m
		"triple":
			radius = 0.0
			for point in C.centers(effect.brush, effect.mods, effect.active):
				radius = maxf(radius, point.distance_to(centre) + g.point_radius + m)
		_:
			return []
	# Local (x, y) lies at pos + scale * (x * side + y * ahead), inverting C.local_point().
	var ahead: Vector2 = effect.direction.normalized()
	if ahead.is_zero_approx():
		return []
	var side := Vector2(-ahead.y, ahead.x)
	var s := float(g.scale)
	var origin: Vector2 = effect.pos
	var piece := [origin.x + s * (centre.x * side.x + centre.y * ahead.x),
		origin.y + s * (centre.x * side.y + centre.y * ahead.y), radius * s, []]
	for plane in planes:
		var normal: Vector2 = side * plane[0].x + ahead * plane[0].y
		piece[3].append([normal.x, normal.y, plane[1] * s + normal.dot(origin)])
	return piece


# Rows of the column at world x whose cells may lie in the piece; x > y when there are none.
func _column_rows(piece: Array, column: float, first: int, last: int) -> Vector2i:
	if piece.is_empty():
		return Vector2i(first, last)
	var low := -INF
	var high := INF
	if piece[2] < INF:
		var square: float = piece[2] * piece[2] - (column - piece[0]) * (column - piece[0])
		if square < 0.0:
			return Vector2i(1, 0)
		low = piece[1] - sqrt(square)
		high = piece[1] + sqrt(square)
	for plane in piece[3]:
		var room: float = plane[2] - plane[0] * column
		if plane[1] > 0.000001:
			high = minf(high, room / plane[1])
		elif plane[1] < -0.000001:
			low = maxf(low, room / plane[1])
		elif room < 0.0:
			return Vector2i(1, 0)
	# Cell centres sit at y = (row + 0.5) * CELL.
	return Vector2i(maxi(first, ceili(clampf(low / CELL - 0.5, first - 1.0, last + 1.0))),
		mini(last, floori(clampf(high / CELL - 0.5, first - 1.0, last + 1.0))))


# Same permutation as cells.sort_custom(func(a, b): return time(a) < time(b)): with distinct times
# the ascending order is unique, so a native sort suffices; ties keep the engine's own custom sort.
func _sort_by_arrival(cells: Array, times: PackedFloat64Array) -> void:
	var sorted := times.duplicate()
	sorted.sort()
	var order := []
	for i in range(1, sorted.size()):
		if not (sorted[i - 1] < sorted[i]):
			order = range(times.size())
			order.sort_custom(func(a, b): return times[a] < times[b])
			break
	if order.is_empty():
		var index := {}
		for i in times.size():
			index[times[i]] = i
		for time in sorted:
			order.append(index[time])
	var source := cells.duplicate()
	for i in order.size():
		cells[i] = source[order[i]]


func _plan_flights(effect: Dictionary) -> void:
	var mask := _mask(effect)
	var best := {}
	effect.flights = {}
	for cell in effect.cells:
		var part := mask.part_for(effect, cell)
		var sample := mask.sample(cell, part, Motion.arrival(effect, cell))
		if sample.is_empty():
			continue
		var distance: float = sample.point.distance_squared_to(mask.parts[part].center)
		if best.has(part):
			var previous: Dictionary = best[part]
			if sample.visible_at > previous.visible_at or (sample.visible_at == previous.visible_at
				and distance >= previous.distance):
				continue
		sample.distance = distance
		best[part] = sample
	for part in best:
		var sample: Dictionary = best[part]
		effect.flights[str(part)] = {"point": sample.point}
		_update_endpoint(effect, effect.flights[str(part)])


func _update_endpoint(effect: Dictionary, plan: Dictionary) -> void:
	var hit := pigment.brush_trace(effect, plan.point)
	plan.travel = hit.travel
	plan.end = hit.position


func _release_bounds(effect: Dictionary, limit: float) -> Rect2:
	# Bound the existing exact shape query; keep its grid, masks and release ordering.
	var g := C.geometry(effect.brush, effect.mods, effect.active)
	var half_size := Vector2(g.reach, g.reach * 0.5)
	var center := Vector2(0, g.reach * 0.5)
	match effect.brush:
		"vertical":
			half_size.x = g.width
		"horizontal":
			center = Vector2(0, g.distance)
			half_size = Vector2(g.length, g.width)
		"ring", "circle":
			center = Vector2(0, g.distance)
			half_size = Vector2.ONE * (g.radius if effect.brush == "circle" else g.ring_radius + g.ring_width)
		"triple":
			var centers := C.centers(effect.brush, effect.mods, effect.active)
			var local := Rect2(centers[0], Vector2.ZERO)
			for point in centers:
				local = local.expand(point)
			center = local.get_center()
			half_size = local.size * 0.5 + Vector2.ONE * float(g.point_radius)
	var bounds := Rect2(Motion.world_point(effect, center - half_size), Vector2.ZERO)
	for corner in [Vector2(-1, 1), Vector2(1, -1), Vector2.ONE]:
		bounds = bounds.expand(Motion.world_point(effect, center + half_size * corner))
	return bounds.intersection(Rect2(effect.pos - Vector2.ONE * limit, Vector2.ONE * limit * 2.0))


func _tick_paint(dt: float) -> void:
	# Keep release order for overlapping colours; visual quality never affects contacts.
	for effect in data.effects:
		effect.life -= dt
		if not effect.has("age"):
			continue
		var previous: float = effect.age
		effect.age += dt
		if effect.has("spray"):
			Spray.advance(self, effect, dt)
			continue
		if previous > Motion.draw_time(effect):
			continue
		for key in effect.get("flights", {}):
			var contact := ContactMask.Frames.contact_start(effect, int(key))
			if previous < contact and effect.age >= contact - Motion.FLIGHT_TIME:
				_update_endpoint(effect, effect.flights[key])
		_apply_cells(effect)
		contacts.refresh_hits(effect)
		for enemy in contacts.enemies(characters.enemies()):
			if contacts.has_hit(int(enemy.id)) or not Motion.contact(effect, enemy.pos, previous):
				continue
			if spatial.line_clear(effect.pos, enemy.pos):
				contacts.emit_hit(enemy_hit, effect, enemy)

	for i in range(data.effects.size() - 1, -1, -1):
		var effect: Dictionary = data.effects[i]
		if effect.life <= 0.0:
			data.effects.remove_at(i)
			_masks.erase(effect.get("stamp_id", ""))
			Stamps.release_unused(data, effect.get("stamp_id", ""))
	if data.effects.is_empty():
		contacts.clear()
	if _masks.size() > data.effects.size():
		_prune_masks()


func _apply_cells(effect: Dictionary) -> void:
	var mask: ContactMask
	while effect.cursor < effect.cells.size():
		var point: Vector2 = effect.cells[effect.cursor]
		var at := Motion.arrival(effect, point)
		if at > effect.age:
			break
		effect.cursor += 1
		if not effect.has("stamp_id"):
			# Pre-atlas saves display flat cells, whose centre is already a visible contact.
			pigment.legacy_contact(effect, point, {"point": point, "visible_at": at}, 0)
			continue
		if mask == null:
			mask = _mask(effect)
		var part := mask.part_for(effect, point)
		pigment.legacy_contact(effect, point, mask.sample(point, part, at), part)


func _mask(effect: Dictionary) -> ContactMask:
	var inputs := ContactMask.inputs(effect)
	var cached: Array = _masks.get(effect.stamp_id, NO_MASK)
	if cached.is_empty() or cached[0] != inputs:
		cached = [inputs.duplicate(true), ContactMask.new(effect)]
		_masks[effect.stamp_id] = cached
	return cached[1]


func _prune_masks() -> void:
	# Lifecycle resets can clear effects outside _tick_paint().
	var live := {}
	for effect in data.effects:
		live[effect.get("stamp_id", "")] = true
	for id in _masks.keys():
		if not live.has(id):
			_masks.erase(id)
