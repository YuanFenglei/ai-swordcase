extends RefCounted
# One procedural leg: optional coxa + analytic two-bone IK, planted foot with stepping arc.
# Segment meshes are modelled along +Y from the joint, with +Z as the outer (knee) side.

var coxa_mi: MeshInstance3D
var upper_mi: MeshInstance3D
var lower_mi: MeshInstance3D
var mount := Vector3.ZERO      # body-local hip mount
var rest := Vector3.ZERO       # body-local rest foot position
var l0 := 0.0
var l1 := 1.0
var l2 := 1.0
var group := 0
var index := 0
var side := 1.0

var foot := Vector3.ZERO       # current foot target (world)
var tip := Vector3.ZERO        # actual solved tip
var knee := Vector3.ZERO
var hip := Vector3.ZERO
var stepping := false
var st := 0.0
var sdur := 0.25
var sfrom := Vector3.ZERO
var sto := Vector3.ZERO
var slift := 0.5
var on_land := Callable()
var err := 0.0
var free_t := -1.0             # >=0: leg is flailing in the air (no ground target)


func setup(parent: Node3D, coxa: Mesh, upper: Mesh, lower: Mesh, mat: Material) -> void:
	if coxa != null:
		coxa_mi = _mi(parent, coxa, mat)
	upper_mi = _mi(parent, upper, mat)
	lower_mi = _mi(parent, lower, mat)


func _mi(parent: Node3D, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.top_level = true
	parent.add_child(mi)
	return mi


func parts() -> Array:
	var a: Array = [upper_mi, lower_mi]
	if coxa_mi != null:
		a.append(coxa_mi)
	return a


func set_param(p: StringName, v: Variant) -> void:
	upper_mi.set_instance_shader_parameter(p, v)
	lower_mi.set_instance_shader_parameter(p, v)
	if coxa_mi != null:
		coxa_mi.set_instance_shader_parameter(p, v)


func set_visible(v: bool) -> void:
	upper_mi.visible = v
	lower_mi.visible = v
	if coxa_mi != null:
		coxa_mi.visible = v


func free_nodes() -> void:
	for p in parts():
		p.queue_free()


func begin_step(target: Vector3, dur: float, lift: float) -> void:
	stepping = true
	st = 0.0
	sdur = dur
	sfrom = foot
	sto = target
	slift = lift + absf(target.y - foot.y) * 0.5


func advance(dt: float) -> void:
	if not stepping:
		return
	st += dt / sdur
	if st >= 1.0:
		stepping = false
		foot = sto
		if on_land.is_valid():
			on_land.call(self)
		return
	var e := st * st * (3.0 - 2.0 * st)
	foot = sfrom.lerp(sto, e)
	foot.y += sin(st * PI) * slift


func solve(xf: Transform3D, scl := 1.0) -> void:
	var up := xf.basis.y.normalized()
	var m := xf * mount
	var to_foot := foot - m
	var hd := to_foot - up * to_foot.dot(up)
	if hd.length_squared() < 1e-6:
		hd = xf.basis.x * side
	hd = hd.normalized()
	var a0 := l0 * scl
	var a1 := l1 * scl
	var a2 := l2 * scl
	hip = m + hd * a0
	var to := foot - hip
	var d := to.length()
	var dir := to / maxf(d, 1e-5)
	var dc := clampf(d, absf(a1 - a2) + 0.01, a1 + a2 - 0.001)
	var a := (a1 * a1 - a2 * a2 + dc * dc) / (2.0 * dc)
	var hh := sqrt(maxf(a1 * a1 - a * a, 0.0))
	var pole := up + hd * 0.25
	var perp := pole - dir * pole.dot(dir)
	if perp.length_squared() < 1e-6:
		perp = up
	perp = perp.normalized()
	knee = hip + dir * a + perp * hh
	tip = hip + dir * dc
	if coxa_mi != null:
		coxa_mi.global_transform = _seg(m, hip, up, scl)
	upper_mi.global_transform = _seg(hip, knee, perp, scl)
	lower_mi.global_transform = _seg(knee, tip, perp, scl)


func _seg(a: Vector3, b: Vector3, zref: Vector3, scl: float) -> Transform3D:
	var y := (b - a).normalized()
	var z := zref - y * zref.dot(y)
	if z.length_squared() < 1e-6:
		z = y.cross(Vector3.RIGHT)
	z = z.normalized()
	var x := y.cross(z)
	return Transform3D(Basis(x, y, z) * scl, a)


# Two-group alternating gait (tripod for 6 legs, trot for 4).
static func schedule(legs: Array, xf: Transform3D, vel: Vector3, thr: float, dur: float, lift: float, stride: float, probe: Callable) -> void:
	var busy := [false, false]
	var maxerr := [0.0, 0.0]
	for l in legs:
		if l.stepping:
			busy[l.group] = true
		var home: Vector3 = xf * l.rest
		var e := Vector2(l.foot.x - home.x, l.foot.z - home.z).length()
		l.err = e
		if e > maxerr[l.group]:
			maxerr[l.group] = e
	if busy[0] or busy[1]:
		return
	var g := 0 if maxerr[0] >= maxerr[1] else 1
	if maxerr[g] < thr:
		return
	var sp := vel.length()
	var lead := vel * dur
	if sp > 0.01:
		lead += vel / sp * minf(sp * 0.16, stride)
	for l in legs:
		if l.group == g and l.err > thr * 0.3:
			var home: Vector3 = xf * l.rest + lead
			l.begin_step(probe.call(home), dur, lift)
