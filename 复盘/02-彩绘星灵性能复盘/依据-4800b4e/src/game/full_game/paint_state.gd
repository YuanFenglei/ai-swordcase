extends RefCounted
## All colour writes pass through this authority. GPU textures are disposable views.
const Score = preload("res://full_game/colour_score.gd")
const Coordinates = preload("res://full_game/paint_coordinates.gd")
const Protection = preload("res://full_game/paint_protection.gd")
const C = preload("res://full_game/catalog.gd")
const Stamps = preload("res://full_game/paint_stamps.gd")
const VERSION := 1
const BODY_SIZE := 32


static func initialize(state: Dictionary) -> void:
	state.paint = {"version": VERSION, "surface_geometry": 2, "surfaces": {}, "bodies": {}, "projectiles": [],
		"droplets": [], "bursts": [], "next_id": 1, "accumulator": 0.0,
		"stamp_revision": 0, "layers_version": 1}


static func migrate(state: Dictionary) -> void:
	if state.is_empty() or state.has("paint"):
		return
	initialize(state)
	# Existing ground still needs the legacy layer rebuild before becoming canonical.
	state.paint.erase("layers_version")
	for node in state.get("map_nodes", []):
		if not node.cleared and not (state.phase == "battle" and node.id == state.node.id):
			node.charge = 0.0
	if state.phase == "explore":
		state.node.charge = 0.0


static func ground(paint: RefCounted, point: Vector2, payload: Dictionary) -> bool:
	if Protection.restored(paint.data, point, paint.world_radius):
		return false
	var key := "%d,%d" % [floori(point.x / 0.5), floori(point.y / 0.5)]
	var tile := payload.duplicate(true)
	# Zero is the persisted no-countdown value; clearing still uses the existing owners.
	tile.life = 0.0
	tile.damage_life = C.GROUND_DAMAGE_LIFE if float(tile.get("damage", 0.0)) > 0.0 else 0.0
	if tile.get("stamp_id", "") == "":
		tile.erase("stamp_id")
	for field in ["color", "source", "round"]:
		if tile.has(field):
			tile[field] = int(tile[field])
	tile.pos = Vector2(floor(point.x / 0.5) + 0.5, floor(point.y / 0.5) + 0.5) * 0.5
	# Coarse legacy cells cannot straddle a protected boundary with writable colour.
	if Protection.restored(paint.data, tile.pos, paint.world_radius):
		return false
	tile.wet_at = paint.data.elapsed
	Stamps.overlay(paint.data, paint.data.ground.get(key, {}), tile)
	if not paint.data.ground.has(key):
		Score.paint_cell(paint.data, key, tile.pos, paint.world_radius)
	paint.data.ground[key] = tile
	if tile.damage > 0.0:
		paint.damaging_cells[key] = true
	else:
		paint.damaging_cells.erase(key)
	paint.mark_cell(key)
	return true


static func clear_ground(paint: RefCounted, center: Vector2, radius: float) -> void:
	for key in paint.data.ground.keys():
		var point: Vector2 = paint.data.ground[key].pos
		if point.distance_to(center) <= radius and not Protection.restored(paint.data, point, paint.world_radius):
			_erase_cell(paint, key)


static func remove_ground_record(state: Dictionary, key: String) -> void:
	Stamps.remove_cell(state, state.ground[key])
	state.paint.get_or_add("scored_cells", {})[key] = true
	state.ground.erase(key)


static func _erase_cell(paint: RefCounted, key: String) -> void:
	remove_ground_record(paint.data, key)
	paint.damaging_cells.erase(key)
	paint.mark_cell(key)


static func tick_ground(paint: RefCounted, delta: float) -> void:
	# Runs every simulation step over every damaging cell: resolve shared lookups once and
	# erase expired keys after the walk instead of copying the whole key list each step.
	var cells: Dictionary = paint.data.ground
	var full_life := C.GROUND_DAMAGE_LIFE
	var expired: Array = []
	for key in paint.damaging_cells:
		var tile: Dictionary = cells[key]
		var life := float(tile.get("damage_life", full_life)) - delta
		if life > 0.0:
			tile.damage_life = life
		else:
			tile.damage_life = 0.0
			tile.damage = 0.0
			expired.append(key)
	for key in expired:
		paint.damaging_cells.erase(key)


static func apply_hit(paint: RefCounted, space: RefCounted, hit: Dictionary, ink: Dictionary, size: float) -> bool:
	var planar := Coordinates.planar(hit.position, paint.world_radius)
	if Protection.restored(paint.data, planar, paint.world_radius):
		return false
	if hit.get("actor", 0) != 0:
		if friendly_body(paint.data, int(hit.actor)) or hit.get("immune", false):
			return false
		body(paint, int(hit.actor), hit.uv, int(ink.color), size / maxf(0.2, float(hit.height)))
		return true
	if hit.surface == "ground":
		return ground(paint, planar, {"color": int(ink.color), "life": 0.0, "damage": 0.0,
			"source": int(ink.source), "hero_ink": ink.get("hero_ink", false), "round": int(ink.get("round", 0)),
			"stamp_id": ink.get("stamp_id", "")})
	if not space.surfaces.has(hit.surface):
		return false
	return paint_surface(paint, space, hit, ink, size)


static func paint_surface(paint: RefCounted, space: RefCounted, hit: Dictionary, ink: Dictionary, size: float,
	covered: Callable = Callable()) -> bool:
	var color := int(ink.color)
	var wet := ink.has("spray")
	var surface: Dictionary = space.surfaces[hit.surface]
	var geometry: RefCounted = surface.geometry
	var local: Vector3 = surface.transform.affine_inverse() * hit.position
	var normal: Vector3 = surface.transform.basis.inverse() * hit.normal
	var changed := false
	var accepted := false
	var record := surface_record(paint.data, hit.surface)
	for index in geometry.nearby(local, size):
		var key := str(index)
		if geometry.normals[index].dot(normal) < 0.25:
			continue
		var point: Vector3 = surface.transform * geometry.positions[index]
		if covered.is_valid() and not covered.call(point):
			continue
		if Protection.restored(paint.data, Coordinates.planar(point, paint.world_radius), paint.world_radius):
			continue
		var obstruction: Dictionary = space.trace(hit.position + hit.normal * 0.015,
			point + surface.transform.basis * geometry.normals[index] * 0.015)
		if not obstruction.is_empty():
			continue
		accepted = true
		if wet:
			if not record.has("wet"):
				record.wet = {}
			record.wet[key] = float(paint.data.elapsed)
			changed = true
		elif record.has("wet"):
			changed = record.wet.erase(key) or changed
		if int(record.colors.get(key, -1)) == color:
			continue
		record.colors[key] = color
		changed = true
	if changed:
		record.revision += 1
		paint.dirty = true
		if int(surface.node) >= 0:
			paint.mark_node(int(surface.node))
	return accepted


static func surface_record(state: Dictionary, id: String) -> Dictionary:
	if not state.paint.surfaces.has(id):
		state.paint.surfaces[id] = {"colors": {}, "revision": 0}
	return state.paint.surfaces[id]


static func body(paint: RefCounted, actor_id: int, uv: Vector2, color: int, radius: float = 0.18) -> void:
	if friendly_body(paint.data, actor_id):
		return
	var key := str(actor_id)
	if not paint.data.paint.bodies.has(key):
		paint.data.paint.bodies[key] = {"colors": {}, "revision": 0}
	var record: Dictionary = paint.data.paint.bodies[key]
	# Widen by one texel before applying the original pixel-center distance test.
	var edge := Vector2.ONE * BODY_SIZE
	var first := ((uv - Vector2.ONE * radius) * BODY_SIZE - Vector2.ONE).clamp(Vector2.ZERO, edge)
	var last := ((uv + Vector2.ONE * radius) * BODY_SIZE + Vector2.ONE).clamp(Vector2.ZERO, edge)
	for y in range(floori(first.y), ceili(last.y)):
		for x in range(floori(first.x), ceili(last.x)):
			var p := (Vector2(x, y) + Vector2.ONE * 0.5) / float(BODY_SIZE)
			if p.distance_to(uv) <= radius:
				record.colors[str(y * BODY_SIZE + x)] = color
	record.revision += 1
	paint.dirty = true


static func friendly_body(state: Dictionary, actor_id: int) -> bool:
	if actor_id == -1:
		return true
	for slot in state.get("slots", []):
		if int(slot.id) == actor_id:
			return true
	var node: Dictionary = state.get("node", {})
	return not node.is_empty() and actor_id == -4000000000 - int(node.id)


static func clear_friendly_bodies(state: Dictionary) -> void:
	for id in state.paint.bodies.keys():
		if friendly_body(state, int(id)):
			state.paint.bodies.erase(id)


static func legacy_body(paint: RefCounted, enemy: Dictionary, color: int, origin: Variant) -> void:
	if Protection.immune(enemy) or Protection.restored(paint.data, enemy.pos, paint.world_radius):
		return
	var uv := Vector2(0.5, 0.5)
	if origin is Vector2:
		uv.x += clampf((origin.x - float(enemy.pos.x)) * 0.04, -0.22, 0.22)
	body(paint, int(enemy.id), uv, color)


static func restore(paint: RefCounted, space: RefCounted) -> void:
	for key in paint.data.ground.keys():
		if Protection.restored(paint.data, paint.data.ground[key].pos, paint.world_radius):
			_erase_cell(paint, key)
	for id in paint.data.paint.surfaces.keys():
		if not space.surfaces.has(id):
			continue
		var surface: Dictionary = space.surfaces[id]
		var record: Dictionary = paint.data.paint.surfaces[id]
		var changed := false
		for key in record.colors.keys():
			var point: Vector3 = surface.transform * surface.geometry.positions[int(key)]
			if Protection.restored(paint.data, Coordinates.planar(point, paint.world_radius), paint.world_radius):
				record.colors.erase(key)
				if record.has("wet"):
					record.wet.erase(key)
				changed = true
		if changed:
			record.revision += 1
	for slot in paint.data.slots:
		if Protection.restored(paint.data, paint.source_position(slot), paint.world_radius):
			paint.data.paint.bodies.erase(str(int(slot.id)))
	if Protection.restored(paint.data, paint.data.player, paint.world_radius):
		paint.data.paint.bodies.erase("-1")
	paint.dirty = true


static func coverage(state: Dictionary, surface: Dictionary, color: int) -> float:
	var record: Dictionary = state.paint.surfaces.get(surface.id, {"colors": {}})
	var result := 0.0
	for key in record.colors:
		if int(record.colors[key]) == color and int(key) < surface.geometry.weights.size():
			result += surface.geometry.weights[int(key)]
	return result
