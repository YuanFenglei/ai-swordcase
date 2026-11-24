extends RefCounted
## Struct-of-arrays battle simulation.
## - fixed 20 Hz tick on its own thread, fanned out over WorkerThreadPool in 512-unit chunks
## - lossy uniform grid (1.25 m cells, 4 slots) rebuilt by the units themselves every tick (double buffered)
## - flow fields (2.5 m cells) computed on a second thread: one "nearest enemy" field per army + one per move order
## - the tick writes the MultiMesh instance buffer directly; the vertex shader interpolates between the last two ticks
## NOTE: integer `/` and `%` are avoided in every threaded loop: in 4.7 they do not scale across threads.

const MB := preload("res://scripts/meshes.gd")
const WorldScript := preload("res://scripts/world.gd")
const HALF := 320.0
const INV_CELL := 0.8
const GW := 512
const GN := 262144
const FN := 65536
const NFIELD := 32
const TICK := 0.05
const CORPSE_T := 26.0
const AGGRO := 13.0
const BIG := 1 << 28
const NT := 4
const PUFF_N := 8192
const ARROW_DMG := 15.0

const ST_FREE := 0
const ST_IDLE := 1
const ST_WALK := 2
const ST_ATK := 3
const ST_DEAD := 4
const O_HOLD := 0
const O_MOVE := 1
const O_AMOVE := 2
const O_HUNT := 3

var T_SPEED := PackedFloat32Array([4.2, 4.4, 9.0, 4.2])
var T_RAD := PackedFloat32Array([0.48, 0.45, 0.85, 0.48])
var T_HP := PackedFloat32Array([100.0, 55.0, 240.0, 140.0])
var T_DMG := PackedFloat32Array([13.0, 5.0, 30.0, 10.0])
var T_CD := PackedFloat32Array([1.0, 2.4, 1.3, 1.2])
var T_RANGE := PackedFloat32Array([0.0, 55.0, 0.0, 0.0])
var T_ACC := PackedFloat32Array([0.4, 0.4, 0.16, 0.4])

var cap := 0
var nchunks := 0
var t_start := PackedInt32Array([0, 0, 0, 0])
var t_end := PackedInt32Array([0, 0, 0, 0])
var t_hi := PackedInt32Array([0, 0, 0, 0])
var t_cur := PackedInt32Array([0, 0, 0, 0])
var c_type := PackedByteArray()

# units
var px := PackedFloat32Array()
var pz := PackedFloat32Array()
var vx := PackedFloat32Array()
var vz := PackedFloat32Array()
var dirx := PackedFloat32Array()
var dirz := PackedFloat32Array()
var hp := PackedFloat32Array()
var rad := PackedFloat32Array()
var cd := PackedFloat32Array()
var st_time := PackedFloat32Array()
var hit_t := PackedFloat32Array()
var useed := PackedFloat32Array()
var hx := PackedFloat32Array()
var hz := PackedFloat32Array()
var arrive := PackedFloat32Array()
var tgt := PackedInt32Array()
var state := PackedByteArray()
var team := PackedByteArray()
var order := PackedByteArray()
var ofield := PackedByteArray()
var sel := PackedByteArray()
var form := PackedByteArray()
var buf := PackedFloat32Array()

# grids
var gcnt_r := PackedInt32Array()
var gcnt_w := PackedInt32Array()
var gslot_r := PackedInt32Array()
var gslot_w := PackedInt32Array()
var rep := PackedInt32Array()
var mmb := PackedByteArray()
var stain := PackedByteArray()
var cost := PackedByteArray()
var hmap := PackedFloat32Array()

# flow fields
var FDX := PackedFloat32Array()
var FDZ := PackedFloat32Array()
var FDIST := PackedFloat32Array()
var FNEXT := PackedInt32Array()
var s_dist := PackedInt32Array()
var s_t := PackedFloat32Array()
var s_q := PackedInt32Array()
var s_inq := PackedByteArray()
var s_mark := PackedByteArray()
var NOFF := PackedInt32Array([-1, 1, -256, 256, -257, -255, 255, 257])
var NCST := PackedInt32Array([10, 10, 10, 10, 14, 14, 14, 14])
var NOA := PackedInt32Array([0, 0, 0, 0, -1, 1, -1, 1])
var NOB := PackedInt32Array([0, 0, 0, 0, -256, -256, 256, 256])
var flow_req: Array = []
var flow_done: Array = []
var flow_mutex := Mutex.new()
var flow_ms := 0.0
var flow_count := 0
var next_slot := 2

# per-chunk outputs
var ch_alive := PackedInt32Array()
var flist := PackedInt32Array()
var fcnt := PackedInt32Array()
var ev_x := PackedFloat32Array()
var ev_z := PackedFloat32Array()
var ev_k := PackedByteArray()
var ecnt := PackedInt32Array()
var ch_prof := PackedInt32Array()

# projectiles / puffs
var arrow_n := 4096
var abuf := PackedFloat32Array()
var a_head := 0
var b_tgt: Array[PackedInt32Array] = []
var b_pos: Array[PackedFloat32Array] = []
var pbuf := PackedFloat32Array()
var p_head := 0
var rng := RandomNumberGenerator.new()

# state
var tick := 0
var sim_time := 0.0
var alive := PackedInt32Array([0, 0])
var kills := 0
var quit := false
var busy := false
var have_tick := false
var warp := false
var paused := false
var speed := 1.0
var steps := 1
var keep_prev := false
var span := TICK
var hook := Callable()
var go_sem := Semaphore.new()
var done_sem := Semaphore.new()
var sim_thread := Thread.new()
var flow_thread := Thread.new()
var pending: Array[Callable] = []
var last_upload := 0
var due := 0
var interval := TICK
var shader_base := 0.0
var selection := PackedInt32Array()

# stats (ms, smoothed)
var ms_grid := 0.0
var ms_update := 0.0
var ms_serial := 0.0
var ms_tick := 0.0
var ms_upload := 0.0
var prof := PackedFloat32Array([0.0, 0.0, 0.0])
var acc_n := 0
var acc_tick := 0.0
var acc_update := 0.0
var acc_serial := 0.0
var acc_grid := 0.0
var acc_upload := 0.0
var acc_prof := PackedFloat64Array([0.0, 0.0, 0.0])

# render resources: one MultiMesh per 512-unit chunk, so chunks can be frustum culled and switch LOD by distance
var ch_mm: Array[MultiMesh] = []
var ch_nodes: Array[MultiMeshInstance3D] = []
var ch_box := PackedFloat32Array()
var ch_vis := PackedInt32Array()
var ch_far := PackedByteArray()
var ch_shadow := PackedByteArray()
var near_mesh: Array[Mesh] = []
var far_mesh: Array[Mesh] = []
var cam_pos := Vector3(0, 300, 0)
var lod_dist := 130.0
var shadow_dist := 330.0
var mm_arrow: MultiMesh
var mm_puff: MultiMesh
var mm_img: Image
var mm_tex: ImageTexture
var stain_tex: ImageTexture
var stain_dirty := 0


func setup(capacity: int, world: WorldScript, rings: bool) -> void:
	cost = world.cost
	hmap = world.hdata
	stain_tex = world.stain_tex
	var fr: Array[float] = [0.585, 0.25, 0.15, 0.015]
	var s := 0
	for t in NT:
		var n := (int(ceil(capacity * fr[t] / 512.0)) + 1) * 512
		t_start[t] = s
		t_end[t] = s + n
		t_hi[t] = s
		t_cur[t] = s
		s += n
	cap = s
	nchunks = cap >> 9
	c_type.resize(nchunks)
	for c in nchunks:
		var i := c << 9
		c_type[c] = 0 if i < t_end[0] else (1 if i < t_end[1] else (2 if i < t_end[2] else 3))
	px.resize(cap); pz.resize(cap); vx.resize(cap); vz.resize(cap); dirx.resize(cap); dirz.resize(cap)
	hp.resize(cap); rad.resize(cap); cd.resize(cap); st_time.resize(cap); hit_t.resize(cap); useed.resize(cap)
	hx.resize(cap); hz.resize(cap); arrive.resize(cap)
	tgt.resize(cap); state.resize(cap); team.resize(cap); order.resize(cap); ofield.resize(cap); sel.resize(cap); form.resize(cap)
	buf.resize(cap * 16)
	gcnt_r.resize(GN); gcnt_w.resize(GN); gslot_r.resize(GN * 4); gslot_w.resize(GN * 4)
	rep.resize(FN * 2)
	rep.fill(-1)
	mmb.resize(FN)
	stain.resize(1024 * 1024 * 2)
	FDX.resize(FN * NFIELD); FDZ.resize(FN * NFIELD); FDIST.resize(FN * NFIELD); FNEXT.resize(FN * NFIELD)
	FDIST.fill(1e6)
	FNEXT.fill(-1)
	s_dist.resize(FN); s_t.resize(FN); s_q.resize(FN); s_inq.resize(FN); s_mark.resize(FN)
	ch_alive.resize(nchunks * 2); flist.resize(cap); fcnt.resize(nchunks)
	ev_x.resize(nchunks * 8); ev_z.resize(nchunks * 8); ev_k.resize(nchunks * 8); ecnt.resize(nchunks)
	ch_prof.resize(nchunks * 4)
	arrow_n = 4096
	while arrow_n < (t_end[1] - t_start[1]) * 4:
		arrow_n *= 2
	abuf.resize(arrow_n * 12)
	pbuf.resize(PUFF_N * 12)
	for i in 128:
		b_tgt.append(PackedInt32Array())
		b_pos.append(PackedFloat32Array())
	rng.seed = 4242

	near_mesh = [MB.infantry(false, rings), MB.archer(rings), MB.cavalry(rings), MB.infantry(true, rings)]
	far_mesh = [MB.infantry_far(false, rings), MB.archer_far(rings), MB.cavalry_far(rings), MB.infantry_far(true, rings)]
	ch_box.resize(nchunks * 4)
	ch_vis.resize(nchunks)
	ch_far.resize(nchunks)
	ch_shadow.resize(nchunks)
	ch_shadow.fill(1)
	for c in nchunks:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = near_mesh[c_type[c]]
		mm.instance_count = 512
		mm.visible_instance_count = 0
		mm.custom_aabb = AABB(Vector3(-HALF, -20, -HALF), Vector3(640, 60, 640))
		ch_mm.append(mm)
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.visible = false
		ch_nodes.append(node)
	mm_arrow = MultiMesh.new()
	mm_arrow.transform_format = MultiMesh.TRANSFORM_3D
	mm_arrow.mesh = MB.arrow()
	mm_arrow.instance_count = arrow_n
	mm_arrow.custom_aabb = AABB(Vector3(-HALF, -20, -HALF), Vector3(640, 120, 640))
	mm_puff = MultiMesh.new()
	mm_puff.transform_format = MultiMesh.TRANSFORM_3D
	var qm := QuadMesh.new()
	qm.size = Vector2(1, 1)
	mm_puff.mesh = qm
	mm_puff.instance_count = PUFF_N
	mm_puff.custom_aabb = AABB(Vector3(-HALF, -20, -HALF), Vector3(640, 120, 640))
	mm_img = Image.create_empty(256, 256, false, Image.FORMAT_R8)
	mm_tex = ImageTexture.create_from_image(mm_img)
	_upload()
	last_upload = Time.get_ticks_usec()
	due = last_upload
	sim_thread.start(_sim_loop)
	flow_thread.start(_flow_loop)


func shutdown() -> void:
	if busy:
		done_sem.wait()
		busy = false
	quit = true
	go_sem.post()
	sim_thread.wait_to_finish()
	flow_thread.wait_to_finish()


# ---------------------------------------------------------------- main-thread API

func spawn(tm: int, ty: int, x: float, z: float, fx: float, fz: float, ord: int) -> int:
	var fc := (int((z + HALF) * 0.4) << 8) | int((x + HALF) * 0.4)
	if cost[fc] == 255:
		return -1
	var i := -1
	if t_hi[ty] < t_end[ty]:
		i = t_hi[ty]
		t_hi[ty] = i + 1
	else:
		var cur := t_cur[ty]
		var e := t_end[ty]
		var s := t_start[ty]
		for k in 96:
			cur += 1
			if cur >= e:
				cur = s
			if state[cur] == ST_FREE:
				i = cur
				break
		t_cur[ty] = cur
		if i < 0:
			return -1
	px[i] = x; pz[i] = z; vx[i] = 0.0; vz[i] = 0.0; dirx[i] = fx; dirz[i] = fz
	hp[i] = T_HP[ty]; rad[i] = T_RAD[ty]
	var sd := rng.randf()
	useed[i] = sd
	cd[i] = sd * T_CD[ty]
	st_time[i] = -10.0; hit_t[i] = -10.0; hx[i] = x; hz[i] = z; arrive[i] = 0.0
	tgt[i] = -1; state[i] = ST_IDLE; team[i] = tm; order[i] = ord; ofield[i] = 0; sel[i] = 0; form[i] = 0
	var o := i << 4
	buf[o] = x; buf[o + 1] = z; buf[o + 2] = x; buf[o + 3] = z
	buf[o + 4] = fx; buf[o + 5] = fz; buf[o + 6] = fx; buf[o + 7] = fz
	buf[o + 8] = 1.0; buf[o + 9] = -10.0; buf[o + 10] = -10.0; buf[o + 11] = 0.0
	buf[o + 12] = float(tm); buf[o + 13] = 0.0; buf[o + 14] = sd; buf[o + 15] = 1.0
	alive[tm] += 1
	return i


## Line formation: `files` wide (along z), as many ranks as needed, growing backwards from the front x.
func spawn_block(tm: int, ty: int, n: int, front_x: float, z0: float, z1: float, spacing: float, ord: int) -> float:
	var face := 1.0 if tm == 0 else -1.0
	var files := int((z1 - z0) / spacing)
	var made := 0
	var rank := 0
	var gap := 26
	while made < n and rank < 400:
		var x := front_x - face * float(rank) * spacing
		if absf(x) > 292.0:
			break
		for f in files:
			if made >= n:
				break
			if (f % gap) == gap - 1 or (f % gap) == gap - 2:
				continue
			var z := z0 + (float(f) + 0.5) * spacing
			var sty := 3 if (ty == 0 and ((f * 7 + rank * 13) % 71) == 0) else ty
			if spawn(tm, sty, x + rng.randf_range(-0.12, 0.12), z + rng.randf_range(-0.12, 0.12), face, 0.0, ord) >= 0:
				made += 1
		rank += 1
	return front_x - face * float(rank) * spacing


## Standard army: infantry line in front, archers behind, cavalry on both wings.
func spawn_army(tm: int, n: int, front_x: float, ord: int) -> void:
	var face := 1.0 if tm == 0 else -1.0
	var n_inf := int(n * 0.6)
	var n_arc := int(n * 0.25)
	var n_cav := n - n_inf - n_arc
	var back := spawn_block(tm, 0, n_inf, front_x, -205.0, 205.0, 1.12, ord)
	spawn_block(tm, 1, n_arc, back - face * 5.0, -205.0, 205.0, 1.12, ord)
	spawn_block(tm, 2, n_cav / 2, front_x, -278.0, -212.0, 2.1, ord)
	spawn_block(tm, 2, n_cav - n_cav / 2, front_x, 212.0, 278.0, 2.1, ord)


func ids_of(tm: int, ty := -1, z0 := -1e9, z1 := 1e9) -> PackedInt32Array:
	var out := PackedInt32Array()
	for t in NT:
		if ty >= 0 and t != ty and not (ty == 0 and t == 3):
			continue
		for i in range(t_start[t], t_hi[t]):
			var st := state[i]
			if st != 0 and st != 4 and team[i] == tm and pz[i] >= z0 and pz[i] < z1:
				out.append(i)
	return out


## `half_len` > 0 turns the goal into a north-south segment; `form_dx` (not NAN) keeps the formation: every unit
## walks the flow field to the segment, then takes its own slot (old slot shifted by form_dx).
func order_units(ids: PackedInt32Array, mode: int, goal := Vector2.ZERO, half_len := 0.0, form_dx := NAN) -> void:
	if ids.is_empty():
		return
	if mode == O_HOLD or mode == O_HUNT:
		pending.append(_apply_order.bind(ids, mode, 0, 0.0, NAN))
		return
	var slot := next_slot
	next_slot += 1
	if next_slot >= NFIELD:
		next_slot = 2
	flow_mutex.lock()
	flow_req.append([slot, goal, ids, mode, half_len, form_dx])
	flow_mutex.unlock()


func _apply_order(ids: PackedInt32Array, mode: int, slot: int, arr: float, dx: float) -> void:
	var keep := not is_nan(dx)
	for i in ids:
		var st := state[i]
		if st == 0 or st == 4:
			continue
		order[i] = mode
		ofield[i] = slot
		arrive[i] = arr
		if keep:
			hx[i] += dx
			form[i] = 1
		else:
			hx[i] = px[i]
			hz[i] = pz[i]
			form[i] = 0


func set_selection(ids: PackedInt32Array) -> void:
	pending.append(_apply_selection.bind(ids))


func _apply_selection(ids: PackedInt32Array) -> void:
	for i in selection:
		sel[i] = 0
		buf[(i << 4) + 13] = 0.0
	selection = ids
	for i in ids:
		sel[i] = 1
		buf[(i << 4) + 13] = 1.0


## Units of `tm` inside a convex ground quad (screen box projected on the ground).
func select_quad(q: PackedVector2Array, tm: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var ax := q[0].x; var az := q[0].y; var bx := q[1].x; var bz := q[1].y
	var cx := q[2].x; var cz := q[2].y; var dx := q[3].x; var dz := q[3].y
	var sgn := 1.0 if ((bx - ax) * (cz - az) - (bz - az) * (cx - ax)) > 0.0 else -1.0
	for t in NT:
		for i in range(t_start[t], t_hi[t]):
			var st := state[i]
			if st == 0 or st == 4 or team[i] != tm:
				continue
			var x := px[i]
			var z := pz[i]
			if ((bx - ax) * (z - az) - (bz - az) * (x - ax)) * sgn < 0.0:
				continue
			if ((cx - bx) * (z - bz) - (cz - bz) * (x - bx)) * sgn < 0.0:
				continue
			if ((dx - cx) * (z - cz) - (dz - cz) * (x - cx)) * sgn < 0.0:
				continue
			if ((ax - dx) * (z - dz) - (az - dz) * (x - dx)) * sgn < 0.0:
				continue
			out.append(i)
	return out


func nearest_unit(p: Vector2, tm: int, max_d: float, ty := -1, need_state := -1) -> int:
	var best := -1
	var bd := max_d * max_d
	for t in NT:
		if ty >= 0 and t != ty:
			continue
		for i in range(t_start[t], t_hi[t]):
			var st := state[i]
			if st == 0 or st == 4 or (tm >= 0 and team[i] != tm) or (need_state >= 0 and st != need_state):
				continue
			var d := (px[i] - p.x) * (px[i] - p.x) + (pz[i] - p.y) * (pz[i] - p.y)
			if d < bd:
				bd = d
				best = i
	return best


## Densest stretch of the melee (20 m bins along z). `prev` gives hysteresis so the camera does not hop.
func hot_spot(prev: Vector2) -> Vector2:
	var cnt := PackedInt32Array()
	var sx := PackedFloat32Array()
	var sz := PackedFloat32Array()
	cnt.resize(32)
	sx.resize(32)
	sz.resize(32)
	for i in range(t_start[0], t_hi[0], 3):
		if state[i] == ST_ATK and absf(pz[i]) < 230.0:
			var b := clampi(int((pz[i] + 320.0) * 0.05), 0, 31)
			cnt[b] += 1
			sx[b] += px[i]
			sz[b] += pz[i]
	var pb := clampi(int((prev.y + 320.0) * 0.05), 0, 31)
	var best := pb
	var bc := cnt[pb] * 1.6 + 4.0
	for b in 32:
		if cnt[b] > bc:
			bc = cnt[b]
			best = b
	if cnt[best] < 4:
		return prev
	return Vector2(sx[best] / cnt[best], sz[best] / cnt[best])


func unit_pos(i: int, a: float) -> Vector3:
	var o := i << 4
	var x := lerpf(buf[o], buf[o + 2], a)
	var z := lerpf(buf[o + 1], buf[o + 3], a)
	return Vector3(x, hmap[(((int((z + HALF) * 1.6)) << 10) + int((x + HALF) * 1.6)) * 2 + 1], z)


## Called every rendered frame. Returns the interpolation factor for the shaders.
func frame() -> float:
	var now := Time.get_ticks_usec()
	if busy and done_sem.try_wait():
		busy = false
		have_tick = true
	if not busy and not paused and (warp or now >= due):
		# if rendering is slower than the tick rate, run up to 3 fixed ticks per hand-off so sim time keeps real time
		var tu := int(TICK * 1e6 / speed)
		due += tu
		var st := 1
		while due + tu <= now and st < 3:
			due += tu
			st += 1
		if due < now - 20000:
			due = now
		var t0 := Time.get_ticks_usec()
		if have_tick:
			_upload()
			var dtu := float(now - last_upload) * 1e-6
			interval = lerpf(interval, clampf(dtu, TICK / speed, 0.5), 0.35)
			span = TICK * steps
			shader_base = sim_time - span
		last_upload = now
		steps = st
		_drain()
		acc_upload += float(Time.get_ticks_usec() - t0) * 0.001
		busy = true
		go_sem.post()
	return clampf(float(now - last_upload) * 1e-6 / interval, 0.0, 1.0)


func shader_time(a: float) -> float:
	return shader_base + a * span


func _drain() -> void:
	flow_mutex.lock()
	var done := flow_done
	flow_done = []
	flow_mutex.unlock()
	for d: Array in done:
		_apply_order(d[0], d[1], d[2], d[3], d[4])
	var p := pending
	pending = []
	for f in p:
		f.call()
	if hook.is_valid():
		hook.call()


## Blocking fast-forward (used by --shots and scene setup).
func run_ticks(n: int) -> void:
	if busy:
		done_sem.wait()
		busy = false
	steps = 1
	for k in n:
		_drain()
		go_sem.post()
		done_sem.wait()
	have_tick = true
	_upload()
	span = TICK
	shader_base = sim_time - TICK
	last_upload = Time.get_ticks_usec()


func _upload() -> void:
	var cp := cam_pos
	for c in nchunks:
		var t := c_type[c]
		var a := c << 9
		var n := clampi(t_hi[t] - a, 0, 512)
		if n != ch_vis[c]:
			ch_vis[c] = n
			ch_mm[c].visible_instance_count = n
			ch_nodes[c].visible = n > 0
		if n == 0:
			continue
		var mm := ch_mm[c]
		RenderingServer.multimesh_set_buffer(mm.get_rid(), buf.slice(a << 4, (a + 512) << 4))
		var x0 := ch_box[c << 2]
		var z0 := ch_box[(c << 2) | 1]
		var x1 := ch_box[(c << 2) | 2]
		var z1 := ch_box[(c << 2) | 3]
		if x0 > x1:
			continue
		mm.custom_aabb = AABB(Vector3(x0 - 3.0, -8.0, z0 - 3.0), Vector3(x1 - x0 + 6.0, 26.0, z1 - z0 + 6.0))
		var dx := maxf(maxf(x0 - cp.x, cp.x - x1), 0.0)
		var dz := maxf(maxf(z0 - cp.z, cp.z - z1), 0.0)
		var d := sqrt(dx * dx + dz * dz + cp.y * cp.y)
		var far := d > lod_dist * (0.93 if ch_far[c] == 1 else 1.07)
		if far != (ch_far[c] == 1):
			ch_far[c] = 1 if far else 0
			mm.mesh = far_mesh[t] if far else near_mesh[t]
		var sh := d < shadow_dist * (1.07 if ch_shadow[c] == 1 else 0.93)
		if sh != (ch_shadow[c] == 1):
			ch_shadow[c] = 1 if sh else 0
			ch_nodes[c].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if sh else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	RenderingServer.multimesh_set_buffer(mm_arrow.get_rid(), abuf)
	RenderingServer.multimesh_set_buffer(mm_puff.get_rid(), pbuf)
	mm_img.set_data(256, 256, false, Image.FORMAT_R8, mmb)
	mm_tex.update(mm_img)
	stain_dirty += 1
	if stain_dirty >= 6:
		stain_dirty = 0
		stain_tex.update(Image.create_from_data(1024, 1024, false, Image.FORMAT_RG8, stain))


func take_stats() -> Dictionary:
	var n := maxi(acc_n, 1)
	var up := acc_update / n
	var ps := acc_prof[0] + acc_prof[1] + acc_prof[2]
	if ps <= 0.0:
		ps = 1.0
	var d := {
		"ticks": acc_n, "tick": acc_tick / n, "grid": acc_grid / n, "update": up, "serial": acc_serial / n,
		"upload": acc_upload / n, "neigh": up * acc_prof[0] / ps, "brain": up * acc_prof[1] / ps, "move": up * acc_prof[2] / ps,
		"flow": flow_ms,
	}
	acc_n = 0
	acc_tick = 0.0; acc_grid = 0.0; acc_update = 0.0; acc_serial = 0.0; acc_upload = 0.0
	acc_prof[0] = 0.0; acc_prof[1] = 0.0; acc_prof[2] = 0.0
	return d


# ---------------------------------------------------------------- sim thread

func _sim_loop() -> void:
	while true:
		go_sem.wait()
		if quit:
			break
		for k in steps:
			keep_prev = k > 0
			_tick()
		done_sem.post()


func _tick() -> void:
	var t0 := Time.get_ticks_usec()
	var a := gcnt_r
	gcnt_r = gcnt_w
	gcnt_w = a
	a = gslot_r
	gslot_r = gslot_w
	gslot_w = a
	gcnt_w.fill(0)
	mmb.fill(0)
	tick += 1
	sim_time = tick * TICK
	var t1 := Time.get_ticks_usec()
	var g := WorkerThreadPool.add_group_task(_upd, nchunks, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(g)
	var t2 := Time.get_ticks_usec()
	_serial()
	var t3 := Time.get_ticks_usec()
	acc_n += 1
	acc_grid += float(t1 - t0) * 0.001
	acc_update += float(t2 - t1) * 0.001
	acc_serial += float(t3 - t2) * 0.001
	acc_tick += float(t3 - t0) * 0.001
	ms_tick = lerpf(ms_tick, float(t3 - t0) * 0.001, 0.15)
	ms_update = lerpf(ms_update, float(t2 - t1) * 0.001, 0.15)
	ms_serial = lerpf(ms_serial, float(t3 - t2) * 0.001, 0.15)


func _stain_at(x: float, z: float) -> void:
	var sc := ((int((z + HALF) * 1.6) << 10) + int((x + HALF) * 1.6)) << 1
	stain[sc] = 255
	if stain[sc + 2] < 180: stain[sc + 2] = 180
	if stain[sc - 2] < 180: stain[sc - 2] = 180
	if stain[sc + 2048] < 180: stain[sc + 2048] = 180
	if stain[sc - 2048] < 180: stain[sc - 2048] = 180


func _upd(c: int) -> void:
	var a := c << 9
	var ct := c_type[c]
	var b := t_hi[ct]
	if b > a + 512:
		b = a + 512
	var nfire := 0
	var nev := 0
	var al0 := 0
	var al1 := 0
	var pa := 0
	var pb := 0
	var pc := 0
	var q0 := 0
	var q1 := 0
	var q2 := 0
	var bx0 := 1e9
	var bz0 := 1e9
	var bx1 := -1e9
	var bz1 := -1e9
	if a < b:
		var now := sim_time
		var tk := tick
		var first := not keep_prev
		var dt := TICK
		var spd0 := T_SPEED[ct]
		var myr := T_RAD[ct]
		var dmg := T_DMG[ct]
		var cdp := T_CD[ct]
		var rng_m := T_RANGE[ct]
		var acc := T_ACC[ct]
		var rng2 := rng_m * rng_m
		var rng_cells := rng_m * 0.4 - 1.0
		var ebase := c << 3
		for i in range(a, b):
			var st := state[i]
			if st == 0:
				continue
			var o := i << 4
			var x := px[i]
			var z := pz[i]
			if x < bx0: bx0 = x
			if x > bx1: bx1 = x
			if z < bz0: bz0 = z
			if z > bz1: bz1 = z
			if st == 4:
				if now - st_time[i] > CORPSE_T:
					state[i] = 0
					buf[o + 8] = 0.0
				continue
			var tm := team[i]
			if hp[i] <= 0.0:
				state[i] = 4
				st_time[i] = now
				buf[o + 2] = x
				buf[o + 3] = z
				buf[o + 8] = 4.0
				buf[o + 9] = now
				buf[o + 13] = 0.0
				_stain_at(x, z)
				if nev < 8:
					ev_x[ebase + nev] = x
					ev_z[ebase + nev] = z
					ev_k[ebase + nev] = 1
					nev += 1
				continue
			if tm == 0:
				al0 += 1
			else:
				al1 += 1
			var samp := (i & 63) == 0
			if samp:
				q0 = Time.get_ticks_usec()

			# ---- neighbours: separation + nearest enemy (uniform grid, 3x3 cells)
			var gx := int((x + HALF) * INV_CELL)
			var gz := int((z + HALF) * INV_CELL)
			var sepx := 0.0
			var sepz := 0.0
			var best := -1
			var bestd := 1e9
			var touch := false
			for cz in range(gz - 1, gz + 2):
				var row := cz << 9
				for cx in range(gx - 1, gx + 2):
					var cell := row + cx
					var n := gcnt_r[cell]
					if n == 0:
						continue
					if n > 4:
						n = 4
					var s0 := cell << 2
					for s in range(s0, s0 + n):
						var j := gslot_r[s]
						if j == i:
							continue
						var dx := x - px[j]
						var dz := z - pz[j]
						var d2 := dx * dx + dz * dz
						var rr := (myr + rad[j]) * 1.15
						if d2 < rr * rr and d2 > 0.0001:
							var d := sqrt(d2)
							var f := (rr - d) / d
							sepx += dx * f
							sepz += dz * f
							if order[j] == 0:
								touch = true
						if team[j] != tm and d2 < bestd:
							bestd = d2
							best = j
			if samp:
				q1 = Time.get_ticks_usec()

			# ---- brain: melee / ranged / orders
			var fc := ((gz >> 1) << 8) | (gx >> 1)
			var ef := tm << 16
			var ed := FDIST[ef + fc]
			var wx := 0.0
			var wz := 0.0
			var want := 0.0
			var fx := dirx[i]
			var fz := dirz[i]
			var tfx := 0.0
			var tfz := 0.0
			var nst := 1
			var cdn := cd[i] - dt
			var engaged := false
			var v_x := vx[i]
			var v_z := vz[i]
			if best >= 0 and state[best] != 4:
				var reach := myr + rad[best] + 0.75
				var inv := 1.0 / sqrt(bestd + 0.0001)
				tfx = (px[best] - x) * inv
				tfz = (pz[best] - z) * inv
				if bestd < reach * reach:
					engaged = true
					if cdn <= 0.0:
						var dd := dmg
						if ct == 2:
							dd *= 1.0 + sqrt(v_x * v_x + v_z * v_z) * 0.16
						hp[best] -= dd
						hit_t[best] = now
						cdn = cdp * (0.85 + useed[i] * 0.3)
						st_time[i] = now
						if nev < 8 and ((i + tk) & 7) == 0:
							ev_x[ebase + nev] = x + tfx * 0.8
							ev_z[ebase + nev] = z + tfz * 0.8
							ev_k[ebase + nev] = 2
							nev += 1
					if now - st_time[i] < 0.7:
						nst = 3
				elif rng_m == 0.0:
					wx = tfx
					wz = tfz
					want = 1.0
			if rng_m > 0.0 and not engaged:
				var rt := tgt[i]
				var ok := false
				if rt >= 0:
					var s2 := state[rt]
					if s2 != 0 and s2 != 4 and team[rt] != tm:
						var ddx := px[rt] - x
						var ddz := pz[rt] - z
						if ddx * ddx + ddz * ddz < rng2:
							ok = true
				if not ok and ((i + tk) & 3) == 0 and ed < rng_cells:
					# walk the enemy flow field towards the nearest enemy cell, look for a representative unit
					var cc := fc
					var eo := (1 - tm) << 16
					for step in 26:
						var j := rep[eo + cc]
						if j >= 0:
							var s2 := state[j]
							if s2 != 0 and s2 != 4 and team[j] != tm:
								var ddx := px[j] - x
								var ddz := pz[j] - z
								if ddx * ddx + ddz * ddz < rng2:
									rt = j
									ok = true
									break
						cc = FNEXT[ef + cc]
						if cc < 0:
							break
				if ok:
					var ddx := px[rt] - x
					var ddz := pz[rt] - z
					var inv := 1.0 / sqrt(ddx * ddx + ddz * ddz + 0.0001)
					tfx = ddx * inv
					tfz = ddz * inv
					tgt[i] = rt
					engaged = true
					if cdn <= 0.0:
						flist[a + nfire] = i
						nfire += 1
						cdn = cdp * (0.8 + useed[i] * 0.4)
						st_time[i] = now
					if now - st_time[i] < 0.9:
						nst = 3
				else:
					tgt[i] = -1
			if not engaged and want == 0.0:
				var ord := order[i]
				if ord == 3 or (ord != 1 and ed < AGGRO):
					if rng_m == 0.0 or ed > rng_cells - 3.0:
						wx = FDX[ef + fc]
						wz = FDZ[ef + fc]
						want = 1.0
				elif ord != 0:
					var of := ofield[i] << 16
					var gd := FDIST[of + fc]
					var ar := arrive[i]
					if gd <= ar or (touch and form[i] == 0 and gd <= ar * 2.0 + 3.0):
						order[i] = 0
						if form[i] == 0:
							hx[i] = x
							hz[i] = z
					else:
						wx = FDX[of + fc]
						wz = FDZ[of + fc]
						want = 1.0
				else:
					var ddx := hx[i] - x
					var ddz := hz[i] - z
					var d2 := ddx * ddx + ddz * ddz
					if d2 > 0.6:
						var d := sqrt(d2)
						wx = ddx / d
						wz = ddz / d
						want = minf(1.0, d * 0.3)
			if samp:
				q2 = Time.get_ticks_usec()

			# ---- steering, integration, obstacle slide
			var cst := cost[fc]
			# queueing: allies overlapping ahead slow this unit down instead of letting it push into them
			var press := -(sepx * wx + sepz * wz)
			if press > 0.0:
				want /= 1.0 + press * 12.0
			var sp := spd0 * want
			if cst == 2:
				sp *= 0.62
			var tvx := wx * sp + sepx * 1.2
			var tvz := wz * sp + sepz * 1.2
			v_x += (tvx - v_x) * acc
			v_z += (tvz - v_z) * acc
			var sl := sepx * sepx + sepz * sepz
			if sl > 1.6:
				sl = 1.265 / sqrt(sl)
				sepx *= sl
				sepz *= sl
			var nx := x + v_x * dt + sepx * 0.3
			var nz := z + v_z * dt + sepz * 0.3
			if nx < -297.0: nx = -297.0
			elif nx > 297.0: nx = 297.0
			if nz < -297.0: nz = -297.0
			elif nz > 297.0: nz = 297.0
			if cst != 255:
				var nfc := (int((nz + HALF) * 0.4) << 8) | int((nx + HALF) * 0.4)
				if cost[nfc] == 255:
					if cost[(int((z + HALF) * 0.4) << 8) | int((nx + HALF) * 0.4)] != 255:
						nz = z
						v_z = 0.0
					elif cost[(int((nz + HALF) * 0.4) << 8) | int((x + HALF) * 0.4)] != 255:
						nx = x
						v_x = 0.0
					else:
						nx = x
						nz = z
						v_x = 0.0
						v_z = 0.0
			else:
				nx = x + FDX[ef + fc] * 3.0 * dt
				nz = z + FDZ[ef + fc] * 3.0 * dt
			var s2 := v_x * v_x + v_z * v_z
			var spd := sqrt(s2)
			if engaged:
				fx += (tfx - fx) * 0.4
				fz += (tfz - fz) * 0.4
			elif s2 > 0.5 and want > 0.0:
				fx += (v_x / spd - fx) * 0.3
				fz += (v_z / spd - fz) * 0.3
			var fl := fx * fx + fz * fz
			if fl > 0.0001:
				fl = 1.0 / sqrt(fl)
				fx *= fl
				fz *= fl
			else:
				fx = 1.0
				fz = 0.0
			if nst != 3 and s2 > 0.4:
				nst = 2
			px[i] = nx
			pz[i] = nz
			vx[i] = v_x
			vz[i] = v_z
			dirx[i] = fx
			dirz[i] = fz
			cd[i] = cdn
			state[i] = nst
			if first:
				buf[o] = x
				buf[o + 1] = z
				buf[o + 4] = buf[o + 6]
				buf[o + 5] = buf[o + 7]
			buf[o + 2] = nx
			buf[o + 3] = nz
			buf[o + 6] = fx
			buf[o + 7] = fz
			buf[o + 8] = float(nst)
			buf[o + 9] = st_time[i]
			buf[o + 10] = hit_t[i]
			buf[o + 11] = spd

			# ---- publish into next tick's grid, the minimap and the ground trail
			var ngx := int((nx + HALF) * INV_CELL)
			var ngz := int((nz + HALF) * INV_CELL)
			var ncell := (ngz << 9) + ngx
			var k := gcnt_w[ncell]
			gcnt_w[ncell] = k + 1
			if k < 4:
				gslot_w[(ncell << 2) + k] = i
			var nf := ((ngz >> 1) << 8) | (ngx >> 1)
			rep[(tm << 16) + nf] = i
			mmb[nf] = tm + 1
			if nst == 2:
				var si := (((int((nz + HALF) * 1.6) << 10) + int((nx + HALF) * 1.6)) << 1) | 1
				var tv := stain[si]
				if tv < 150:
					stain[si] = tv + 3
				if nev < 8 and ((i * 7 + tk * 13) & 1023) < 3:
					ev_x[ebase + nev] = nx
					ev_z[ebase + nev] = nz
					ev_k[ebase + nev] = 0
					nev += 1
			if samp:
				var q3 := Time.get_ticks_usec()
				pa += q1 - q0
				pb += q2 - q1
				pc += q3 - q2
	fcnt[c] = nfire
	ecnt[c] = nev
	ch_alive[c << 1] = al0
	ch_alive[(c << 1) | 1] = al1
	ch_box[c << 2] = bx0
	ch_box[(c << 2) | 1] = bz0
	ch_box[(c << 2) | 2] = bx1
	ch_box[(c << 2) | 3] = bz1
	ch_prof[c << 2] = pa
	ch_prof[(c << 2) | 1] = pb
	ch_prof[(c << 2) | 2] = pc


func _h(x: float, z: float) -> float:
	return hmap[(((int((z + HALF) * 1.6)) << 10) + int((x + HALF) * 1.6)) * 2 + 1]


func _puff(x: float, z: float, kind: float, size: float, life: float) -> void:
	var o := p_head * 12
	p_head = (p_head + 1) & (PUFF_N - 1)
	pbuf[o] = x
	pbuf[o + 1] = _h(x, z)
	pbuf[o + 2] = z
	pbuf[o + 3] = sim_time
	pbuf[o + 4] = size
	pbuf[o + 5] = kind
	pbuf[o + 6] = rng.randf()
	pbuf[o + 7] = life


func _serial() -> void:
	var a0 := 0
	var a1 := 0
	var now := sim_time
	var am := arrow_n - 1
	for c in nchunks:
		a0 += ch_alive[c << 1]
		a1 += ch_alive[(c << 1) | 1]
		acc_prof[0] += ch_prof[c << 2]
		acc_prof[1] += ch_prof[(c << 2) | 1]
		acc_prof[2] += ch_prof[(c << 2) | 2]
		var n := fcnt[c]
		var base := c << 9
		for k in n:
			var i := flist[base + k]
			var j := tgt[i]
			if j < 0:
				continue
			var sx := px[i]
			var sz := pz[i]
			var dx := px[j] - sx
			var dz := pz[j] - sz
			var dist := sqrt(dx * dx + dz * dz)
			var ft := dist / 34.0 + 0.4
			var tx := px[j] + vx[j] * ft * 0.8 + rng.randf_range(-1.3, 1.3)
			var tz := pz[j] + vz[j] * ft * 0.8 + rng.randf_range(-1.3, 1.3)
			var o := a_head * 12
			a_head = (a_head + 1) & am
			abuf[o] = sx
			abuf[o + 1] = sz
			abuf[o + 2] = tx
			abuf[o + 3] = tz
			abuf[o + 4] = now
			abuf[o + 5] = ft
			abuf[o + 6] = 1.5 + dist * 0.17
			abuf[o + 7] = rng.randf()
			var bk := (tick + int(ft / TICK) + 1) & 127
			b_tgt[bk].append(j)
			b_pos[bk].append(tx)
			b_pos[bk].append(tz)
		n = ecnt[c]
		base = c << 3
		for k in n:
			var kind := ev_k[base + k]
			if kind == 0:
				_puff(ev_x[base + k], ev_z[base + k], 0.0, rng.randf_range(2.2, 4.2), rng.randf_range(2.0, 3.6))
			elif kind == 1:
				_puff(ev_x[base + k], ev_z[base + k], 1.0, rng.randf_range(1.0, 1.7), 0.55)
				_puff(ev_x[base + k], ev_z[base + k], 0.0, rng.randf_range(2.0, 3.0), 1.8)
			else:
				_puff(ev_x[base + k], ev_z[base + k], 2.0, rng.randf_range(0.35, 0.6), 0.16)
	alive[0] = a0
	alive[1] = a1
	var bk := tick & 127
	var bt := b_tgt[bk]
	var bp := b_pos[bk]
	for k in bt.size():
		var j := bt[k]
		var st := state[j]
		var tx := bp[k * 2]
		var tz := bp[k * 2 + 1]
		if st != 0 and st != 4:
			var dx := px[j] - tx
			var dz := pz[j] - tz
			if dx * dx + dz * dz < 5.0:
				hp[j] -= ARROW_DMG if rad[j] < 0.6 else ARROW_DMG * 0.6
				hit_t[j] = now
				continue
		if (k & 3) == 0:
			_puff(tx, tz, 0.0, 1.2, 0.9)
	b_tgt[bk] = PackedInt32Array()
	b_pos[bk] = PackedFloat32Array()


# ---------------------------------------------------------------- flow-field thread

func _flow_loop() -> void:
	var turn := 0
	while not quit:
		var req = null
		flow_mutex.lock()
		if flow_req.size() > 0:
			req = flow_req.pop_front()
		flow_mutex.unlock()
		if req != null:
			var slot: int = req[0]
			var goal: Vector2 = req[1]
			var ids: PackedInt32Array = req[2]
			var src := _goal_cells(goal, req[4])
			_compute(slot, src)
			var arr := sqrt(float(ids.size()) * 1.5 / PI) / 2.5 * 0.7
			if not is_nan(req[5]):
				arr = 12.0
			flow_mutex.lock()
			flow_done.append([ids, req[3], slot, arr, req[5]])
			flow_mutex.unlock()
			continue
		if alive[0] > 0 and alive[1] > 0:
			var t0 := Time.get_ticks_usec()
			_compute(turn, _enemy_cells(turn))
			flow_ms = lerpf(flow_ms, float(Time.get_ticks_usec() - t0) * 0.001, 0.2)
			flow_count += 1
			turn = 1 - turn
		OS.delay_msec(12)


func _goal_cells(goal: Vector2, half_len: float) -> PackedInt32Array:
	var gx := clampi(int((goal.x + HALF) * 0.4), 2, 253)
	var out := PackedInt32Array()
	if half_len > 0.0:
		for gz in range(clampi(int((goal.y - half_len + HALF) * 0.4), 2, 253), clampi(int((goal.y + half_len + HALF) * 0.4), 2, 253) + 1):
			if cost[gz * 256 + gx] != 255:
				out.append(gz * 256 + gx)
		if out.size() > 0:
			return out
	var gz := clampi(int((goal.y + HALF) * 0.4), 2, 253)
	for r in 40:
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var cx := gx + dx
				var cz := gz + dz
				if cx < 1 or cx > 254 or cz < 1 or cz > 254:
					continue
				if cost[cz * 256 + cx] != 255:
					out.append(cz * 256 + cx)
		if out.size() > 0:
			break
	return out


func _enemy_cells(tm: int) -> PackedInt32Array:
	s_mark.fill(0)
	var out := PackedInt32Array()
	for t in NT:
		for i in range(t_start[t], t_hi[t]):
			var st := state[i]
			if st == 0 or st == 4 or team[i] == tm:
				continue
			var c := (int((pz[i] + HALF) * 0.4) << 8) | int((px[i] + HALF) * 0.4)
			if s_mark[c] == 0:
				s_mark[c] = 1
				out.append(c)
	return out


## cost field -> integration field (label-correcting wavefront) -> flow field
func _compute(k: int, src: PackedInt32Array) -> void:
	s_dist.fill(BIG)
	s_inq.fill(0)
	var head := 0
	var tail := 0
	for c in src:
		if cost[c] != 255:
			s_dist[c] = 0
			s_q[tail] = c
			tail = (tail + 1) & 65535
			s_inq[c] = 1
	while head != tail:
		var c := s_q[head]
		head = (head + 1) & 65535
		s_inq[c] = 0
		var d := s_dist[c]
		for kk in 8:
			var n := c + NOFF[kk]
			var cn := cost[n]
			if cn == 255:
				continue
			if kk >= 4 and (cost[c + NOA[kk]] == 255 or cost[c + NOB[kk]] == 255):
				continue
			var nd := d + cn * NCST[kk]
			if nd < s_dist[n]:
				s_dist[n] = nd
				if s_inq[n] == 0:
					s_inq[n] = 1
					s_q[tail] = n
					tail = (tail + 1) & 65535
	# Eikonal refinement (fast sweeping, seeded by the wavefront result): removes the 8-direction bias,
	# so streams stay as wide as the gap they came through instead of collapsing into lanes.
	for c in FN:
		var d := s_dist[c]
		s_t[c] = float(d) * 0.1 if d < BIG else 1e6
	for sweep in 4:
		for zi in 254:
			var z := (1 + zi) if (sweep & 2) == 0 else (254 - zi)
			var row := z << 8
			for xi in 254:
				var c := row + ((1 + xi) if (sweep & 1) == 0 else (254 - xi))
				var cn := cost[c]
				if cn == 255:
					continue
				var tc := s_t[c]
				var a := minf(s_t[c - 1], s_t[c + 1])
				var b := minf(s_t[c - 256], s_t[c + 256])
				var lo := minf(a, b)
				if lo >= tc:
					continue
				var f := float(cn)
				var df := absf(a - b)
				var t := lo + f
				if df < f:
					t = (a + b + sqrt(2.0 * f * f - df * df)) * 0.5
				if t < tc:
					s_t[c] = t
	var base := k << 16
	for c in range(257, 65536 - 257):
		var tc := s_t[c]
		var blocked := cost[c] == 255
		var best := tc
		var bn := -1
		for kk in 8:
			var n := c + NOFF[kk]
			var tn := s_t[n]
			if tn < best:
				if kk >= 4 and not blocked and (cost[c + NOA[kk]] == 255 or cost[c + NOB[kk]] == 255):
					continue
				best = tn
				bn = n
		var dx := 0.0
		var dz := 0.0
		if bn >= 0:
			if not blocked:
				var l := s_t[c - 1]
				var r := s_t[c + 1]
				var u := s_t[c - 256]
				var dn := s_t[c + 256]
				if l < r:
					if l < tc:
						dx = l - tc
				elif r < tc:
					dx = tc - r
				if u < dn:
					if u < tc:
						dz = u - tc
				elif dn < tc:
					dz = tc - dn
			if dx == 0.0 and dz == 0.0:
				dx = float((bn & 255) - (c & 255))
				dz = float((bn >> 8) - (c >> 8))
			var gl := 1.0 / sqrt(dx * dx + dz * dz)
			dx *= gl
			dz *= gl
		FDX[base + c] = dx
		FDZ[base + c] = dz
		FDIST[base + c] = tc
		FNEXT[base + c] = bn
