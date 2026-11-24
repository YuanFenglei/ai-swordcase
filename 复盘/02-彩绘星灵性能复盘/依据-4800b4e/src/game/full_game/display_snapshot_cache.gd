extends RefCounted
## Render-owned ground and surface descriptors, separate from the full public snapshot.
const SurfaceView = preload("res://full_game/surface_read_model.gd")
const Layers = preload("res://full_game/paint_stamps.gd")
var ground: Dictionary = {}
var stamps: Dictionary = {}
var surfaces := SurfaceView.new()
var revision := -2
var _run_revision := -1
var _source: Dictionary = {}
# Detached dye records per id: [authority record, its revision, read-only copy].
var _records: Dictionary = {"surfaces": {}, "bodies": {}}


## True when GameWorld committed, replaced its state or changed ground after the last capture.
func stale(run: RefCounted) -> bool:
	return (run.revision != _run_revision or not is_same(run.data, _source)
		or run.paint_system.ground_revision != revision)


func capture(run: RefCounted) -> Dictionary:
	_run_revision = run.revision
	_source = run.data
	var paint_system: RefCounted = run.paint_system
	var space: RefCounted = paint_system.space
	var full: bool = revision != paint_system.changes_since or surfaces.generation != space.generation
	var state: Dictionary = run.data
	var cells: Dictionary = state.get("ground", {})
	var paint: Dictionary = state.get("paint", {}).duplicate()
	var source_stamps: Dictionary = paint.get("stamps", {})
	var keys: Array = cells.keys() if full else paint_system.changed_cells.keys()
	if full:
		ground.clear()
		stamps.clear()
		surfaces.capture(space)
		for kind in _records:
			_records[kind].clear()
	for key in keys:
		_capture_cell(key, cells, source_stamps)
	revision = paint_system.ground_revision
	paint_system.changes_since = revision
	paint_system.changed_cells.clear()
	var view := state.duplicate()
	view.erase("paint")
	view.erase("ground")
	view = view.duplicate(true)
	if not state.is_empty():
		var source_paint: Dictionary = state.get("paint", {})
		paint.erase("stamps")
		for kind in _records:
			paint.erase(kind)
		paint = paint.duplicate(true)
		paint.stamps = stamps
		for kind in _records:
			if source_paint.has(kind):
				paint[kind] = _detach_records(source_paint[kind], _records[kind])
		view.paint = paint
		view.ground = ground
	return {"data": view, "settings": run.settings.duplicate(true), "ground_revision": revision,
		"radius": run.world_radius, "surfaces": surfaces, "changed_cells": keys, "full": full,
		"portal": run.portal_snapshot()}


## Surface and body dye maps are large and change rarely. Writers bump a record's revision
## after each edit, so a copy stays valid until the record is replaced or its revision moves.
func _detach_records(source: Dictionary, cache: Dictionary) -> Dictionary:
	var result := {}
	for id in source:
		var record: Dictionary = source[id]
		var entry: Array = cache.get(id, [])
		if entry.is_empty() or not is_same(entry[0], record) or entry[1] != record.get("revision"):
			var copy: Dictionary = record.duplicate(true)
			for field in copy:
				if copy[field] is Dictionary:
					copy[field].make_read_only()
			copy.make_read_only()
			entry = [record, record.get("revision"), copy]
			cache[id] = entry
		result[id] = entry[2]
	if cache.size() > result.size():
		for id in cache.keys():
			if not source.has(id):
				cache.erase(id)
	return result


func _capture_cell(key: String, cells: Dictionary, source_stamps: Dictionary) -> void:
	if ground.has(key):
		for old in Layers.layers(ground[key]):
			var id: String = old.get("stamp_id", "")
			if not source_stamps.has(id) or source_stamps[id].cells.is_empty():
				stamps.erase(id)
	if not cells.has(key):
		ground.erase(key)
		return
	var tile: Dictionary = cells[key]
	# Combat timers continue ticking on the authority and are never used for drawing.
	ground[key] = {"pos": tile.pos, "color": tile.color, "layers": Layers.layers(tile).duplicate(true),
		"wet_at": tile.get("wet_at", -10.0), "life": tile.get("life", 0.0)}
	for layer in ground[key].layers:
		var id: String = layer.get("stamp_id", "")
		if source_stamps.has(id) and not stamps.has(id):
			var stamp: Dictionary = source_stamps[id].duplicate()
			stamp.erase("cells")
			stamps[id] = stamp.duplicate(true)
