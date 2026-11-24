extends Node3D
const StartupTrace = preload("res://full_game/startup_trace.gd")
const Restoration = preload("res://full_game/node_restoration.gd")
const Navigation = preload("res://full_game/navigation_hints.gd")
const Activation = preload("res://full_game/node_activation.gd")
const ActivationRing = preload("res://full_game/stele_activation_ring.gd")
const PlanetPortalView = preload("res://full_game/planet_portal_view.gd")
const PlanetScene = preload("res://full_game/planet_scene.gd")
const EnemyVisual = preload("res://full_game/enemy_visual.gd")
const Deaths = preload("res://full_game/death_system.gd")
const Attacks = preload("res://full_game/enemy_attacks.gd")
const C = preload("res://full_game/catalog.gd")
const Ultimates = preload("res://full_game/color_ultimate_rules.gd")
const SpringDecor = preload("res://full_game/spring_decor.gd")
const Landforms = preload("res://full_game/planet_landforms.gd")
const MovementFrames = preload("res://full_game/movement_frames.gd")
const PetView = preload("res://full_game/pet_view.gd")
const PetAttackMotion = preload("res://full_game/pet_attack_motion.gd")
var pet_view: RefCounted
const Actor = preload("res://通用组件/billboard_actor.gd")
const Style = preload("res://full_game/render_style.gd")
const District = preload("res://full_game/paper_district.gd")
const PaintSurface = preload("res://full_game/paint_surface.gd")
var style = Style.new()
var district
var paint_pages := preload("res://full_game/ground_paint_pages.gd").new()
var paint_surface = PaintSurface.new()
var paint_view := preload("res://full_game/paint_view.gd").new()
var brush_fx = preload("res://full_game/brush_fx.gd").new()
var enemy_fx = preload("res://full_game/enemy_fx.gd").new()
var color_ultimate_fx := preload("res://full_game/color_ultimate_fx.gd").new()
var yellow_field_start := -1.0
var fragment_display := preload("res://full_game/fragment_display.gd").new()
var game
const ReadModel = preload("res://full_game/presentation_read_model.gd")
const Protection = preload("res://full_game/paint_protection.gd")
var read_model: ReadModel
var actors: Dictionary = {}
var model_range := preload("res://full_game/model_view_range.gd").new()
var environment_root: Node3D
var static_root: Node3D
var ground_mesh: MeshInstance3D
var restored_mesh: MeshInstance3D
var static_generation := -1
var static_revision := 0
var displayed_ecology := 0
var displayed_step := -1
var extra_flowers: Node3D
var decor_sprites: Array[Sprite3D] = []
var last_paint_settings := -1
var core: Node3D
var core_label: Label3D
var partner: Node3D
var font: FontVariation
var actor_ids: Dictionary = {}
var actor_generation := -1
var node_labels: Array[Label3D] = []
var planet_portal: PlanetPortalView


func setup(owner_game, snapshot: Callable, collision: Callable, stamp: Callable) -> void:
	var _startup_span := StartupTrace.scope("world.gd:setup")
	game = owner_game
	read_model = ReadModel.new(snapshot, collision, stamp)
	pet_view = PetView.new(owner_game.camera, position_on)
	if owner_game.get("render_palette") != null:
		style.palette = owner_game.render_palette
	district = District.new(style)
	environment_root = Node3D.new()
	add_child(environment_root)
	if owner_game.get("planet_material") != null:
		style.register_environment(owner_game.planet_material)
	font = preload("res://球面基础/fonts/game_body.tres")
	static_root = Node3D.new()
	add_child(static_root)
	ground_mesh = MeshInstance3D.new()
	ground_mesh.material_override = paint_surface.material
	style.register_environment(paint_surface.material)
	ground_mesh.hide()
	add_child(ground_mesh)
	refreshed_mesh()
	add_child(fragment_display)
	fragment_display.setup(font)
	brush_fx.setup(self)
	add_child(color_ultimate_fx)
	color_ultimate_fx.setup(self)
	add_child(paint_view)
	paint_view.setup(self)


func refreshed_mesh() -> void:
	restored_mesh = MeshInstance3D.new()
	var restored_material = style.environment(Color.WHITE, false).duplicate()
	restored_material.shader = preload("res://full_game/surface_overlay.gdshader")
	style.register_environment(restored_material)
	restored_material.set_shader_parameter("use_vertex_color", true)
	restored_mesh.material_override = restored_material
	restored_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(restored_mesh)


func material(color: Color, vertex: bool = false) -> Material:
	if not vertex:
		return style.surface(color)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = vertex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return mat


func normal(point: Vector2) -> Vector3:
	var tangent = Vector3(point.x, 0, point.y)
	if tangent.length() < 0.0001:
		return Vector3.UP
	return (
		Basis(Vector3.UP.cross(tangent).normalized(), tangent.length() / game.radius) * Vector3.UP
	)


func position_on(point: Vector2, height: float = 0.0) -> Vector3:
	return read_model.surfaces.terrain.position(point, height)


func frame(point: Vector2, face_camera: bool = false) -> Basis:
	var up = normal(point)
	var z = Vector3.BACK - up * Vector3.BACK.dot(up)
	if face_camera:
		var toward = game.camera.position - position_on(point)
		z = toward - up * toward.dot(up)
	if z.length_squared() < 0.0001:
		z = Vector3.RIGHT
	z = z.normalized()
	return Basis(up.cross(z).normalized(), up, z)


func place(node: Node3D, point: Vector2, height: float = 0.0, face_camera: bool = false) -> void:
	node.transform = Transform3D(frame(point, face_camera), position_on(point, height))


func tick(refresh: bool = true, sync_actors: bool = true) -> void:
	var _startup_span := StartupTrace.scope("world.gd:tick")
	if refresh:
		read_model.capture()
	game.render_style.sync_ground_quality(game.planet_material, bool(read_model.settings.get("low_fx", false)))
	if not sync_actors or read_model.data.is_empty():
		_sync_planet_portal()
	if read_model.data.is_empty():
		return
	var d: Dictionary = read_model.data
	model_range.capture(game.camera, game.radius)
	if static_generation != read_model.surfaces.generation:
		_build_static()
	if extra_flowers != null:
		extra_flowers.visible = not read_model.settings.low_fx
	if displayed_step != int(d.step):
		displayed_step = int(d.step)
		for label in node_labels:
			var id := int(label.get_meta("navigation_id"))
			var cleared: bool = d.restored.any(func(region: Dictionary) -> bool:
				return int(region.get("id", -1)) == id)
			label.text = str(label.get_meta("title")) + (" · 已完成" if cleared else "")
	_sync_ecology(d.ecology)
	var meadow := static_root.get_node_or_null("SpringDecor")
	if meadow != null and meadow.get_meta("plant_builder").refresh_plants(meadow):
		static_revision += 1
	for sprite in decor_sprites:
		sprite.visible = model_range.contains(sprite.position, 3.0)
	sync_environment_restoration()
	_sync_ground()
	if sync_actors:
		tick_actors(false)
	brush_fx.update(self, d.effects, read_model.settings)
	enemy_fx.update(self)
	fragment_display.sync(self)


func play_color_ultimate(payload: Dictionary, elapsed: float) -> void:
	# The persistent yellow field is drawn from snapshots, including a mid-cast resume.
	if str(payload.id) != Ultimates.IDS[1]:
		color_ultimate_fx.play(payload, elapsed)


func reset_color_ultimates() -> void:
	color_ultimate_fx.reset()
	yellow_field_start = -1.0


func _tick_color_ultimates() -> void:
	var d := read_model.data
	var elapsed := float(d.elapsed)
	color_ultimate_fx.set_quality(read_model.settings.low_fx, read_model.settings.reduce_flash)
	var field: Dictionary = d.get("color_ultimate_field", {})
	if field.is_empty() or int(field.planet) != int(d.planet) or d.phase == "summary":
		if yellow_field_start >= 0.0:
			color_ultimate_fx.clear_yellow()
			yellow_field_start = -1.0
	elif yellow_field_start != float(field.started):
		yellow_field_start = float(field.started)
		var center: Vector2 = field.center
		var points: Array[Vector2] = [center]
		color_ultimate_fx.play({
			"id": Ultimates.IDS[1], "color": 1, "source": field.source,
			"origin": center, "center": center, "direction": Vector2.ZERO,
			"points": points, "radius": Ultimates.YELLOW_RADIUS,
			"duration": Ultimates.YELLOW_DURATION, "round": field.round
		}, elapsed - (Ultimates.YELLOW_DURATION - float(field.remaining)))
	color_ultimate_fx.tick(elapsed)


func sync_environment_restoration() -> void:
	var state: Dictionary = read_model.data
	style.sync_restoration(Restoration.regions(state), game.radius, Restoration.planet_reveal(state, game.radius))


## The scene's physics step passes overlays=false: its _process re-aligns labels and
## pickups before every draw. Bodies are always aligned, because paint contacts read them.
func tick_actors(refresh: bool = true, overlays: bool = true) -> void:
	var _startup_span := StartupTrace.scope("world.gd:tick_actors")
	if refresh:
		read_model.capture()
	_sync_planet_portal()
	if read_model.data.is_empty():
		return
	sync_environment_restoration()
	_tick_color_ultimates()
	_sync_activation_rings()
	if actor_generation != read_model.surfaces.generation:
		actor_generation = read_model.surfaces.generation
		for actor in actors.values():
			actor.hide()
			actor.queue_free()
		actors.clear()
		actor_ids.clear()
	model_range.capture(game.camera, game.radius)
	_sync_actors()
	align_actors(overlays)
	paint_view.actor_bridge.cached_clock = -1.0
	paint_view.update()


func _sync_planet_portal() -> void:
	var portal := read_model.portal
	var phase: String = read_model.data.get("phase", "menu")
	if portal.is_empty() or phase in ["menu", "summary"]:
		if planet_portal != null:
			planet_portal.hide()
			planet_portal.label.hide()
		return
	if planet_portal == null:
		planet_portal = PlanetPortalView.new()
		planet_portal.setup(style, font)
		add_child(planet_portal)
	planet_portal.sync(portal, read_model.surfaces.generation, read_model.settings, position_on, place)
	planet_portal.show()


func align_actors(overlays: bool = true) -> void:
	if overlays:
		fragment_display.align(self)
		_align_planet_portal_label()
	var target := Navigation.target_node(read_model)
	for label in node_labels:
		var tracked: bool = int(label.get_meta("navigation_id")) == int(target.get("id", -1))
		label.visible = (
			tracked and not target.get("cleared", true) and read_model.data.get("phase", "") == "explore"
			and Navigation.visible(game, label.get_meta("navigation_point"))
		)
		if label.visible:
			_align_name(label)
	for actor in actors.values():
		if actor.visible:
			_align_actor(actor, overlays)


func _align_planet_portal_label() -> void:
	if planet_portal == null or not planet_portal.visible:
		return
	var portal := read_model.portal
	var label := planet_portal.label
	label.visible = (
		not portal.is_empty()
		and Navigation.objective(read_model).get("kind") == "portal"
		and Navigation.visible(game, portal.pos)
	)
	if label.visible:
		_align_name(label)


func stele_name_top(id: int) -> Vector3:
	for label in node_labels:
		if int(label.get_meta("navigation_id")) == id:
			var half_line := label.font.get_height(label.font_size) * 0.5
			var height := half_line * label.pixel_size * label.global_basis.get_scale().y
			return label.global_position + game.camera.global_basis.y * height
	return Vector3.INF


func _sync_activation_rings() -> void:
	if node_labels.is_empty():
		return
	var state: Dictionary = read_model.data
	var phase: String = state.get("phase", "menu")
	var current: Dictionary = state.get("node", {})
	var current_id: int = int(current.get("id", -1))
	var records: Dictionary = {}
	for node in state.get("map_nodes", []):
		records[int(node.id)] = node
	for label in node_labels:
		var id: int = int(label.get_meta("navigation_id"))
		var record: Dictionary = current if id == current_id else records.get(id, {})
		var opened: bool = record.get("cleared", false) or not record.get("locked", {}).is_empty()
		var available: bool = Activation.available(record, int(state.get("planet_clears", 0)))
		var progress: float = Activation.progress(record)
		var weight: float = 0.45 if opened else (1.0 if available and id == current_id else 0.38)
		var ring: ActivationRing = label.get_meta("activation_ring")
		ring.visible = not record.is_empty() and phase not in ["menu", "summary"]
		ring.set_progress(progress, weight)


func _align_actor(actor: Node3D, overlays: bool = true) -> void:
	if actor.has_meta("sprite"):
		var sprite: Sprite3D = actor.get_meta("sprite")
		# Screen-parallel artwork on the curved surface; facing selects art.
		var artwork_scale: Vector3 = (
			actor.scale * actor.dye_scale if actor is EnemyVisual else Vector3.ONE
		)
		sprite.global_basis = game.camera.global_basis.scaled(artwork_scale)
		if overlays and actor.get_meta("boss", false):
			actor.label.global_position = sprite.to_global(Vector3.UP * (actor.bar_height + 0.54))
		if actor.has_meta("attack_pose"):
			sprite.position = actor.get_meta("rest_position", Vector3.ZERO)
			PetAttackMotion.apply(
				sprite,
				game.camera,
				actor.get_meta("attack_pose"),
				Vector3.ONE,
				sprite.global_position,
				float(actor.get_meta("body_height")),
				actor.get_meta("attack_screen_direction"),
				actor.get_meta("attack_screen_lateral")
			)
	if not overlays:
		return
	for label in actor.get_children():
		if label is Label3D:
			# Cheap ownership rules first: most labels stay hidden without casting a terrain ray.
			label.visible = _label_shown(actor) and game.world_point_visible(label.global_position)
			if label.visible:
				_align_name(label)


func _label_shown(actor: Node3D) -> bool:
	if not actor is EnemyVisual:
		return true
	if actor.action == "death" or actor.get_meta("entering", false):
		return false
	return actor.get_meta("guard", false) or (
		actor.get_meta("boss", false) and read_model.data.phase == "battle"
		and Navigation.boss_guided(read_model)
		and Navigation.visible(game, actor.get_meta("navigation_point", Vector2.ZERO)))


func _build_static() -> void:
	var _startup_span := StartupTrace.scope("world.gd:_build_static")
	for task in prepare_static_build().values():
		task.call()


func prepare_static_build() -> Dictionary[StringName, Callable]:
	static_generation = read_model.surfaces.generation
	static_revision += 1
	displayed_ecology = 0
	displayed_step = -1
	extra_flowers = null
	decor_sprites.clear()
	node_labels.clear()
	for child in static_root.get_children():
		static_root.remove_child(child)
		child.queue_free()
	# static_root 被整体清空，district 里的旧分组指针必须一起丢掉，否则下一次 populate 会
	# 认为节点还在而跳过重建，石碑与樱树就会挂到已经释放的父节点上。
	district.districts.clear()
	core = null
	core_label = null
	if read_model.data.node.is_empty():
		return {}
	extra_flowers = Node3D.new()
	static_root.add_child(extra_flowers)
	return {&"terrain": _build_terrain, &"landmarks": _build_landmarks, &"decor": _build_spring_decor}


func _build_terrain() -> void:
	game.planet.mesh = read_model.surfaces.terrain.ground_mesh()
	game.planet_material.set_shader_parameter("meadow_season", _meadow_season())


func _meadow_season() -> int:
	return PlanetScene.season_for_theme(str(read_model.data.get("planet_season", "")))


func _build_landmarks() -> void:
	var pos: Vector2 = read_model.data.node.pos
	paint_view.update()
	# 彩碑和固定樱树由碰撞表面统一绘制。
	district.populate(self, static_root, pos, false)
	for template in district.templates(self):
		if template.type == "boss" and not Activation.boss_revealed(read_model.data):
			continue
		core = Node3D.new()
		static_root.add_child(core)
		place(core, template.pos)
		var label = Label3D.new()
		label.font = font
		label.font_size = 28
		label.pixel_size = 0.012
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position.y = 6.9
		label.outline_size = 10
		label.modulate = Color("fff4d7")
		label.outline_modulate = Color("240e16")
		label.text = Navigation.display_title(template)
		label.set_meta("title", label.text)
		core.add_child(label)
		var ring := ActivationRing.new()
		ring.setup(position_on, template.pos, Activation.RANGE)
		static_root.add_child(ring)
		label.set_meta("activation_ring", ring)
		_align_name(label)
		label.set_meta("navigation_point", Vector2(template.pos))
		label.set_meta("navigation_id", int(template.id))
		node_labels.append(label)
	core_label = Label3D.new()
	core_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	core_label.font = font
	core_label.font_size = 32
	core_label.pixel_size = 0.014
	core_label.outline_size = 10
	core_label.modulate = Color("fff4d7")
	core_label.visible = false
	static_root.add_child(core_label)
	_build_landscape()


func _sync_ecology(records: Array) -> void:
	# Remains append on settlement. A planet change or load resets the view cursor.
	for index in range(displayed_ecology, records.size()):
		var eco: Dictionary = records[index]
		var sprite = eco_sprite(int(eco.color))
		decor_sprites.append(sprite)
		static_root.add_child(sprite)
		_place_ecology(sprite, eco)
		sprite.add_to_group("full_decoration")
		sprite.set_meta("paint_actor_id", -3000000000 - int(eco.id))
	displayed_ecology = records.size()


func _build_landscape() -> void:
	var restored = ImmediateMesh.new()
	restored.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for region in district.templates(self):
		# Preset creek and vegetation recover independently from corpse colours.
		for segment in 16:
			var a = (
				Vector2(float(segment) - 8.0, sin(float(segment) * 0.55) * 1.2 + 3.0)
				+ Vector2(region.pos)
			)
			var b = (
				Vector2(float(segment + 1) - 8.0, sin(float(segment + 1) * 0.55) * 1.2 + 3.0)
				+ Vector2(region.pos)
			)
			for p in [
				a + Vector2(0, -0.4),
				a + Vector2(0, 0.4),
				b + Vector2(0, 0.4),
				a + Vector2(0, -0.4),
				b + Vector2(0, 0.4),
				b + Vector2(0, -0.4)
			]:
				restored.surface_set_color(style.palette.primary.lightened(0.25))
				restored.surface_set_normal(normal(p))
				restored.surface_add_vertex(position_on(p, 0.04))
		for i in 3:
			var p: Vector2 = (
				region.pos + Vector2.from_angle(float(i) * 2.399) * sqrt(float(i) + 1) * 2.2
			)
			var flower = eco_sprite(i % 6)
			decor_sprites.append(flower)
			var parent := extra_flowers if i == 2 else static_root
			parent.add_child(flower)
			place(flower, p, 0.02, true)
			flower.scale *= 0.65
			flower.add_to_group("full_decoration")
			flower.material_override.set_shader_parameter("environment_surface", true)
			style.register_environment(flower.material_override, flower)
	restored.surface_end()
	restored_mesh.mesh = restored


func _build_spring_decor() -> void:
	var decor := SpringDecor.build(self, _meadow_season())
	if decor != null:
		static_root.add_child(decor)
		var plants := decor.get_node("SpringDecorMesh") as MeshInstance3D
		var landforms := Landforms.new()
		static_root.add_child(landforms)
		landforms.build(self, plants.material_override)


func eco_sprite(color: int) -> Sprite3D:
	var sprite = Sprite3D.new()
	var names = ["red", "yellow", "blue", "orange", "green", "purple"]
	var path = "res://full_game/art/eco_" + names[color] + ".png"
	if ResourceLoader.exists(path):
		sprite.texture = load(path)
	else:
		var image = Image.create(64, 64, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		for x in 64:
			for y in 64:
				if Vector2(x - 32, y - 32).length() < 22:
					image.set_pixel(x, y, C.COLORS[color])
		sprite.texture = ImageTexture.create_from_image(image)
	sprite.pixel_size = 1.5 / float(sprite.texture.get_width())
	sprite.offset.y = float(sprite.texture.get_height()) * (116.0 / 256.0)
	sprite.shaded = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.no_depth_test = false
	style.sticker(sprite)
	sprite.material_override.set_shader_parameter("keep_art_colors", true)
	sprite.material_override.set_shader_parameter("sticker_width", 0.0)
	sprite.rotation.x = 0.0
	return sprite


func _place_ecology(sprite: Sprite3D, record: Dictionary) -> void:
	place(sprite, record.pos, 0.04)
	sprite.scale *= 1.6 if record.boss else 1.0


func is_restored(point: Vector2) -> bool:
	return Protection.restored({"restored": Restoration.regions(read_model.data)}, point, game.radius)


func _sync_ground() -> void:
	var settings: Dictionary = read_model.settings
	var flags := int(settings.color_assist) + int(settings.reduce_flash) * 2
	if read_model.rebuild_ground or not read_model.changed_cells.is_empty() or flags != last_paint_settings:
		last_paint_settings = flags
		_build_ground()
	game.planet_material.set_shader_parameter("paint_clock", float(read_model.data.elapsed))
	game.planet_material.set_shader_parameter("battle_rim", Restoration.battle_rim(read_model.data, game.radius))
	paint_view.decor_dye.update(self)


func _build_ground() -> void:
	var _startup_span := StartupTrace.scope("world.gd:_build_ground")
	paint_pages.update(read_model, game.planet_material, self)
	game.planet_material.set_shader_parameter("paint_assist", read_model.settings.color_assist)
	game.planet_material.set_shader_parameter("reduce_paint_flash", read_model.settings.reduce_flash)


func _make_actor(species: String, stage: int, enemy: bool = false) -> Node3D:
	var root = Node3D.new()
	var sprite: Sprite3D
	if not enemy:
		sprite = Sprite3D.new()
		MovementFrames.setup(sprite, species, stage, 1.5 * (1.0 + 0.12 * float(stage - 1)))
		root.add_child(sprite)
		if sprite.has_meta("missing_pet_resource"):
			root.set_meta("sprite", sprite)
			root.add_child(MovementFrames.missing_label(C.SPECIES[species].name))
			return root
	else:
		var actor = Actor.new()
		actor.setup(species)
		root.add_child(actor)
		sprite = actor.sprite
	if enemy:
		sprite.pixel_size = (
			float(game.world_profile.actors.enemy_height_m) / 224.0
			if game.get("world_profile") != null
			else 1.6 / 224.0
		)
	sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	root.set_meta("sprite", sprite)
	style.sticker(sprite, enemy)
	style.actor_foreground(sprite, game.radius, enemy)
	sprite.rotation.x = 0.0
	if enemy:
		var mat = sprite.material_override
		mat.set_shader_parameter("bands", body_texture([]))
		sprite.material_override = mat
	else:
		_setup_pet_display(root, sprite, stage)
	return root


func _setup_pet_display(root: Node3D, sprite: Sprite3D, stage: int) -> void:
	root.set_meta("rest_position", sprite.position)
	var height := 1.5 * (1.0 + 0.12 * float(stage - 1))
	if sprite.has_meta("art_clip"):
		height = float(sprite.get_meta("art_clip").world_height)
	root.set_meta("body_height", height * MovementFrames.PET_SCALE)


## Passing the actor's previous band texture refreshes it in place instead of allocating a new one.
func body_texture(bands: Array, reuse: ImageTexture = null) -> ImageTexture:
	return EnemyVisual.body_texture(bands, reuse)


func _sync_enemy_pose(actor: EnemyVisual, enemy: Dictionary) -> void:
	actor.set_meta("navigation_point", Vector2(enemy.pos))
	place(actor, enemy.pos, EnemyVisual.Director.Entry.lift(enemy), true)
	var facing: Vector2 = enemy.get("facing", Vector2.UP)
	var screen_direction: Vector2 = (
		game.camera.unproject_position(position_on(enemy.pos + facing * 0.1))
		- game.camera.unproject_position(position_on(enemy.pos))
	)
	actor.scale = Vector3.ONE * (1.65 if enemy.boss else (1.2 if enemy.elite else 1.0))
	actor.scale *= EnemyVisual.Director.Entry.stretch(enemy).max(Vector3.ONE * 0.001)
	actor.visible = not actor.get_meta("culled", false) and EnemyVisual.Director.Entry.revealed(enemy)
	actor.set_meta("entering", EnemyVisual.Director.Entry.emerging(enemy))
	actor.set_meta("boss", bool(enemy.boss))
	actor.set_meta("guard", enemy.get("encounter", false) and not enemy.boss)
	if float(actor.get_meta("paint_hp", -1)) != float(enemy.hp):
		var previous: ImageTexture = actor.get_meta("bands") if actor.has_meta("bands") else null
		actor.set_meta("bands", body_texture(enemy.get("bands", []), previous))
		actor.set_meta("paint_hp", enemy.hp)
	actor.update_state(
		enemy,
		actor.get_meta("bands"),
		read_model.data.elapsed,
		screen_direction,
		read_model.data.hazards,
		read_model.settings
	)


func _sync_corpse_pose(actor: EnemyVisual, corpse: Dictionary) -> void:
	place(actor, corpse.pos, 0, true)
	actor.scale = (
		Vector3.ONE
		* (
			1.65
			if corpse.boss
			else (1.2 if corpse.get("archetype", "") in EnemyVisual.Director.ELITES else 1.0)
		)
	)
	actor.update_state(
		corpse, actor.get_meta("bands"), read_model.data.elapsed, Vector2.ZERO, [], read_model.settings
	)


func sample_culled_body(actor: EnemyVisual, record: Dictionary) -> bool:
	# Only a paint segment close enough to touch a hidden body needs its exact alpha frame.
	if not EnemyVisual.Director.Entry.revealed(record):
		return false
	if record.has("hp"):
		_sync_enemy_pose(actor, record)
	else:
		_sync_corpse_pose(actor, record)
	actor.sprite.global_basis = game.camera.global_basis.scaled(actor.scale * actor.dye_scale)
	return is_visible_in_tree()


func _model_in_range(point: Vector2, scale_factor: float = 1.0) -> bool:
	return model_range.contains(position_on(point, 1.4 * scale_factor), 2.0 * scale_factor)


func _enemy_in_range(record: Dictionary) -> bool:
	var bound_scale := 1.65 * EnemyVisual.BOSS_ART_SCALE if record.boss else 1.2
	return _model_in_range(record.pos, bound_scale)


func _sync_actors() -> void:
	var _startup_span := StartupTrace.scope("world.gd:_sync_actors")
	var wanted: Dictionary = {}
	var d = read_model.data
	for enemy in d.enemies:
		var key := "enemy_" + str(enemy.id)
		wanted[key] = true
		if not actors.has(key):
			var visual := EnemyVisual.new()
			visual.setup(
				enemy.get("archetype", "scraper"),
				font,
				float(game.world_profile.actors.enemy_height_m), enemy.boss
			)
			visual.setup_foreground(style, game.radius, enemy.boss)
			actors[key] = visual
			add_child(visual)
		var actor: Node3D = actors[key]
		actor.set_meta("culled", not _enemy_in_range(enemy))
		if actor.get_meta("culled"):
			actor.hide()
		else:
			_sync_enemy_pose(actor, enemy)
	for corpse in d.corpses:
		var opacity := Deaths.opacity(corpse, d.elapsed)
		if opacity <= 0.0:
			continue
		var key := "corpse_" + str(corpse.id)
		wanted[key] = true
		if not actors.has(key):
			var visual := EnemyVisual.new()
			visual.setup(corpse.get("archetype", "scraper"), font,
				float(game.world_profile.actors.enemy_height_m), corpse.boss)
			visual.setup_foreground(style, game.radius, corpse.boss, false)
			visual.set_meta("bands", body_texture(corpse.get("bands", [])))
			var live_key := "enemy_" + str(corpse.id)
			if actors.has(live_key):
				visual.direction = actors[live_key].direction
			visual.label.hide()
			visual.paint_material.render_priority = Style.ACTOR_PRIORITY - 1
			actors[key] = visual
			add_child(visual)
		var actor: EnemyVisual = actors[key]
		actor.visible = _enemy_in_range(corpse)
		actor.set_meta("culled", not actor.visible)
		if actor.visible:
			actor.paint_material.set_shader_parameter("corpse_opacity", opacity)
			_sync_corpse_pose(actor, corpse)
	# Effects are in release order. The last brush from each caster owns its pose.
	var brushes := {}
	for effect in d.effects:
		if effect.get("kind", "") == "brush":
			brushes[int(effect.source)] = effect
	for i in d.slots.size():
		var slot = d.slots[i]
		var key = "friend_%s_%s" % [slot.id, slot.stage]
		wanted[key] = true
		if not actors.has(key):
			actors[key] = _make_actor(slot.species, int(slot.stage))
			add_child(actors[key])
			MovementFrames.Final.prepare_battle_atlases(actors[key].get_meta("sprite"))
		var point: Vector2 = read_model.source_position(slot)
		actors[key].visible = _model_in_range(point)
		if not actors[key].visible:
			continue
		place(actors[key], point, 0.02, true)
		pet_view.update_brush(actors[key], slot, point, d.elapsed,
			brushes.get(int(slot.id), {}), read_model.settings)
	if not d.partner.is_empty():
		var key = "reward_" + str(d.node.id)
		wanted[key] = true
		if not actors.has(key):
			actors[key] = _make_actor(d.partner.species, 1)
			add_child(actors[key])
		actors[key].visible = _model_in_range(d.partner.pos)
		if actors[key].visible:
			place(
				actors[key],
				d.partner.pos,
				0.12 + (0.0 if read_model.settings.low_fx else sin(d.elapsed * 3) * 0.08),
				true
			)
			MovementFrames.sample(actors[key].get_meta("sprite"), Vector2.ZERO, 0, 0)
	for key in actors.keys():
		if not wanted.has(key):
			actors[key].queue_free()
			actors.erase(key)


func _align_name(label: Label3D) -> void:
	# Draw both glyphs and their outline after foreground actors/corpses.
	# Scene depth and the caller's planet/viewport visibility checks still apply.
	label.no_depth_test = false
	label.render_priority = Style.ACTOR_PRIORITY + 3
	label.outline_render_priority = Style.ACTOR_PRIORITY + 2
	var point := label.global_position
	var camera: Camera3D = game.camera
	if not game.world_point_visible(point):
		return
	var pixels := camera.unproject_position(point).distance_to(
		camera.unproject_position(point + camera.global_basis.y)
	)
	var inherited_scale := label.global_basis.get_scale().y
	label.pixel_size = 14.0 / (float(label.font_size) * maxf(0.01, pixels * inherited_scale))
