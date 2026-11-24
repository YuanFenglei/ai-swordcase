extends RefCounted
## Starling attack commands, damage and active abilities. No file IO, level flow or reward creation.
const HeroInk = preload("res://full_game/hero_ink.gd")
signal ink_reaction(title: String, color: int, point: Vector3)
signal changed
signal message_changed(value: String)
signal player_damaged
signal ended(reason: String)
signal enemy_defeated(enemy: Dictionary, color: int)
signal color_ultimate_cast(payload: Dictionary)
const ColorUltimates = preload("res://full_game/color_ultimate_system.gd")
const C = preload("res://full_game/catalog.gd")
const Attributes = preload("res://full_game/attack_attributes.gd")
const EnemyConfig = preload("res://full_game/enemy_config.gd")
const Entry = preload("res://full_game/enemy_entry.gd")
const PetAI = preload("res://full_game/pet_ai.gd")
const Characters = preload("res://full_game/character_system.gd")
const Spatial = preload("res://full_game/spatial_adapter.gd")
const PaintSystem = preload("res://full_game/paint_system.gd")
const Brushes = preload("res://full_game/brush_system.gd")
const Queries = preload("res://full_game/target_queries.gd")
var data: Dictionary = {}
var characters: Characters
var spatial: Spatial
var paint_system: PaintSystem
var brushes: Brushes
var pet_ai: PetAI
var targets: Queries
var message: String:
	set(value):
		message_changed.emit(value)


func bind(state: Dictionary, actors: Characters, geometry: Spatial, pigment: PaintSystem,
	brush: Brushes, behavior: PetAI, queries: Queries) -> void:
	data = state
	characters = actors
	spatial = geometry
	paint_system = pigment
	brushes = brush
	pet_ai = behavior
	targets = queries


func release_brush(source: Dictionary, direction: Vector2, target_position: Variant = null) -> void:
	if int(source.id) <= 0 or spatial.player_sheltered():
		return
	var info: Dictionary = C.SPECIES[source.species]
	var values := Attributes.ordinary(source, data.upgrades)
	var origin := characters.source_position(source)
	var mods: Dictionary = values.mods
	direction = PetAI.face(source, direction)
	mods.target_distance = values.range
	if target_position is Vector2:
		mods.target_distance = minf(C.ATTACK_RANGE, origin.distance_to(target_position))
	_select_spray(info, mods)
	brushes.paint(info.brush, origin, direction, int(info.color), values.damage, values.dot,
		values.life, int(source.id), false, mods)
	source.attack_started = data.elapsed
	source.attack_delivery = "brush"
	source.attack_direction = direction
	source.attack_cooldown = values.interval

func _select_spray(info: Dictionary, mods: Dictionary) -> void:
	var kind := ["fan", "sweep", "stream", "lob"].find(info.attack.get("spray", ""))
	if kind >= 0:
		mods.spray_kind = kind


func pet_target(slot: Dictionary) -> Dictionary:
	if int(slot.id) > 0:
		var query_slot: Dictionary = slot.duplicate(true)
		if not query_slot.has("ai"):
			query_slot.ai = {"pos": characters.home(slot), "target": -1}
		return targets.choose(query_slot, "attack")
	return {}

func attack_source(source: Dictionary) -> void:
	if int(source.id) <= 0 or float(source.get("attack_cooldown", 0)) > 0 or spatial.player_sheltered():
		return
	var target := pet_ai.firing_target(source)
	var origin := characters.source_position(source)
	var direction := PetAI.facing(source)
	var position := origin + direction * C.ATTACK_RANGE
	if not target.is_empty():
		position = target.pos
		direction = PetAI.face(source, Vector2(position) - origin)
	data.round += 1
	release_brush(source, direction, position)

func pet_attacks() -> void:
	if spatial.player_sheltered():
		return
	if data.phase not in ["explore", "battle"] or not str(data.panel).is_empty():
		return
	characters.adopt_roster()
	for slot in data.slots:
		if C.SPECIES[slot.species].attack.enabled:
			attack_source(slot)
			if float(slot.active_cooldown) <= 0.0:
				_automatic_skill(slot)
	ColorUltimates.release_ready(data, characters, spatial, damage_enemy, color_ultimate_cast)


func tick_timers(dt: float) -> void:
	if data.phase not in ["explore", "battle"] or not str(data.panel).is_empty():
		return
	data.cooldown = maxf(0, data.cooldown - dt)
	data.hero.attack_cooldown = maxf(0, float(data.hero.attack_cooldown) - dt)
	for slot in data.slots:
		slot.attack_cooldown = maxf(0, float(slot.get("attack_cooldown", 0)) - dt)
		var remaining := float(slot.get("active_cooldown", Attributes.skill_interval(int(slot.stage)))) - dt
		slot.active_cooldown = 0.0 if remaining <= 0.000001 else remaining
	ColorUltimates.tick(data, dt, spatial, damage_enemy)

func fire_hero(color: int, aim: Callable) -> bool:
	if data.is_empty() or data.phase not in ["explore", "battle"] or not str(data.panel).is_empty():
		return false
	if not HeroInk.owned(data, color):
		return false
	data.hero.ink_color = color
	if spatial.player_sheltered() or float(data.hero.attack_cooldown) > 0:
		return false
	HeroInk.fire(self, aim.call(), color)
	return true


func pet_ink_hit(enemy: Dictionary, damage: float, color: int, origin: Variant) -> void:
	if damage > 0 and not PaintSystem.Protection.immune(enemy):
		HeroInk.prime(data, enemy, color)
	damage_enemy(enemy, damage, color, origin)


func hero_brush_hit(enemy: Dictionary, effect: Dictionary) -> void:
	if PaintSystem.Protection.immune(enemy) or float(enemy.hp) <= 0:
		return
	var point: Vector3 = paint_system.space.terrain.position(enemy.pos, 0.8)
	HeroInk.resolve_contact(self, enemy, int(effect.color), effect.pos, effect.direction, point)


func hero_ink_hit(hit: Dictionary, bullet: Dictionary) -> void:
	var enemy := characters.find_enemy(int(hit.actor))
	if not enemy.is_empty() and not PaintSystem.Protection.immune(enemy):
		HeroInk.resolve(self, enemy, hit, bullet)


func damage_player() -> void:
	if data.is_empty() or spatial.player_sheltered() or not characters.player.receive_hit():
		return
	player_damaged.emit()
	if data.health <= 0:
		ended.emit("护心耗尽")

func _tick_ground_damage(dt: float) -> void:
	for enemy in data.enemies.duplicate():
		if Entry.locked(enemy):
			continue
		var tile = paint_system.sample(enemy.pos)
		if tile.is_empty():
			enemy.dot = 0.0
		else:
			enemy.dot += dt
			if enemy.dot >= 1.0:
				enemy.dot -= 1.0
				damage_enemy(enemy, float(tile.damage), int(tile.color))

func damage_enemy(enemy: Dictionary, damage: float, color: int, origin: Variant = null) -> void:
	if PaintSystem.Protection.immune(enemy):
		return
	if float(enemy.hp) <= 0 or damage <= 0:
		return
	var base := damage * EnemyConfig.damage_factor(enemy, origin)
	var actual := minf(float(enemy.hp), base)
	# A scene with billboard collision writes the exact contact UV in PaintState.apply_hit.
	if not paint_system.space.actor_query.is_valid():
		PaintSystem.State.legacy_body(paint_system, enemy, color, origin)
	if not enemy.has("bands"):
		enemy.bands = []
	if not enemy.has("color_order"):
		enemy.color_order = [0, 0, 0, 0, 0, 0]
	enemy.hit_sequence = int(enemy.get("hit_sequence", 0)) + 1
	enemy.color_order[color] = enemy.hit_sequence
	var end = 1.0 - (float(enemy.hp) - actual) / float(enemy.max_hp)
	if not enemy.bands.is_empty() and int(enemy.bands.back().color) == color:
		enemy.bands.back().end = end
	else:
		enemy.bands.append({"color": color, "end": end})
	enemy.hp -= actual
	enemy.colors[color] += actual / float(enemy.max_hp)
	enemy.last_color = color
	if enemy.hp <= 0:
		enemy_defeated.emit(enemy, color)

func active_offer(id: int) -> Dictionary:
	var slot := characters.find_slot(id) if not data.is_empty() else {}
	if slot.is_empty():
		return {"available": false, "label": "离队", "reason": "伙伴已不在队伍中"}
	var stage := int(slot.stage)
	var interval := Attributes.skill_interval(stage)
	return {"available": false, "label": "自动", "reason": "每 %.0f 秒自动释放" % interval,
		"cooldown": Attributes.pending_skill_time(slot), "interval": interval,
		"area_scale": Attributes.skill_area_scale(stage)}

func active(_id: int) -> bool:
	# Compatibility endpoint only: manual callers cannot trigger an automatic skill.
	return false


func _automatic_skill(slot: Dictionary) -> bool:
	# Consume this clock even when a wall blocks the old two-metre skill origin.
	# The next opportunity is one full interval away, with no queued retries or bursts.
	var stage := int(slot.stage)
	slot.active_cooldown = Attributes.skill_interval(stage)
	var origin := characters.source_position(slot)
	var target := pet_target(slot)
	var direction := PetAI.facing(slot)
	var distance := C.ATTACK_RANGE
	if not target.is_empty():
		direction = PetAI.face(slot, Vector2(target.pos) - origin)
		distance = minf(C.ATTACK_RANGE, origin.distance_to(target.pos))
	if not spatial.line_clear(origin, origin + direction * 2.0):
		return false
	var info: Dictionary = C.SPECIES[slot.species]
	# Keep the old aim point and stage-one reach; snapshot the current stage's coverage.
	var mods := {"base_reach": C.ATTACK_RANGE / C.ACTIVE_GEOMETRY_SCALE, "target_distance": distance,
		"active_area_scale": Attributes.skill_area_scale(stage)}
	if slot.species == "fusion":
		mods.horizontal_length = 1.25
	data.round += 1
	_select_spray(info, mods)
	brushes.paint(info.brush, origin, direction, int(info.color), C.ACTIVE_DAMAGE,
		C.ACTIVE_DOT, C.ACTIVE_PAINT_LIFE, int(slot.id), true, mods)
	slot.attack_started = data.elapsed
	slot.attack_delivery = "brush"
	slot.attack_direction = direction
	changed.emit()
	return true
