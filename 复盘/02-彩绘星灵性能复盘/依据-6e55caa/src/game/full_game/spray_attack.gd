extends RefCounted
## Released sprays own only delivery. HP, ground damage, recovery and dye writes
## still go through the combat and paint authorities.
const Shape = preload("res://full_game/spray_shape.gd")
const Contacts = preload("res://full_game/spray_contacts.gd")
const Coords = Shape.Coords
const State = preload("res://full_game/paint_state.gd")


static func prepare(effect: Dictionary, kind: int, radius: float, terrain: RefCounted = null) -> void:
	effect.spray = Shape.create(effect, kind, radius)
	if kind != Shape.LOB:
		Contacts.queue(effect, radius)
		return
	var start := Coords.position(effect.pos, radius, 0.55)
	# Growth changes the burst footprint, not the existing delivery point.
	var throw_limit := 4.2 * Shape.C.brush_scale({}, bool(effect.active))
	var distance := minf(effect.pos.distance_to(effect.target), throw_limit)
	var landing: Vector3 = (effect.spray.origin + effect.spray.axis * distance).normalized() * (radius - 0.01)
	if terrain != null:
		start = terrain.lift_point(start)
		landing = terrain.lift_point(landing)
	effect.ball = start
	effect.gravity = -start.normalized() * 9.8
	effect.velocity = (landing - start) / Shape.FLIGHT - effect.gravity * (0.5 * Shape.FLIGHT)
	effect.life = 3.0


static func advance(brushes: RefCounted, e: Dictionary, dt: float) -> void:
	var s: Dictionary = e.spray
	if int(s.kind) == Shape.LOB:
		if e.has("landed"):
			return
		if not fly(brushes, e, dt):
			return
		if e.landing_surface != "ground":
			roof(brushes, e)
			blast_damage(brushes, e)
			return
		Contacts.queue(e, brushes.pigment.world_radius)
	var paint: RefCounted = brushes.pigment
	# Contacts never move the landed ball, so one projection serves every cell of this step.
	var from: Vector2 = Coords.planar(e.ball, paint.world_radius) if int(s.kind) == Shape.LOB else e.pos
	while e.cursor < e.cells.size():
		var p: Vector2 = e.cells[e.cursor]
		if Shape.arrival(e, p, paint.world_radius) > e.age:
			break
		e.cursor += 1
		if not brushes.spatial.line_clear(from, p):
			continue
		var hit := Contacts.trace(paint, e, p)
		if int(s.kind) == Shape.LOB and hit.surface != "ground":
			continue
		contact(brushes, e, hit, p)
	if int(s.kind) == Shape.LOB:
		blast_damage(brushes, e)
	elif e.age - dt <= s.duration:
		swept_damage(brushes, e, dt)


static func fly(brushes: RefCounted, e: Dictionary, dt: float) -> bool:
	var paint: RefCounted = brushes.pigment
	var remaining := dt
	while remaining > 0.000001:
		var step := minf(1.0 / 120.0, remaining)
		var next: Vector3 = e.ball + e.velocity * step + e.gravity * (0.5 * step * step)
		var hit: Dictionary = paint.space.trace(e.ball, next, int(e.source), false)
		e.velocity += e.gravity * step
		remaining -= step
		if hit.is_empty():
			e.ball = next
			continue
		var up: Vector3 = hit.position.normalized()
		if hit.normal.dot(up) < 0.6:
			e.ball = hit.position + hit.normal * 0.018
			e.velocity = -up * maxf(0.15, -e.velocity.dot(up))
			continue
		e.ball = hit.position
		e.normal = hit.normal
		e.landed = e.age - remaining
		e.life = maxf(0.01, 0.45 - remaining)
		e.landing_surface = hit.surface
		var s: Dictionary = e.spray
		var ground: bool = hit.surface == "ground"
		var projection_normal: Vector3 = up if ground else hit.normal
		s.axis = s.axis.slide(projection_normal).normalized()
		s.cross = s.axis.cross(projection_normal).normalized()
		var center: Vector3 = up * paint.world_radius if ground else e.ball
		s.origin = center - s.axis * (s.length * 77.5 / 156.0)
		# Landing establishes the final projection before the first writable cell.
		paint.data.paint.stamps[e.stamp_id].spray = s.duplicate(true)
		paint.data.paint.stamps[e.stamp_id].landed = e.landed
		return true
	return false


static func contact(brushes: RefCounted, e: Dictionary, hit: Dictionary, point: Vector2) -> void:
	var paint: RefCounted = brushes.pigment
	if hit.surface == "ground":
		var payload := {"source": e.source, "round": e.round, "color": e.color, "damage": e.dot, "stamp_id": e.stamp_id}
		if e.get("hero_ink", false):
			payload.hero_ink = true
		if not State.ground(paint, point, payload):
			return
	else:
		if not State.apply_hit(paint, paint.space, hit, e, 0.32):
			return
		var actor_id := int(hit.get("actor", 0))
		if actor_id > 0:
			var enemy: Dictionary = brushes.characters.find_enemy(actor_id)
			if not enemy.is_empty():
				damage(brushes, e, enemy)
	paint._record_impact(e, hit, point, {"visible_at": e.age, "point": point}, 0)


static func damage(brushes: RefCounted, e: Dictionary, enemy: Dictionary, indexed := false) -> void:
	if int(e.spray.kind) >= Shape.HERO_FAN and Vector2(e.pos).distance_to(enemy.pos) > Shape.C.HERO_ATTACK_RANGE:
		return
	if not indexed:
		brushes.contacts.refresh_hits(e)
	if brushes.contacts.has_hit(int(enemy.id)):
		return
	brushes.contacts.emit_hit(brushes.enemy_hit, e, enemy)


static func swept_damage(brushes: RefCounted, e: Dictionary, dt: float) -> void:
	var s: Dictionary = e.spray
	var paint: RefCounted = brushes.pigment
	brushes.contacts.refresh_hits(e)
	for enemy in brushes.contacts.enemies(brushes.characters.enemies()):
		if brushes.contacts.has_hit(int(enemy.id)) or not brushes.spatial.line_clear(e.pos, enemy.pos):
			continue
		var at := Coords.position(enemy.pos, paint.world_radius)
		var uv := Shape.uv_at(s, at)
		if uv.x * s.duration < e.age - dt or uv.x * s.duration > e.age:
			continue
		if Shape.alpha(int(s.kind), uv) <= 0.025:
			continue
		var query_can_change_hits: bool = paint.space.actor_query.is_valid()
		var hit := Contacts.trace(paint, e, enemy.pos)
		if query_can_change_hits:
			brushes.contacts.refresh_hits(e)
		if hit.surface != "ground" and hit.get("actor", 0) != enemy.id:
			continue
		if paint.space.actor_query.is_valid():
			var from: Vector3 = paint.space.terrain.position(e.pos, 0.40)
			if int(s.kind) == Shape.SWEEP:
				var sweep_up := Shape.point(s, 0.0, uv.y).normalized()
				from = paint.space.terrain.lift_point(sweep_up * (paint.world_radius + 0.40))
			var center: Vector3 = paint.space.terrain.position(enemy.pos, 0.40)
			var body: Dictionary = paint.space.trace(from, center + from.direction_to(center) * 0.55, int(e.source))
			if body.get("actor", 0) == enemy.id:
				contact(brushes, e, body, enemy.pos)
				brushes.contacts.refresh_hits(e)
				continue
			brushes.contacts.refresh_hits(e)
		damage(brushes, e, enemy, true)


static func roof(brushes: RefCounted, e: Dictionary) -> void:
	var paint: RefCounted = brushes.pigment
	var s: Dictionary = e.spray
	var hit := {"position": e.ball, "normal": e.normal, "surface": e.landing_surface}
	var covered := func(pos: Vector3): return Shape.alpha(Shape.LOB, Shape.uv_at(s, pos)) > 0.025
	State.paint_surface(paint, paint.space, hit, e, float(s.length) * 0.65, covered)


static func blast_damage(brushes: RefCounted, e: Dictionary) -> void:
	var paint: RefCounted = brushes.pigment
	for enemy in brushes.contacts.enemies(brushes.characters.enemies()):
		var target: Vector3 = paint.space.terrain.position(enemy.pos, 0.35)
		if e.ball.distance_to(target) > float(e.spray.length) * 0.5:
			continue
		var from: Vector3 = e.ball + e.normal * 0.08
		if not brushes.spatial.line_clear(Coords.planar(from, paint.world_radius), enemy.pos):
			continue
		var hit: Dictionary = paint.space.trace(from, target + from.direction_to(target) * 0.30, int(e.source))
		if hit.get("actor", 0) == enemy.id:
			contact(brushes, e, hit, enemy.pos)
		elif hit.is_empty():
			damage(brushes, e, enemy)
