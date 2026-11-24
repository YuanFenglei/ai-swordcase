extends RefCounted
## Shared contact clock. Simulation, warnings and previews consume these functions.
const Legacy = preload("res://full_game/legacy_brush.gd")
const C = preload("res://full_game/catalog.gd")
const DRAW_TIME = 0.62
const DURATION = 1.05
const FLIGHT_STEPS := 8
const FLIGHT_TIME := 0.36


static func local_point(effect: Dictionary, point: Vector2) -> Vector2:
	return C.local_point(point, effect.pos, effect.direction, C.brush_scale(effect.mods, bool(effect.active)))


static func draw_time(effect: Dictionary) -> float:
	if effect.has("spray"):
		return float(effect.get("landed", 0.82)) if int(effect.spray.kind) == 3 else float(effect.spray.duration)
	if effect.brush == "circle":
		return 0.62 * (1.0 - 0.15 * float(effect.mods.get("stamp_haste", 0)))
	if effect.brush in ["horizontal", "ring"]:
		return 0.10 + 0.52 / (1.0 + 0.2 * float(effect.mods.get("draw_speed", 0)))
	return DRAW_TIME


static func arrival(effect: Dictionary, point: Vector2) -> float:
	if not effect.has("target") and effect.has("cells"):
		return Legacy.arrival(effect, point)
	var p := local_point(effect, point)
	var g := C.geometry(effect.brush, effect.mods, effect.active)
	var progress := 0.0
	match effect.brush:
		"bucket":
			progress = p.length() / g.reach
		"horizontal":
			progress = (p.x / g.length + 1.0) * 0.5
		"vertical":
			progress = p.y / g.reach
		"ring":
			progress = maxf(0, p.distance_to(Vector2(0, g.distance)) - g.ring_width) / g.ring_radius
		"circle":
			return draw_time(effect)
		"triple":
			var centers := C.centers(effect.brush, effect.mods, effect.active)
			for i in centers.size():
				if p.distance_to(centers[i]) <= g.point_radius:
					return 0.10 + float(i) * 0.26
	return 0.10 + clampf(progress, 0.0, 1.0) * (draw_time(effect) - 0.10)


static func contact(effect: Dictionary, point: Vector2, previous: float) -> bool:
	if not effect.has("target") and effect.has("cells"):
		return (
			Legacy.inside(
				effect.brush, point, effect.pos, effect.direction, effect.mods, effect.active
			)
			and Legacy.arrival(effect, point) <= effect.age
		)
	if not C.inside(effect.brush, point, effect.pos, effect.direction, effect.mods, effect.active):
		return false
	var at := arrival(effect, point)
	if effect.brush == "ring":
		var g := C.geometry(effect.brush, effect.mods, effect.active)
		var radius := local_point(effect, point).distance_to(Vector2(0, g.distance))
		var before: float = (
			clampf((previous - 0.10) / (draw_time(effect) - 0.10), 0, 1) * g.ring_radius
		)
		return (
			effect.age >= at and previous <= draw_time(effect) and radius >= before - g.ring_width
		)
	return at > previous and at <= effect.age


static func world_point(effect: Dictionary, p: Vector2) -> Vector2:
	var d: Vector2 = effect.direction
	return (
		Vector2(effect.pos) + (Vector2(-d.y, d.x) * p.x + d * p.y) * (C.brush_scale(effect.mods, bool(effect.active)))
	)


static func flight_point(origin: Vector2, target: Vector2, radius: float, progress: float,
	terrain: RefCounted = null) -> Vector3:
	var height := (1.0 - progress) * 0.60 + sin(progress * PI) * 0.65
	if terrain != null:
		return terrain.position(origin.lerp(target, progress), height)
	return preload("res://full_game/paint_coordinates.gd").position(origin.lerp(target, progress), radius, height)


static func tip(effect: Dictionary, progress: float) -> Vector2:
	var g := C.geometry(effect.brush, effect.mods, effect.active)
	var p := Vector2.ZERO
	match effect.brush:
		"horizontal":
			p = Vector2(lerpf(-g.length, g.length, progress), g.distance)
		"vertical":
			p = Vector2(0, g.reach * progress)
		"ring":
			p = Vector2(g.ring_radius * progress, g.distance)
	return world_point(effect, p)
