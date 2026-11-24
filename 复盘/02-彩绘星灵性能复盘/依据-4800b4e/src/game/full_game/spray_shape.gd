extends RefCounted
## Metre-space projection shared by ground sampling and the GPU stamp descriptors.
const C = preload("res://full_game/catalog.gd")
const Coords = preload("res://full_game/paint_coordinates.gd")
const ATLAS = preload("res://full_game/art/颜料攻击/四星灵喷彩.png")
const HERO_MASK = preload("res://full_game/art/颜料攻击/主角湿笔.svg")
const SIZES := [Vector2i(124, 116), Vector2i(200, 116), Vector2i(147, 113), Vector2i(156, 113), Vector2i(512, 128), Vector2i(512, 128), Vector2i(512, 128)]
const ROOTS := [107.0 / 116, 0.5, 25.0 / 113, 0.5, 0.5, 0.5, 0.5]
const HERO_FAN := 4
const HERO_VARIANTS := 3
const SWEEP := 1
const LOB := 3
const FLIGHT := 0.82
static var hero_pixels: Image
static var pixels: Image
# Ink extents per atlas row, built once per spray kind from the image's own alpha.
static var _rows: Dictionary = {}


static func create(effect: Dictionary, kind: int, radius: float) -> Dictionary:
	if kind == HERO_FAN:
		kind += posmod(int(effect.get("visual_variant", 0)), HERO_VARIANTS)
	var foot := Coords.position(effect.pos, radius)
	var direction: Vector2 = effect.direction
	if effect.get("hero_ink", false) and kind == 0:
		# The fan atlas originates at its bottom corner. Aim the ink belly along the cast direction.
		direction = direction.rotated(0.22)
	var ahead := Coords.position(effect.pos + direction * 0.05, radius)
	var axis := (ahead - foot).slide(foot.normalized()).normalized()
	if axis.is_zero_approx():
		axis = Coords.frame(effect.pos, radius).basis.x
	var across := axis.cross(foot.normalized()).normalized()
	var mods: Dictionary = effect.mods
	var scale := C.brush_scale(mods, bool(effect.active))
	var reach := 4.2 * scale
	var width := (3.2 if kind == 0 else 2.1) * scale
	var start_width := (1.1 if kind == 0 else 0.20) * scale
	var origin := foot
	if kind == SWEEP:
		reach = 3.5 * scale * (1.0 + 0.15 * float(mods.get("ring", 0)))
		width = 2.0 * scale * (1.0 + 0.25 * float(mods.get("ring_width", 0)))
		start_width = width
		origin += axis * (0.8 * scale + width * 0.5) - across * reach * 0.5
		var facing := axis
		axis = across
		across = -facing
	elif kind == LOB:
		reach = 4.6 * scale * (1.0 + 0.2 * float(mods.get("width", 0)))
		width = reach * 113.0 / 156.0
		start_width = width
	elif kind == 0 or kind >= HERO_FAN:
		if kind >= HERO_FAN:
			start_width = 1.0
			width = 4.0
			# The registry measures the axis on the tangent plane, not along the surface arc.
			reach = radius * sin(C.HERO_ATTACK_RANGE / radius) + 0.0001
		width *= 1.0 + 0.2 * float(mods.get("fan_angle", 0))
	else:
		reach *= 1.0 + 0.2 * float(mods.get("sweep_length", 0))
		width *= 1.0 + 0.2 * float(mods.get("width", 0))
	var duration := 0.52
	if kind in [SWEEP, 2]:
		duration /= 1.0 + 0.2 * float(mods.get("draw_speed", 0))
	return {"kind": kind, "origin": origin, "axis": axis, "cross": across,
		"length": reach, "w0": start_width, "width": width, "duration": duration}


static func uv_at(s: Dictionary, pos: Vector3) -> Vector2:
	var d: Vector3 = pos - s.origin
	return project_uv(d.dot(s.axis), d.dot(s.cross), s.length, ROOTS[int(s.kind)], s.w0, s.width)


static func project_uv(along: float, side: float, length: float, root: float,
	start_width: float, end_width: float) -> Vector2:
	var u := along / length
	return Vector2(u, root + side / lerpf(start_width, end_width, clampf(u, 0, 1)))


static func point(s: Dictionary, u: float, v: float) -> Vector3:
	var offset: Vector3 = s.axis * (u * s.length) + s.cross * ((v - ROOTS[int(s.kind)]) * lerpf(s.w0, s.width, u))
	if int(s.kind) >= HERO_FAN:
		var origin: Vector3 = s.origin
		return origin.normalized() * sqrt(maxf(0.0, origin.length_squared() - offset.length_squared())) + offset
	return s.origin + offset


static func alpha(kind: int, uv: Vector2) -> float:
	if not Rect2(0, 0, 1, 1).has_point(uv):
		return 0.0
	if kind >= HERO_FAN:
		var pixel := Vector2i(uv * Vector2(SIZES[kind]))
		pixel.y += (kind - HERO_FAN) * int(SIZES[kind].y)
		return _hero_pixels().get_pixelv(pixel).a
	if kind == LOB:
		var offset := (uv - Vector2(77.5 / 156, 0.5)) * Vector2(1, 113.0 / 156)
		if offset.length_squared() > 0.25:
			return 0.0
	if pixels == null:
		pixels = ATLAS.get_image()
	var at := Vector2i(uv * Vector2(SIZES[kind])) + Vector2i(0, kind * 160)
	return pixels.get_pixelv(at).a


## Conservative: false only when no point within `reach` metres of the projection point at
## (along, side) can give alpha() > 0.025, so a caller may skip those samples exactly.
static func ink_possible(s: Dictionary, along: float, side: float, reach: float) -> bool:
	var kind := int(s.kind)
	var u_low := (along - reach) / float(s.length)
	var u_high := (along + reach) / float(s.length)
	# The width is monotonic in u, so corners of the (u, side) box bound v = root + side / width.
	var w_low := lerpf(s.w0, s.width, clampf(u_low, 0, 1))
	var w_high := lerpf(s.w0, s.width, clampf(u_high, 0, 1))
	var v_low: float = ROOTS[kind] + minf((side - reach) / w_low, (side - reach) / w_high)
	var v_high: float = ROOTS[kind] + maxf((side + reach) / w_low, (side + reach) / w_high)
	if u_high < 0.0 or u_low >= 1.0 or v_high < 0.0 or v_low >= 1.0:
		return false
	var size: Vector2i = SIZES[kind]
	var rows := _ink_rows(kind)
	var first := clampi(floori(v_low * size.y) - 1, 0, size.y - 1)
	for y in range(first, clampi(floori(v_high * size.y) + 1, 0, size.y - 1) + 1):
		if rows[y * 2] <= floori(u_high * size.x) + 1 and rows[y * 2 + 1] >= floori(u_low * size.x) - 1:
			return true
	return false


static func _hero_pixels() -> Image:
	if hero_pixels == null:
		hero_pixels = HERO_MASK.get_image()
		if hero_pixels.is_compressed():
			hero_pixels.decompress()
	return hero_pixels


static func _ink_rows(kind: int) -> PackedInt32Array:
	# Per atlas row, the first and last pixel with any alpha; empty rows never match.
	if _rows.has(kind):
		return _rows[kind]
	if pixels == null:
		pixels = ATLAS.get_image()
	var size: Vector2i = SIZES[kind]
	var source := _hero_pixels() if kind >= HERO_FAN else pixels
	var first_row: int = (kind - HERO_FAN) * size.y if kind >= HERO_FAN else kind * 160
	var rows := PackedInt32Array()
	for y in size.y:
		var used := source.get_region(Rect2i(0, first_row + y, size.x, 1)).get_used_rect()
		rows.append(used.position.x if used.has_area() else size.x)
		rows.append(used.end.x - 1 if used.has_area() else -1)
	_rows[kind] = rows
	return rows


static func arrival(effect: Dictionary, point_2d: Vector2, radius: float) -> float:
	var s: Dictionary = effect.spray
	if int(s.kind) == LOB:
		return effect.get("landed", FLIGHT)
	return clampf(uv_at(s, Coords.position(point_2d, radius)).x, 0, 1) * float(s.duration)


static func valid(s: Variant) -> bool:
	if not s is Dictionary or not (s.get("kind") is int or s.get("kind") is float):
		return false
	if s.kind != floorf(s.kind) or s.kind < 0 or s.kind >= HERO_FAN + HERO_VARIANTS:
		return false
	for key in ["origin", "axis", "cross"]:
		if not s.get(key) is Vector3 or not s[key].is_finite():
			return false
	for key in ["length", "w0", "width", "duration"]:
		if not (s.get(key) is float or s.get(key) is int) or not (s[key] > 0 and s[key] <= 100):
			return false
	return s.axis.is_normalized() and s.cross.is_normalized() and absf(s.axis.dot(s.cross)) < 0.001
