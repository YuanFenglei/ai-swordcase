extends "res://球面基础/main.gd"
const StartupTrace = preload("res://full_game/startup_trace.gd")
const Stele = preload("res://full_game/stele.gd")
const Navigation = preload("res://full_game/navigation_hints.gd")
const Run = preload("res://full_game/game_world.gd")
const MovementFrames = preload("res://full_game/movement_frames.gd")
const Interpolation = preload("res://full_game/movement_interpolation.gd")
const HitFeedback = preload("res://full_game/hit_feedback.gd")
var hit_feedback := HitFeedback.new()
var movement_interpolation = Interpolation.new()
const World = preload("res://full_game/world.gd")
const FlowerTrail = preload("res://full_game/flower_trail.gd")
var flower_trail := FlowerTrail.new()
const WideLens = preload("res://通用组件/wide_lens.gd")
var world_profile: Dictionary = Run.default_world_profile()
var WIDE_CAMERA: Dictionary = world_profile.wide_camera
const UI = preload("res://full_game/ui.gd")
const MENU_MUSIC: AudioStreamMP3 = preload("res://full_game/art/音乐/开始界面.mp3")
const GAMEPLAY_MUSIC: AudioStreamMP3 = preload("res://full_game/art/音乐/开始游戏后.mp3")
@export var render_palette: Resource = preload("res://full_game/paper_theme.tres")
var render_style = preload("res://full_game/render_style.gd").new()
var display_cache := preload("res://full_game/display_snapshot_cache.gd").new()
var run = Run.new()
var world
var hud
var menu_visible = true
var draw_clock = 0.0
var injected_save_path = ""
var simulation_enabled = true
var generating_planet := false
var _pause_after_generation := false
var previous_health = 5.0
var theater := preload("res://full_game/evolution_theater.gd").new()
var _background_music: AudioStreamPlayer


func _ready() -> void:
	var _startup_span := StartupTrace.scope("main.gd:_ready")
	if Run.C.SPECIES.is_empty():
		push_error("宠物配置无效，请检查 full_game/pets.json")
		get_tree().quit(1)
		return
	var startup_token := -1
	_resize_display()
	get_window().size_changed.connect(_resize_display)
	startup_token = StartupTrace.begin("main.load_scale")
	var error = Scale.load_file(config_path)
	StartupTrace.end(startup_token)
	if not error.is_empty():
		push_error(error)
		get_tree().quit(1)
		return
	radius_index = Scale.DEFAULT_INDEX
	radius = float(world_profile.expected_radius_m)
	Scale.CAMERA_FOCUS_HEIGHT = float(world_profile.camera.focus_height_m)
	Scale.CAMERA_FOLLOW_SPEED = float(world_profile.camera.follow_speed)
	yaw = Scale.CAMERA_YAW
	pitch = Scale.CAMERA_PITCH
	distance = Scale.CAMERA_DISTANCE
	get_window().title = "彩绘星灵 · 花卷星"
	startup_token = StartupTrace.begin("main.build_base_world")
	_build_world()
	StartupTrace.end(startup_token)
	planet_material.shader = preload("res://full_game/ground.gdshader")
	startup_token = StartupTrace.begin("main.build_player_and_movement")
	_build_player()
	MovementFrames.setup(hero.sprite, "hero", 1, float(world_profile.actors.hero_height_m))
	StartupTrace.end(startup_token)
	hit_feedback.remember_pose(hero.sprite)
	run.player_damaged.connect(_on_player_damaged)
	run.lifecycle_changed.connect(_on_lifecycle_changed)
	render_style.palette = render_palette
	startup_token = StartupTrace.begin("main.configure_render_style")
	render_style.configure(self)
	StartupTrace.end(startup_token)
	startup_token = StartupTrace.begin("main.sphere_mesh")
	var sphere = SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 192
	sphere.rings = 95
	planet.mesh = sphere
	StartupTrace.end(startup_token)
	_sync_player()
	update_camera(0, true)
	if not injected_save_path.is_empty():
		run.save_path = injected_save_path
	elif "--gm" in OS.get_cmdline_user_args():
		DirAccess.make_dir_recursive_absolute("user://tests")
		run.save_path = "user://tests/gm_session.json"
	elif "--profile-startup" in OS.get_cmdline_user_args():
		DirAccess.make_dir_recursive_absolute("user://tests")
		run.save_path = "user://tests/startup_session.json"
	# 临时关闭正式版读写档，每次启动从新局开始；保留存档实现供复测。
	# run.load_game()
	startup_token = StartupTrace.begin("main.create_world_view")
	world = World.new()
	add_child(world)
	world.setup(self, display_cache.capture.bind(run), run.collision_snapshot, run.collision_stamp)
	StartupTrace.end(startup_token)
	run.combat.ink_reaction.connect(_show_ink_reaction)
	run.combat.color_ultimate_cast.connect(_on_color_ultimate_cast)
	run.paint_system.space.actor_aim = world.paint_view.actor_bridge.aim_point
	run.spatial.attach_actor_query(world.paint_view.actor_bridge.trace)
	run.spatial.enemy_viewport = _enemy_on_screen
	world.paint_view.actor_query_detached.connect(run.spatial.detach_actor_query)
	run.attack_visible = func(point: Vector2) -> bool:
		return is_instance_valid(hud) and Navigation.visible(self, point)
	startup_token = StartupTrace.begin("main.create_hud")
	hud = UI.new()
	add_child(hud)
	add_child(theater)
	run.progression.evolved.connect(_present_evolution)
	theater.finished.connect(_finish_evolution)
	joystick = hud.joystick
	hud.read_harmonizations = run.harmonization_view
	hud.action_requested.connect(ui_action)
	StartupTrace.end(startup_token)
	paused = true
	if not run.data.is_empty():
		_restore_position()
	refresh_ui()
	startup_token = StartupTrace.begin("main.initial_world_tick")
	world.tick()
	StartupTrace.end(startup_token)
	flower_trail.setup(world, radius, render_style.ground_image())
	if "--gm" in OS.get_cmdline_user_args():
		var console := preload("res://full_game/gm_console.gd").new()
		add_child(console)
		console.setup(self)
	if "--autoplay" in OS.get_cmdline_user_args():
		_autoplay()


func _autoplay() -> void:
	# 截图/自动化用：跳过主菜单直接开局。
	await get_tree().process_frame
	await get_tree().process_frame
	ui_action("new_run", {"seed": 0})


func _enemy_on_screen(point: Vector2) -> bool:
	var center: Vector3 = world.position_on(point, 1.0)
	return world_point_visible(center) and get_viewport().get_visible_rect().has_point(
		camera.unproject_position(center))


func world_point_visible(point: Vector3) -> bool:
	if camera.is_position_behind(point):
		return false
	var offset = point - camera.global_position
	var length = offset.length()
	var direction = offset / maxf(length, 0.00001)
	var b = camera.global_position.dot(direction)
	var discriminant = b * b - camera.global_position.length_squared() + radius * radius
	if discriminant >= 0 and -b - sqrt(discriminant) < length - 0.02:
		return false
	var terrain: RefCounted = run.paint_system.space.terrain
	return terrain.ground_hit(camera.global_position, point - direction * 0.03).is_empty()


func _resize_display() -> void:
	var window = get_window()
	if window.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP:
		return
	# Preserve readable touch units on narrow windows and cap the adaptive layout width.
	var factor = maxf(1.0, float(window.size.x) / 600.0)
	var logical = Vector2i(Vector2(window.size) / factor)
	if window.content_scale_size != logical:
		window.content_scale_size = logical


func update_camera(delta: float, immediate: bool = false) -> void:
	if not is_instance_valid(camera) or not is_instance_valid(player):
		return
	# Projection shake must not feed back into follow smoothing or optical centering.
	camera.h_offset = 0.0
	camera.v_offset = 0.0
	pitch = deg_to_rad(float(WIDE_CAMERA.pitch_degrees))
	distance = float(WIDE_CAMERA.distance_m) * Scale.HERO_HEIGHT / 1.8
	var up = surface_frame.y
	var frame = surface_frame * Basis(Vector3.UP, yaw)
	var focus = player.position + up * Scale.CAMERA_FOCUS_HEIGHT
	var desired = focus + (frame.z * cos(pitch) + up * sin(pitch)) * distance
	camera.position = (
		desired
		if immediate
		else camera.position.lerp(desired, 1 - exp(-delta * Scale.CAMERA_FOLLOW_SPEED))
	)
	if camera.position.length() < radius + 0.4:
		camera.position = camera.position.normalized() * (radius + 0.4)
	camera.far = maxf(1000.0, radius * 12.0)
	camera.look_at(focus, up)
	WideLens.project(self, WIDE_CAMERA)
	WideLens.face_camera(hero.sprite, camera)


func _restore_position() -> void:
	var _startup_span := StartupTrace.scope("main.gd:_restore_position")
	hit_feedback.reset()
	hit_feedback.restore_pose(hero.sprite)
	movement_interpolation.reset()
	if is_instance_valid(world):
		for actor in world.actors.values():
			actor.remove_meta("sample_time")
			actor.remove_meta("sample_point")
	var point: Vector2 = run.data.player
	var tangent = Vector3(point.x, 0, point.y)
	surface_frame = (
		Basis.IDENTITY
		if tangent.length() < 0.001
		else Basis(Vector3.UP.cross(tangent).normalized(), tangent.length() / radius)
	)
	facing_local = Vector3(run.data.facing.x, 0, run.data.facing.y)
	_sync_player()
	update_camera(0, true)
	if is_instance_valid(world):
		var direction: Vector2 = run.data.facing
		var screen := (
			camera.unproject_position(world.position_on(point + direction * 0.1))
			- camera.unproject_position(world.position_on(point))
		)
		hero.sprite.set_meta("move_phase", 0.0)
		MovementFrames.sample(hero.sprite, screen, 0, 0)
		hit_feedback.remember_pose(hero.sprite)
		hit_feedback.apply_pose(hero.sprite)


func _desktop_movement() -> Vector2:
	if OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return Vector2.ZERO
	var input := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		input.x -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		input.x += 1
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		input.y -= 1
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		input.y += 1
	return input


func _physics_process(delta: float) -> void:
	if (theater.visible or not simulation_enabled or generating_planet
		or not is_instance_valid(world) or not is_instance_valid(hud)):
		return
	movement_interpolation.restore()
	hit_feedback.restore_pose(hero.sprite)
	var old_position: Vector3 = player.position
	var old_phase: float = hero.sprite.get_meta("move_phase", 0.0)
	if run.allows_simulation(paused or menu_visible):
		var input: Vector2 = (_desktop_movement() + joystick.direction).limit_length()
		var previous_planet: int = run.data.planet
		run.advance(delta, false, _engine_motion.bind(input))
		if int(run.data.planet) != previous_planet:
			# Lifecycle already repositioned the player and camera. Do not join the two planets' trails.
			refresh_ui(false)
			return
		if _engine_planar().distance_to(run.characters.player_position()) > 0.00001:
			var accepted := run.small_world_normal(run.characters.player_position())
			surface_frame = (Basis(Quaternion(surface_frame.y, accepted)) * surface_frame).orthonormalized()
			_sync_player()
		flower_trail.grow(delta)
		if input.length_squared() > 0.0:
			flower_trail.walk(old_position, player.position)
		if float(run.data.health) < previous_health and run.settings.vibration:
			Input.vibrate_handheld(45)
		previous_health = float(run.data.health)
		if run.data.phase == "summary":
			set_paused(true)
	else:
		run.advance(delta, paused or menu_visible)
	# run.autosave(minf(delta, 0.1))
	update_camera(delta)
	var actual_distance := player.position.distance_to(old_position)
	var screen_motion := (
		camera.unproject_position(player.position) - camera.unproject_position(old_position)
	)
	hero.sprite.set_meta("move_phase", old_phase)
	if run.allows_simulation(paused or menu_visible):
		var brush := World.PetAttackMotion.current(run.data.effects, -1)
		MovementFrames.sample(hero.sprite, screen_motion, actual_distance, delta, brush)
	hit_feedback.remember_pose(hero.sprite)
	hit_feedback.apply_pose(hero.sprite)
	# Paused, menu and decision steps reuse the detached records; simulation steps and commands
	# bump revisions, and the restoration clock runs without one. _process aligns overlays.
	world.tick_actors(display_cache.stale(run) or run.data.get("phase", "") == "restoring", false)
	var moving_nodes: Array = [player, camera]
	moving_nodes.append_array(world.actors.values())
	movement_interpolation.capture(moving_nodes)
	for light in get_children():
		if light is DirectionalLight3D:
			light.basis = (
				surface_frame * Basis.from_euler(Vector3(deg_to_rad(-35), deg_to_rad(-38), 0))
			)
	draw_clock += delta
	if draw_clock >= 0.08:
		draw_clock = 0
		# Actor sync already captured this simulation step's detached presentation records.
		world.tick(false, false)
		refresh_ui(false)
	if not run.data.is_empty():
		hero.sprite.modulate = (
			Color(1, 0.55, 0.55)
			if run.data.invulnerable > 0 and not run.settings.reduce_flash
			else Color.WHITE
		)


func _sync_player() -> void:
	super._sync_player()
	if not run.data.is_empty():
		player.position = run.paint_system.space.terrain.lift_point(player.position)


func _show_ink_reaction(title: String, color: int, point: Vector3) -> void:
	var label := Label3D.new()
	label.text = title
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = Material.RENDER_PRIORITY_MAX
	label.outline_render_priority = Material.RENDER_PRIORITY_MAX - 1
	label.font = preload("res://full_game/ink_reaction_font.tres")
	label.font_size = 72
	label.outline_size = 14
	label.pixel_size = 0.012
	label.modulate = Run.C.COLORS[color].lightened(0.18)
	label.outline_modulate = Color("352137")
	world.add_child(label)
	label.position = point + point.normalized() * 0.55
	var travel: Vector3 = camera.global_basis.x * 0.40 + camera.global_basis.y * 0.75
	var tween := label.create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "position", label.position + travel, 0.85)
	tween.tween_property(label, "pixel_size", 0.016, 0.12)
	tween.tween_property(label, "pixel_size", 0.012, 0.18).from(0.016).set_delay(0.12)
	tween.tween_property(label, "modulate:a", 0.0, 0.25).set_delay(0.65)
	tween.tween_property(label, "outline_modulate:a", 0.0, 0.25).set_delay(0.65)
	tween.chain().tween_callback(label.queue_free)


func _on_color_ultimate_cast(payload: Dictionary) -> void:
	world.play_color_ultimate(payload, float(run.data.elapsed))


func _present_evolution(species: String, offer: Dictionary) -> void:
	var point := run.source_position(run.find_slot(int(offer.id)))
	var screen := camera.unproject_position(world.position_on(point, 0.8))
	joystick.release()
	hud.hide()
	hud.process_mode = Node.PROCESS_MODE_DISABLED
	theater.present(species, offer, screen, bool(run.settings.reduce_flash))


func _finish_evolution() -> void:
	hud.process_mode = Node.PROCESS_MODE_INHERIT
	hud.show()
	refresh_ui()


func _on_player_damaged() -> void:
	hit_feedback.trigger(hero.sprite)


func _on_lifecycle_changed(_reason: String) -> void:
	hit_feedback.reset()
	movement_interpolation.reset()
	if is_instance_valid(joystick):
		joystick.release()
	if not run.data.is_empty():
		previous_health = float(run.data.health)
		_restore_position()
	flower_trail.reset()
	if is_instance_valid(world):
		world.reset_color_ultimates()
		if not generating_planet:
			world.tick()
	draw_clock = 0.0


func _process(delta: float) -> void:
	if (theater.visible or not simulation_enabled or generating_planet
		or not is_instance_valid(world) or not is_instance_valid(hud)):
		return
	if not run.allows_simulation(paused or menu_visible):
		movement_interpolation.restore()
	else:
		movement_interpolation.render(Engine.get_physics_interpolation_fraction())
	_update_hit_feedback(delta)
	# Interpolated roots must still carry screen-parallel art between fixed ticks.
	hero.sprite.global_basis = camera.global_basis
	world.align_actors()
	if not run.data.is_empty() and not menu_visible:
		hud.hero_hearts.follow(hero.sprite, camera, ceili(run.data.health), hud.playfield_rect().position.y)
		_update_guidance(hud.snapshot)
		hud.refresh_guidance()


func _update_hit_feedback(delta: float) -> void:
	var active: bool = run.allows_simulation(paused or menu_visible)
	if run.data.get("phase", "") == "summary" or menu_visible:
		hit_feedback.reset()
	if active:
		hit_feedback.advance(delta)
	hit_feedback.apply_pose(hero.sprite)
	var offset := hit_feedback.camera_offset() if active else Vector2.ZERO
	camera.h_offset = offset.x
	camera.v_offset = offset.y


func refresh_ui(refresh_world: bool = true) -> void:
	var _startup_span := StartupTrace.scope("main.gd:refresh_ui")
	if not is_instance_valid(hud):
		return
	_sync_background_music()
	var snapshot = run.snapshot(false)
	snapshot.paused = paused
	snapshot.edge_warnings = []
	if not run.data.is_empty() and not menu_visible:
		if refresh_world:
			world.read_model.capture()
		_update_guidance(snapshot)
	if menu_visible:
		snapshot.phase = "menu"
		snapshot.panel = ""
	hud.refresh(snapshot)


func _sync_background_music() -> void:
	if AudioServer.get_driver_name() == "Dummy":
		return
	if _background_music == null:
		_background_music = AudioStreamPlayer.new()
		_background_music.name = "BackgroundMusic"
		add_child(_background_music)
	var track := MENU_MUSIC if menu_visible else GAMEPLAY_MUSIC
	if _background_music.stream == track:
		return
	_background_music.stream = track
	_background_music.play()


func _update_guidance(snapshot: Dictionary) -> void:
	var view: RefCounted = world.read_model
	var goal := Navigation.objective(view)
	snapshot.guidance = goal
	snapshot.edge_warnings = Navigation.collect(self, goal)
	snapshot.erase("hold_anchor")
	var crown: Vector3
	if snapshot.portal.get("nearby", false) and is_instance_valid(world.planet_portal):
		crown = world.planet_portal.label.global_position
	elif snapshot.node_activation.get("nearby", false):
		crown = world.position_on(snapshot.node.pos, Stele.HEIGHT)
	if crown != Vector3.ZERO and not camera.is_position_behind(crown):
		snapshot.hold_anchor = camera.unproject_position(crown)
	snapshot.erase("node_pin")
	if goal.is_empty():
		return
	goal.distance = Vector2(view.data.player).distance_to(goal.pos)
	if view.data.phase == "explore" and snapshot.edge_warnings.is_empty():
		snapshot.node_pin = camera.unproject_position(world.position_on(goal.pos, 1.0))


func set_paused(value: bool) -> void:
	paused = value
	if paused and is_instance_valid(camera):
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	if is_instance_valid(joystick):
		joystick.release()
		joystick.input_enabled = not paused and not menu_visible
	drag_touch = -1
	drag_mouse = false
	refresh_ui()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(hud):
		if generating_planet:
			_pause_after_generation = true
			return
		set_paused(true)
		# run.save_game()


func _unhandled_input(_event: InputEvent) -> void:
	# The fixed camera and pet-owned colours have no manual colour hotkeys.
	pass


func _refresh_stats() -> void:
	pass


func ui_action(action: String, payload: Dictionary = {}) -> void:
	if theater.visible or generating_planet:
		return
	if action == "hero_ink":
		if not paused and not menu_visible and not hud.modal_open:
			run.select_hero_color(int(payload.get("color", -1)))
			refresh_ui(false)
		return
	movement_interpolation.reset()
	match action:
		"begin_encounter":
			hud.show_starter_encounter(run.begin_starter_encounter(int(payload.get("seed", 0))))
		"cancel_encounter":
			run.cancel_starter_encounter()
			hud.reset_session()
			menu_visible = true
			set_paused(true)
		"confirm_starter":
			_start_selected_partner(str(payload.get("species", "")))
			return
		"new_run":
			run.new_run(int(payload.get("seed", 0)))
			_enter_new_run()
		"continue":
			if run.data.is_empty() or run.data.phase == "summary":
				return
			menu_visible = false
			_restore_position()
			set_paused(false)
		"pause":
			set_paused(bool(payload.get("value", true)))
		"color":
			if not run.data.is_empty():
				run.select_color(int(payload.get("index", 0)))
		"select_starling":
			run.select_starling(int(payload.get("id", -1)))
		"select_hero_attack":
			run.select_hero_attack(str(payload.get("species", "")))
		"active":
			pass
		"activate_node":
			if not paused and not menu_visible:
				run.activate_node(int(payload.get("id", -1)))
		"evolve":
			run.evolve(int(payload.get("keep_id", -1)), -1, int(payload.get("expected_stage", -1)))
		"harmonize":
			run.harmonize(int(payload.get("first_id", -1)), int(payload.get("second_id", -1)))
		"reorder":
			run.reorder(int(payload.get("id", -1)), int(payload.get("direction", 0)))
		"reward":
			run.reward(str(payload.get("mode", "")), int(payload.get("target_id", -1)),
				int(payload.get("expected_id", -1)))
		"upgrade":
			run.upgrade(int(payload.get("index", 0)), int(payload.get("decision_id", -1)))
		"skip_upgrade":
			run.skip_upgrade(int(payload.get("decision_id", -1)))
		"choose_reward":
			run.choose_reward(int(payload.get("index", -1)), int(payload.get("decision_id", -1)))
		"track_node":
			run.track_node(int(payload.get("id", -1)))
		"starter":
			run.choose_starter(int(payload.get("index", 0)))
		"track_portal":
			run.track_node(-1)
		"abandon":
			run.finish("主动结束")
		"settings":
			var key = str(payload.get("key", ""))
			run.change_setting(key, bool(payload.get("value", false)))
		"menu":
			menu_visible = true
			set_paused(true)
	# if run.dirty:
	# 	run.save_game()
	world.tick()
	refresh_ui(false)


func _start_selected_partner(species: String) -> void:
	if species not in run.starter_candidates:
		return
	generating_planet = true
	_pause_after_generation = false
	hud.show_planet_loading()
	# Confirmation can arrive immediately before process_frame. Present the overlay first.
	if not await _entry_frame() or not await _entry_frame():
		return
	var token := StartupTrace.begin("entry.start_with_candidate")
	var started: bool = run.start_with_candidate(species)
	StartupTrace.end(token)
	if not started:
		generating_planet = false
		hud.show_starter_encounter(run.starter_candidates)
		return
	world.read_model.capture()
	var tasks: Dictionary = world.prepare_static_build()
	tasks[&"actors"] = world.tick.bind(false)
	for stage in tasks:
		hud.update_planet_loading(stage)
		if not await _entry_frame():
			return
		var task: Callable = tasks[stage]
		token = StartupTrace.begin("entry." + task.get_method())
		task.call()
		StartupTrace.end(token)
	hud.update_planet_loading(&"ready")
	if not await _entry_frame():
		return
	generating_planet = false
	_enter_new_run(_pause_after_generation)
	hud.show_starter_guide(species)


func _entry_frame() -> bool:
	await get_tree().process_frame
	if (is_inside_tree() and not is_queued_for_deletion()
		and is_instance_valid(world) and world.is_inside_tree() and not world.is_queued_for_deletion()
		and is_instance_valid(hud) and hud.is_inside_tree() and not hud.is_queued_for_deletion()):
		return true
	generating_planet = false
	return false


func _enter_new_run(start_paused := false) -> void:
	menu_visible = false
	hud.reset_session()
	_restore_position()
	set_paused(start_paused)


func _engine_motion(delta: float, multiplier: float, input: Vector2) -> Vector2:
	# Engine adapter proposes a spherical step; GameWorld validates and owns the accepted position.
	step_motion(input, delta * float(world_profile.speed_mps) / Scale.MOVE_SPEED * multiplier, false)
	if input.length_squared() > 0.0:
		hud.dismiss_starter_guide()
	return _engine_planar()


func _engine_planar() -> Vector2:
	var up := surface_frame.y
	return Vector2(up.x, up.z).normalized() * acos(clampf(up.y, -1, 1)) * radius


func _exit_tree() -> void:
	if is_instance_valid(_background_music):
		_background_music.stop()
		_background_music.stream = null
	run.spatial.detach_view()
