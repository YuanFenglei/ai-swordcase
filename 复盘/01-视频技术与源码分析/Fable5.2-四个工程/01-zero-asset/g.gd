extends Node
# Global registry + palette. Everything else reaches its neighbours through here.

const C_CYAN := Color(0.2, 0.9, 1.0)
const C_TEAL := Color(0.1, 0.85, 0.7)
const C_MAGENTA := Color(1.0, 0.16, 0.5)
const C_ORANGE := Color(1.0, 0.5, 0.16)
const C_VIOLET := Color(0.55, 0.3, 1.0)
const C_HULL := Color(0.72, 0.68, 0.62)
const C_HULL_DARK := Color(0.08, 0.085, 0.1)

const ARENA_R := 205.0

var main: Node3D
var terrain
var world
var scatter
var walker
var boss
var fx
var audio
var hud
var director
var cam: Camera3D
var creatures: Array = []
var cores: Array = []
var obstacles: Array = []   # Vector3(x, z, radius)

var demo := false
var shots := false
var rng := RandomNumberGenerator.new()
var shaders := {}
var prof := {}


func _ready() -> void:
	rng.seed = 90417
	RenderingServer.global_shader_parameter_add("push_a", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0, -999, 0))
	RenderingServer.global_shader_parameter_add("push_b", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0, -999, 0))
	for a in OS.get_cmdline_user_args():
		if a == "--demo":
			demo = true
		elif a == "--shots":
			demo = true
			shots = true


func shader(n: String) -> Shader:
	if not shaders.has(n):
		shaders[n] = load("res://shaders/%s.gdshader" % n)
	return shaders[n]


func smat(n: String, params := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(n)
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m


func h(x: float, z: float) -> float:
	return terrain.height(x, z)


func ground(p: Vector3, off := 0.0) -> Vector3:
	return Vector3(p.x, terrain.height(p.x, p.z) + off, p.z)


func flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func damp(a, b, k: float, dt: float):
	return lerp(a, b, 1.0 - exp(-k * dt))


func probe(x: float, z: float, top: float, depth: float) -> Vector3:
	var space := main.get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, top - depth, z))
		var r := space.intersect_ray(q)
		if not r.is_empty():
			return r.position
	return Vector3(x, terrain.height(x, z), z)
