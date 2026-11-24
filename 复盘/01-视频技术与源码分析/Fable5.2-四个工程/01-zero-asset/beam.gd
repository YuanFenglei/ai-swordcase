extends Node3D
# Stretched energy beam: inner core + outer halo cylinders.
const MB = preload("res://mb.gd")
var inner: MeshInstance3D
var outer: MeshInstance3D
var width := 1.0


func build(col: Color) -> void:
	top_level = true
	var mb := MB.new()
	mb.xf = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3.ZERO)
	mb.lathe(PackedVector2Array([Vector2(1, 0), Vector2(1, 1)]), 14)
	var mesh := mb.build()
	inner = MeshInstance3D.new()
	inner.mesh = mesh
	inner.material_override = G.smat("beam", {"tint": col, "core": 1.0})
	inner.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inner)
	outer = MeshInstance3D.new()
	outer.mesh = mesh
	outer.material_override = G.smat("beam", {"tint": col, "core": 0.0})
	outer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(outer)
	visible = false


func set_span(a: Vector3, b: Vector3) -> void:
	var d := a - b
	var ln := maxf(d.length(), 0.1)
	var z := d / ln
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 1e-5:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x)
	global_transform = Transform3D(Basis(x, y, z * ln), a)
	var r := 0.1 * width
	inner.scale = Vector3(r, r, 1)
	outer.scale = Vector3(r * 3.6, r * 3.6, 1)
	inner.set_instance_shader_parameter(&"len", ln)
	outer.set_instance_shader_parameter(&"len", ln)
	outer.set_instance_shader_parameter(&"power", 0.35)
