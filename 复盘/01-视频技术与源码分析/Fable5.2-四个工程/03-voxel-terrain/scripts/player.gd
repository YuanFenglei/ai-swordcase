extends CharacterBody3D

const VoxelWorld := preload("res://scripts/voxel_world.gd")

var main: Node3D
var world: RefCounted
var cam: Camera3D
var lamp: SpotLight3D
var fly := true
var yaw := 2.4
var pitch := -0.25
var tool_i := 0
var radius := 6.0
var fill_mat := 2
var _cool := 0.0
var _hit: Variant = null
var _bore_last := Vector3.INF
var _click := false
var test_walk := false
var _cam_base := Vector3(0, 0.7, 0)


func _ready() -> void:
	world = main.world
	collision_layer = 8
	collision_mask = 3
	floor_max_angle = deg_to_rad(52.0)
	floor_snap_length = 0.6
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.45
	cap.height = 1.8
	cs.shape = cap
	add_child(cs)
	cam = Camera3D.new()
	cam.fov = 72.0
	cam.near = 0.1
	cam.far = 2500.0
	cam.position = _cam_base
	add_child(cam)
	cam.make_current()
	lamp = SpotLight3D.new()
	lamp.spot_range = 60.0
	lamp.spot_angle = 42.0
	lamp.spot_angle_attenuation = 0.8
	lamp.light_energy = 5.0
	lamp.light_color = Color(1.0, 0.9, 0.76)
	lamp.shadow_enabled = true
	lamp.light_volumetric_fog_energy = 0.6
	cam.add_child(lamp)
	var x := 330.0
	var z := 205.0
	position = Vector3(x, world.surface_y(x, z) + 14.0, z)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if main.selftest:
		_selftest()


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= ev.relative.x * 0.0022
		pitch = clampf(pitch - ev.relative.y * 0.0022, -1.5, 1.5)
	elif ev is InputEventMouseButton and ev.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			radius = minf(radius + 1.0, 16.0)
			_sync()
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			radius = maxf(radius - 1.0, 2.0)
			_sync()
		elif ev.button_index == MOUSE_BUTTON_LEFT:
			_click = true
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.physical_keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				tool_i = ev.physical_keycode - KEY_1
				_sync()
			KEY_F:
				fly = not fly
			KEY_L:
				lamp.visible = not lamp.visible
			KEY_Q:
				fill_mat = (fill_mat + 1) % 7
				_sync()
			KEY_BRACKETLEFT:
				radius = maxf(radius - 1.0, 2.0)
				_sync()
			KEY_BRACKETRIGHT:
				radius = minf(radius + 1.0, 16.0)
				_sync()
			KEY_M:
				var c: Vector3 = _hit if _hit != null else global_position
				main.fx.meteor_shower(c, 60.0, 10, 4.0)
			KEY_B:
				if _hit != null:
					var h: Vector3 = _hit
					for i in 24:
						main.spawn_block(h + Vector3((i % 4) * 2.3 - 3.4, 2.0 + (i / 8) * 2.2, ((i / 4) % 2) * 2.3 - 1.1), i)
			KEY_R:
				get_tree().reload_current_scene()
			KEY_ESCAPE:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else:
					get_tree().quit()


func _sync() -> void:
	main.hud.set_tool(tool_i, radius, fill_mat)


func _process(dt: float) -> void:
	rotation = Vector3(0, yaw, 0)
	cam.rotation = Vector3(pitch, 0, 0)
	cam.position = _cam_base + cam.global_transform.basis.inverse() * main.fx.shake_offset() * 0.6
	var dir := -cam.global_transform.basis.z
	var from := cam.global_position
	_hit = world.raycast(from, dir, 400.0)
	_cool -= dt
	var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if tool_i == 4:
		var r := clampf(radius * 0.6, 2.6, 7.0)
		var p := from + dir * (r + 2.2)
		main.set_brush(p, r, Color(0.3, 0.95, 0.8))
		if down and (p.distance_to(_bore_last) > 0.9):
			_bore_last = p
			world.edit(VoxelWorld.OP_DIG, p, r)
	elif _hit != null:
		var h: Vector3 = _hit
		var cols := [Color(1.0, 0.72, 0.3), Color(0.4, 0.9, 0.5), Color(0.5, 0.75, 1.0), Color(1.0, 0.3, 0.15)]
		var br := radius * (1.5 if tool_i == 3 else 1.0)
		main.set_brush(h, br, cols[tool_i])
		if tool_i == 3:
			if _click:
				main.fx.explode(h, br)
		elif down and _cool <= 0.0:
			_cool = 0.045
			if tool_i == 0:
				world.edit(VoxelWorld.OP_DIG, h + dir * radius * 0.35, radius)
			elif tool_i == 1:
				var c := h - dir * radius * 0.45
				if c.distance_to(global_position) > radius + 1.6:
					world.edit(VoxelWorld.OP_FILL, c, radius, fill_mat)
			else:
				world.edit(VoxelWorld.OP_SMOOTH, h, radius + 1.0)
	else:
		main.set_brush(Vector3(0, -1000, 0), 0.0)
	_click = false


func _physics_process(dt: float) -> void:
	var iv := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W) or test_walk:
		iv.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		iv.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		iv.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		iv.x += 1.0
	var fast := Input.is_physical_key_pressed(KEY_SHIFT)
	if fly:
		var b := Basis.from_euler(Vector3(pitch, yaw, 0))
		var v := b * iv
		if Input.is_physical_key_pressed(KEY_SPACE):
			v.y += 1.0
		if Input.is_physical_key_pressed(KEY_CTRL):
			v.y -= 1.0
		var sp := 90.0 if fast else 30.0
		velocity = velocity.lerp(v.normalized() * sp if v.length() > 0.01 else Vector3.ZERO, 1.0 - exp(-dt * 10.0))
	else:
		var b := Basis(Vector3.UP, yaw)
		var v := (b * iv)
		v.y = 0.0
		var sp := 15.0 if fast else 8.5
		var hv := v.normalized() * sp if v.length() > 0.01 else Vector3.ZERO
		var k := 1.0 - exp(-dt * (12.0 if is_on_floor() else 3.0))
		velocity.x = lerpf(velocity.x, hv.x, k)
		velocity.z = lerpf(velocity.z, hv.z, k)
		velocity.y -= 24.0 * dt
		if is_on_floor() and Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = 9.5
	move_and_slide()
	if position.y < -30.0:
		position.y = 150.0
		velocity = Vector3.ZERO


func _selftest() -> void:
	# scripted pass over every tool, then walk into a freshly bored tunnel
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var VW := VoxelWorld
	await get_tree().create_timer(1.0).timeout
	pitch = -0.6
	for t in 5:
		tool_i = t
		_sync()
		await get_tree().create_timer(0.3).timeout
		var h: Variant = world.raycast(cam.global_position, -cam.global_transform.basis.z, 400.0)
		if h == null:
			continue
		var hp: Vector3 = h
		match t:
			0: world.edit(VW.OP_DIG, hp, 6.0)
			1: world.edit(VW.OP_FILL, hp + Vector3(0, 3, 0), 5.0, 5)
			2: world.edit(VW.OP_SMOOTH, hp, 7.0)
			3: main.fx.explode(hp, 9.0)
			4: world.edit(VW.OP_DIG, hp, 4.0)
		await get_tree().create_timer(0.5).timeout
	# land, bore a tunnel into the slope ahead and walk in
	fly = false
	pitch = -0.12
	var gx := 300.0
	var gz := 200.0
	position = Vector3(gx, world.surface_y(gx, gz) + 1.5, gz)
	velocity = Vector3.ZERO
	reset_physics_interpolation()
	await get_tree().create_timer(0.8).timeout
	var y0 := position.y
	var fwd := -Basis(Vector3.UP, yaw).z
	for i in 26:
		world.edit(VW.OP_DIG, position + Vector3(0, 0.8 - i * 0.35, 0) + fwd * (3.0 + i * 1.4), 3.4)
	test_walk = true
	await get_tree().create_timer(4.0).timeout
	test_walk = false
	var moved := Vector2(position.x - gx, position.z - gz).length()
	print("SELFTEST walked %.1f m, dy %.1f, on_floor %s, roof above %s" % [moved, position.y - y0, is_on_floor(), world.surface_y(position.x, position.z) > position.y + 3.0])
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://_shots/11_play_tunnel.png")
	get_tree().quit()
