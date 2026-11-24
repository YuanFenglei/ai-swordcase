extends RefCounted
## Queue actual ink samples in the existing half-metre chart. The projected footprint
## stays metric on the sphere, including cells on opposite sides of the antipode.
const Shape = preload("res://full_game/spray_shape.gd")
const Coords = Shape.Coords
# Subcell samples lie within 0.1875 * sqrt(2) chart metres of the centre; the planet chart never
# lengthens distances, so 0.27 m (with float slack) bounds them on the sphere too.
const SUBCELL_REACH := 0.27


static func queue(effect: Dictionary, radius: float) -> void:
	var s: Dictionary = effect.spray
	var center := Shape.point(s, 0.5, 0.5)
	var span := 0.0
	for u in [0.0, 1.0]:
		for v in [0.0, 1.0]:
			span = maxf(span, center.distance_to(Shape.point(s, u, v)))
	span += 0.5
	var chart := Coords.planar(center, radius)
	var angle := minf(PI, (chart.length() + span) / radius)
	var limit := minf(PI * radius * 2, span * maxf(1.0, angle / maxf(0.00001, sin(angle))))
	var entries: Array = []
	var rim := PI * radius + 0.36
	var inner := maxf(0, chart.length() - span)
	var outer := minf(rim, chart.length() + span)
	for y in range(floori(maxf(-outer, chart.y - limit) * 2), ceili(minf(outer, chart.y + limit) * 2)):
		var cy := (y + 0.5) * 0.5
		var edge := sqrt(maxf(0, outer * outer - cy * cy))
		var low := maxi(floori((chart.x - limit) * 2), floori(-edge * 2))
		var high := mini(ceili((chart.x + limit) * 2), ceili(edge * 2))
		var gap := sqrt(maxf(0, inner * inner - cy * cy))
		for x in range(low, high):
			var cell := Vector2(x + 0.5, y + 0.5) * 0.5
			if absf(cell.x) + 0.36 < gap:
				continue
			var hit := sample_cell(s, cell, center, span, radius)
			if hit.has("point"):
				entries.append(hit)
	entries.sort_custom(func(a, b): return a.u < b.u)
	for entry in entries:
		effect.cells.append(entry.point)


static func sample_cell(s: Dictionary, cell: Vector2, center: Vector3, span: float, radius: float) -> Dictionary:
	var world := Coords.position(cell, radius)
	if world.distance_squared_to(center) > span * span:
		return {}
	var delta: Vector3 = world - s.origin
	var along := delta.dot(s.axis)
	var side := delta.dot(s.cross)
	var width := lerpf(s.w0, s.width, clampf((along + 0.36) / s.length, 0, 1))
	var root_v: float = Shape.ROOTS[int(s.kind)]
	if along < -0.36 or along > s.length + 0.36 or side < -root_v * width - 0.36 or side > (1.0-root_v)*width+0.36:
		return {}
	if int(s.kind) in [0, 2] and along < 0.36 and absf(side) < 0.36:
		var foot := Coords.planar(Shape.point(s, 0.001, root_v), radius)
		if (foot * 2.0).floor() == (cell * 2.0).floor():
			return {"point": foot, "u": 0.001}
	# Prefer the centre for the CPU query, then find ink inside edge cells.
	var uv := Shape.uv_at(s, world)
	if cell.length() <= PI * radius and Shape.alpha(int(s.kind), uv) > 0.025:
		return {"point": cell, "u": uv.x}
	if not Shape.ink_possible(s, along, side, SUBCELL_REACH):
		return {}
	for i in 16:
		var p := cell + (Vector2(i % 4, floori(i / 4.0)) - Vector2.ONE * 1.5) * 0.125
		uv = Shape.uv_at(s, Coords.position(p, radius))
		if p.length() <= PI * radius and Shape.alpha(int(s.kind), uv) > 0.025:
			return {"point": p, "u": uv.x}
	return {}


static func trace(paint: RefCounted, effect: Dictionary, point: Vector2) -> Dictionary:
	var s: Dictionary = effect.spray
	var radius: float = paint.world_radius
	var end := Coords.position(point, radius, 0.075)
	var terrain: RefCounted = paint.space.terrain
	var start: Vector3 = terrain.position(effect.pos, 0.075)
	var base := start
	if int(s.kind) == Shape.LOB:
		base = effect.ball + effect.normal * 0.075
	elif int(s.kind) == Shape.SWEEP:
		base = Shape.point(s, 0, Shape.uv_at(s, end).y).normalized() * (radius + 0.075)
		base = terrain.lift_point(base)
		var blocked: Dictionary = paint.space.trace(start, base, int(effect.source))
		if not blocked.is_empty():
			return blocked
	# Follow curved ground in short chords so long segments cannot hit the planet early.
	end = terrain.lift_point(end)
	var steps := maxi(1, ceili(base.distance_to(end) / 1.0))
	var previous := base
	for i in range(1, steps + 1):
		var next := base.lerp(end, float(i) / steps).normalized() * (radius + 0.075)
		next = terrain.lift_point(next)
		var hit: Dictionary = paint.space.trace(previous, next, int(effect.source))
		previous = next
		if not hit.is_empty():
			return hit
	return {"surface": "ground", "position": terrain.position(point),
		"normal": terrain.surface_normal(end.normalized())}
