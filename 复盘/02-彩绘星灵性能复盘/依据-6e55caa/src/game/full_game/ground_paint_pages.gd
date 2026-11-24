extends RefCounted
## A 32 m page contains 64 x 64 authority cells. Empty pages share the initial blank CPU image.
const Strokes = preload("res://full_game/ground_stroke_table.gd")
const Stamps = preload("res://full_game/paint_stamps.gd")
const EDGE := 64
var pages: Dictionary = {}
var texture: Texture2DArray
var strokes := Strokes.new()
var half_grid := 0
var uploads := 0
var folds_at_antipode := false


func reset(radius: float, material: ShaderMaterial) -> void:
	pages.clear()
	strokes.cache.reset()
	strokes = Strokes.new()
	material.set_shader_parameter("spray_stamps", null)
	material.set_shader_parameter("hero_mask", preload("res://full_game/spray_shape.gd").HERO_MASK)
	material.set_shader_parameter("spray_masks", preload("res://full_game/spray_shape.gd").ATLAS)
	texture = null
	# A brush centred on the antipode can deposit beyond the principal planar disk.
	half_grid = ceili(PI * radius / (EDGE * 0.5)) + 1
	folds_at_antipode = false
	material.set_shader_parameter("paint_fold", false)
	material.set_shader_parameter("ground_pages", null)
	material.set_shader_parameter("stroke_records", null)
	material.set_shader_parameter("paint_grid_half", 0)


func update(view: RefCounted, material: ShaderMaterial, owner: Node = null) -> void:
	if view.rebuild_ground:
		reset(view.world_radius, material)
	strokes.cache.parent = owner
	var ground: Dictionary = view.data.ground
	if ground.is_empty():
		if texture != null:
			reset(view.world_radius, material)
		view.rebuild_ground = false
		view.changed_cells.clear()
		return
	var keys: Array = ground.keys() if view.rebuild_ground else view.changed_cells.keys()
	var touched: Dictionary = {}
	for key in keys:
		var xy := str(key).split(",")
		var cell := Vector2i(int(xy[0]), int(xy[1]))
		var page := _write_cell(cell, ground.get(key, {}), view.data.paint.stamps)
		if page >= 0:
			touched[page] = true
		var center := (Vector2(cell) + Vector2.ONE * 0.5) * 0.5
		if not folds_at_antipode and center.length() + 0.36 >= PI * view.world_radius:
			folds_at_antipode = true
			material.set_shader_parameter("paint_fold", true)
	if not touched.is_empty() and not _upload(touched, material):
		view.rebuild_ground = true
		return
	strokes.flush(material)
	view.rebuild_ground = false
	view.changed_cells.clear()


func _write_cell(cell: Vector2i, tile: Dictionary, stamps: Dictionary) -> int:
	var block := Vector2i((Vector2(cell) / EDGE).floor()) + Vector2i.ONE * half_grid
	var grid := half_grid * 2
	if block.x < 0 or block.y < 0 or block.x >= grid or block.y >= grid:
		return -1
	var page := block.y * grid + block.x
	if not pages.has(page):
		pages[page] = Image.create(EDGE, EDGE, false, Image.FORMAT_RGBAF)
	var image: Image = pages[page]
	var pixel := Vector2i(posmod(cell.x, EDGE), posmod(cell.y, EDGE))
	var old := image.get_pixelv(pixel)
	var control := Color(0, 0, 0, 0)
	if not tile.is_empty():
		var layers := Stamps.layers(tile)
		control.r = strokes.acquire(layers[0], stamps)
		if layers.size() == 2:
			control.g = strokes.acquire(layers[1], stamps)
		control.b = tile.get("wet_at", -10.0)
		control.a = tile.get("life", 0.0)
	strokes.release(int(old.r))
	strokes.release(int(old.g))
	image.set_pixelv(pixel, control)
	return page


func _upload(touched: Dictionary, material: ShaderMaterial) -> bool:
	if texture == null:
		var layers: Array[Image] = []
		layers.resize(4 * half_grid * half_grid)
		layers.fill(Image.create(EDGE, EDGE, false, Image.FORMAT_RGBAF))
		for index in pages:
			layers[index] = pages[index]
		texture = Texture2DArray.new()
		var result := texture.create_from_images(layers)
		if result != OK:
			texture = null
			push_error("Ground paint texture allocation failed: " + error_string(result))
			return false
		material.set_shader_parameter("ground_pages", texture)
		material.set_shader_parameter("paint_grid_half", half_grid)
	else:
		for index in touched:
			texture.update_layer(pages[index], index)
	uploads += touched.size()
	return true
