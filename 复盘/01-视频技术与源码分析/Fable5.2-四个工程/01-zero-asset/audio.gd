extends Node
# Everything audible is synthesised here.
#  - SFX: rendered once at boot into AudioStreamWAV buffers (pure maths, no files).
#  - Music: a generative step sequencer rendered on a worker thread into an AudioStreamGenerator.
#    Voices: pad (6 saws + LP), filtered bass, pluck arp, lead, kick, hat, snare, drone.

const SR := 22050
const MR := 32000

var sfx := {}
var stats := {}
var players: Array = []
var pi := 0
var last_play := {}
var loops := {}
var music_player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var intensity := 0            # 0 calm, 1 explore, 2 swarm, 3 boss
var thread: Thread
var mutex := Mutex.new()
var queue: Array = []
var running := true
var m_peak := 0.0
var m_sq := 0.0
var m_n := 0
var pushed := 0
var m_usec := 0
var m_steps := 0
var bus_peak := -100.0
var rng := RandomNumberGenerator.new()
var clock := 0.0

# --- sequencer state (worker thread only)
var mr := RandomNumberGenerator.new()
var step := 0
var bar := 0
var pad_ph := PackedFloat32Array([0, 0.3, 0.5, 0.7, 0.1, 0.9])
var pad_inc := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var pad_amp := 0.0
var pad_lp := 0.0
var pad_lp2 := 0.0
var bass_ph := 0.0
var bass_f := 55.0
var bass_env := 0.0
var bass_y1 := 0.0
var bass_y2 := 0.0
var arp_ph := 0.0
var arp_f := 440.0
var arp_env := 0.0
var arp_pan := 0.5
var lead_ph := 0.0
var lead_f := 220.0
var lead_tf := 220.0
var lead_env := 0.0
var lead_gate := false
var lead_y := 0.0
var kick_t := 9.0
var kick_ph := 0.0
var hat_env := 0.0
var hat_prev := 0.0
var sn_env := 0.0
var sn_ph := 0.0
var drone_ph := 0.0
var drone_ph2 := 0.0
var lfo := 0.0
var arp_idx := 2
var cur_int := 0.0

const ROOTS := [38, 34, 31, 33]            # D2 Bb1 G1 A1
const CHORDS := [[0, 3, 7], [0, 4, 7], [0, 3, 7], [0, 4, 7]]
const SCALE := [0, 2, 3, 5, 7, 8, 10]


func build() -> void:
	rng.seed = 77
	_setup_buses()
	_make_sfx()
	for i in 26:
		var p := AudioStreamPlayer3D.new()
		p.bus = &"SFX"
		p.unit_size = 14.0
		p.max_distance = 500.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.panning_strength = 0.6
		add_child(p)
		players.append(p)
	for n in ["beam", "wind"]:
		var lp := AudioStreamPlayer.new()
		lp.stream = sfx[n]
		lp.bus = &"SFX"
		lp.volume_db = -60.0
		add_child(lp)
		loops[n] = {"p": lp, "vol": -60.0, "target": -60.0, "on_db": (-9.0 if n == "beam" else -17.0)}
	loop("wind", true)
	music_player = AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MR
	gen.buffer_length = 0.7
	music_player.stream = gen
	music_player.bus = &"Music"
	music_player.volume_db = -5.0
	add_child(music_player)
	music_player.play()
	playback = music_player.get_stream_playback()
	mr.seed = 2024
	thread = Thread.new()
	thread.start(_music_loop)


func _setup_buses() -> void:
	if AudioServer.get_bus_index(&"Music") >= 0:
		return
	AudioServer.add_bus()
	var mi := AudioServer.bus_count - 1
	AudioServer.set_bus_name(mi, &"Music")
	AudioServer.set_bus_send(mi, &"Master")
	var dl := AudioEffectDelay.new()
	dl.tap1_active = true
	dl.tap1_delay_ms = 326.0
	dl.tap1_level_db = -10.0
	dl.tap1_pan = -0.6
	dl.tap2_active = true
	dl.tap2_delay_ms = 489.0
	dl.tap2_level_db = -13.0
	dl.tap2_pan = 0.6
	dl.feedback_active = true
	dl.feedback_delay_ms = 489.0
	dl.feedback_level_db = -9.0
	AudioServer.add_bus_effect(mi, dl)
	var rv := AudioEffectReverb.new()
	rv.room_size = 0.85
	rv.damping = 0.4
	rv.wet = 0.28
	rv.dry = 0.85
	rv.spread = 1.0
	AudioServer.add_bus_effect(mi, rv)
	AudioServer.add_bus()
	var si := AudioServer.bus_count - 1
	AudioServer.set_bus_name(si, &"SFX")
	AudioServer.set_bus_send(si, &"Master")
	var rv2 := AudioEffectReverb.new()
	rv2.room_size = 0.6
	rv2.damping = 0.5
	rv2.wet = 0.12
	rv2.dry = 0.95
	AudioServer.add_bus_effect(si, rv2)
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -0.6
	lim.pre_gain_db = 0.0
	AudioServer.add_bus_effect(0, lim)


func _exit_tree() -> void:
	running = false
	if thread != null and thread.is_started():
		thread.wait_to_finish()


func play(n: String, pos: Vector3, vol_db := 0.0, pitch := 1.0) -> void:
	var lt: float = last_play.get(n, -1.0)
	if clock - lt < 0.035:
		return
	last_play[n] = clock
	var p: AudioStreamPlayer3D = players[pi]
	pi = (pi + 1) % players.size()
	p.stream = sfx[n]
	p.global_position = pos
	p.volume_db = vol_db
	p.pitch_scale = pitch
	p.play()


func loop(n: String, on: bool) -> void:
	var l: Dictionary = loops[n]
	l.target = l.on_db if on else -60.0
	var p: AudioStreamPlayer = l.p
	if on and not p.playing:
		p.play()


func _process(dt: float) -> void:
	clock += dt
	for n in loops:
		var l: Dictionary = loops[n]
		l.vol = move_toward(l.vol, l.target, dt * 160.0)
		var p: AudioStreamPlayer = l.p
		p.volume_db = l.vol
		if l.vol <= -59.0 and l.target <= -59.0 and p.playing and n != "wind":
			p.stop()
	# feed the generator from the worker queue
	if playback != null:
		while true:
			mutex.lock()
			var chunk = queue[0] if queue.size() > 0 else null
			if chunk != null and playback.can_push_buffer(chunk.size()):
				queue.pop_front()
				mutex.unlock()
				playback.push_buffer(chunk)
				pushed += chunk.size()
			else:
				mutex.unlock()
				break
	bus_peak = maxf(bus_peak, AudioServer.get_bus_peak_volume_left_db(0, 0))


func report() -> String:
	var s := "audio: %d sfx | " % sfx.size()
	var worst := 0.0
	var silent := 0
	for n in stats:
		worst = maxf(worst, stats[n].peak)
		if stats[n].rms < 0.01:
			silent += 1
	s += "sfx peak max %.2f, silent buffers %d | music frames pushed %d, skips %d, peak %.2f, rms %.3f, render %.1f ms per %.0f ms step | master bus peak %.1f dB" % [
		worst, silent, pushed, playback.get_skips() if playback != null else -1, m_peak, sqrt(m_sq / maxf(m_n, 1)), m_usec / 1000.0 / maxf(m_steps, 1), 1000.0 * m_n / MR / maxf(m_steps, 1), bus_peak]
	return s


# ------------------------------------------------------------------ SFX synthesis

func _wav(n: String, s: PackedFloat32Array, looped := false, gain := 0.9) -> void:
	var peak := 0.0001
	var sq := 0.0
	for v in s:
		peak = maxf(peak, absf(v))
		sq += v * v
	var k := gain / peak
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i] * k, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = data
	if looped:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = s.size()
	sfx[n] = w
	stats[n] = {"peak": gain, "rms": sqrt(sq / s.size()) * k, "len": float(s.size()) / SR}


func _buf(sec: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(sec * SR))
	return b


func _make_sfx() -> void:
	var dt := 1.0 / SR
	# footstep: hydraulic thump + click + servo
	var b := _buf(0.24)
	var ph := 0.0
	var lp := 0.0
	for i in b.size():
		var t := i * dt
		ph += (48.0 + 90.0 * exp(-t * 30.0)) * dt
		lp += 0.25 * ((rng.randf() * 2.0 - 1.0) - lp)
		b[i] = sin(ph * TAU) * exp(-t * 20.0) + lp * exp(-t * 55.0) * 0.7 + sin(TAU * (500.0 + 2600.0 * t) * t) * 0.06 * exp(-t * 14.0)
	_wav("step", b)
	# boss footfall
	b = _buf(0.7)
	ph = 0.0
	lp = 0.0
	for i in b.size():
		var t := i * dt
		ph += (30.0 + 55.0 * exp(-t * 16.0)) * dt
		lp += 0.06 * ((rng.randf() * 2.0 - 1.0) - lp)
		b[i] = sin(ph * TAU) * exp(-t * 7.0) + lp * exp(-t * 9.0) * 2.5
	_wav("stomp", b)
	# cannon shot
	b = _buf(0.26)
	ph = 0.0
	for i in b.size():
		var t := i * dt
		ph += (180.0 + 1500.0 * exp(-t * 22.0)) * dt
		var saw := fmod(ph, 1.0) * 2.0 - 1.0
		var sq := 1.0 if fmod(ph * 0.5, 1.0) < 0.5 else -1.0
		b[i] = (saw * 0.6 + sq * 0.4) * exp(-t * 15.0) + (rng.randf() * 2.0 - 1.0) * exp(-t * 70.0) * 0.6
	_wav("shot", b)
	# beam loop (integer frequencies -> seamless 1 s loop)
	b = _buf(1.0)
	for i in b.size():
		var t := i * dt
		var trem := 0.75 + 0.25 * sin(TAU * 17.0 * t)
		b[i] = (sin(TAU * 220.0 * t + 2.5 * sin(TAU * 55.0 * t)) * 0.5 + sin(TAU * 441.0 * t + sin(TAU * 110.0 * t)) * 0.25 + sin(TAU * 1320.0 * t) * 0.06) * trem
	_wav("beam", b, true, 0.7)
	# explosions
	for big in [false, true]:
		b = _buf(2.6 if big else 1.0)
		ph = 0.0
		lp = 0.0
		var lp2 := 0.0
		var dec := 2.2 if big else 5.5
		for i in b.size():
			var t := i * dt
			var a := 0.02 + 0.5 * exp(-t * (5.0 if big else 9.0))
			lp += a * ((rng.randf() * 2.0 - 1.0) - lp)
			lp2 += a * (lp - lp2)
			ph += (28.0 + 70.0 * exp(-t * 8.0)) * dt
			var crack := (rng.randf() * 2.0 - 1.0) * (1.0 if rng.randf() < 0.004 else 0.0) * exp(-t * 1.5)
			b[i] = lp2 * 3.0 * exp(-t * dec) + sin(ph * TAU) * exp(-t * dec * 1.2) * 0.9 + crack * 0.5 + (rng.randf() * 2.0 - 1.0) * exp(-t * 80.0) * 0.5
		_wav("boom_big" if big else "boom", b)
	# creature chirp
	b = _buf(0.28)
	ph = 0.0
	for i in b.size():
		var t := i * dt
		ph += (1900.0 - 3200.0 * t + 500.0 * sin(TAU * 62.0 * t)) * dt
		var env := pow(absf(sin(t * 34.0)), 2.0) * exp(-t * 7.0)
		b[i] = sin(ph * TAU) * env
	_wav("chirp", b, false, 0.6)
	# creature death squelch
	b = _buf(0.34)
	ph = 0.0
	lp = 0.0
	for i in b.size():
		var t := i * dt
		ph += (520.0 * exp(-t * 9.0) + 70.0) * dt
		lp += (0.5 * exp(-t * 10.0) + 0.03) * ((rng.randf() * 2.0 - 1.0) - lp)
		b[i] = sin(ph * TAU) * exp(-t * 11.0) * 0.7 + lp * exp(-t * 9.0) * 1.6
	_wav("squish", b)
	# boss roar
	b = _buf(3.0)
	ph = 0.0
	lp = 0.0
	var lpb := 0.0
	for i in b.size():
		var t := i * dt
		var f := 62.0 - 9.0 * t + 14.0 * sin(TAU * 21.0 * t) * (0.4 + 0.2 * t)
		ph += f * dt
		var x := (fmod(ph, 1.0) * 2.0 - 1.0) + (fmod(ph * 1.503, 1.0) * 2.0 - 1.0) * 0.7 + (fmod(ph * 2.02, 1.0) * 2.0 - 1.0) * 0.5
		x *= 0.6 + 0.4 * sin(TAU * 31.0 * t)
		x += (rng.randf() * 2.0 - 1.0) * 0.5
		var cut := 0.03 + 0.25 * sin(clampf(t / 2.6, 0.0, 1.0) * PI)
		lp += cut * (x - lp)
		lpb += cut * (lp - lpb)
		var env := smoothstep(0.0, 0.35, t) * (1.0 - smoothstep(2.0, 3.0, t))
		b[i] = lpb * env
	_wav("roar", b)
	# core pickup chime
	b = _buf(1.1)
	var notes := [880.0, 1108.7, 1318.5, 1760.0, 2217.5]
	for i in b.size():
		var t := i * dt
		var s := 0.0
		for k in notes.size():
			var tt := t - k * 0.065
			if tt > 0.0:
				s += (sin(TAU * notes[k] * tt) + 0.35 * sin(TAU * notes[k] * 2.01 * tt)) * exp(-tt * 5.5)
		b[i] = s
	_wav("pickup", b, false, 0.6)
	# hull hit
	b = _buf(0.32)
	ph = 0.0
	for i in b.size():
		var t := i * dt
		ph += (210.0 - 330.0 * t) * dt
		b[i] = (1.0 if fmod(ph, 1.0) < 0.5 else -1.0) * exp(-t * 11.0) * 0.6 + (rng.randf() * 2.0 - 1.0) * exp(-t * 28.0)
	_wav("hurt", b, false, 0.8)
	# boss spit
	b = _buf(0.4)
	ph = 0.0
	lp = 0.0
	for i in b.size():
		var t := i * dt
		ph += (240.0 + 900.0 * t) * dt
		var nz := rng.randf() * 2.0 - 1.0
		lp += 0.3 * (nz - lp)
		b[i] = (nz - lp) * sin(clampf(t / 0.4, 0.0, 1.0) * PI) * 0.6 + sin(ph * TAU) * exp(-t * 8.0) * 0.5
	_wav("spit", b, false, 0.7)
	# wind loop (crossfaded ends)
	var n := int(6.0 * SR)
	var fade := int(0.6 * SR)
	var raw := PackedFloat32Array()
	raw.resize(n + fade)
	lp = 0.0
	var lp3 := 0.0
	for i in raw.size():
		var t := i * dt
		var cut := 0.012 + 0.02 * (0.5 + 0.5 * sin(TAU * t / 6.0)) + 0.012 * (0.5 + 0.5 * sin(TAU * t / 2.0 + 1.0))
		lp += cut * ((rng.randf() * 2.0 - 1.0) - lp)
		lp3 += cut * (lp - lp3)
		raw[i] = lp3 * (0.7 + 0.3 * sin(TAU * t / 3.0))
	b = _buf(6.0)
	for i in n:
		var v := raw[i]
		if i < fade:
			var k := float(i) / fade
			v = v * k + raw[n + i] * (1.0 - k)
		b[i] = v
	_wav("wind", b, true, 0.8)
	# ui blip
	b = _buf(0.12)
	for i in b.size():
		var t := i * dt
		b[i] = sin(TAU * 990.0 * t) * exp(-t * 30.0) + sin(TAU * 1485.0 * t) * exp(-t * 40.0) * 0.5
	_wav("ui", b, false, 0.5)


# ------------------------------------------------------------------ generative music

func _music_loop() -> void:
	while running:
		mutex.lock()
		var qn := queue.size()
		mutex.unlock()
		if qn < 3:
			var t0 := Time.get_ticks_usec()
			var chunk := _render_step()
			m_usec += Time.get_ticks_usec() - t0
			m_steps += 1
			mutex.lock()
			queue.append(chunk)
			mutex.unlock()
		else:
			OS.delay_msec(8)


func _mtof(m: float) -> float:
	return 440.0 * pow(2.0, (m - 69.0) / 12.0)


func _render_step() -> PackedVector2Array:
	var lvl := intensity
	cur_int = lerpf(cur_int, float(lvl), 0.25)
	var bpm := 92.0 if lvl < 2 else (104.0 if lvl == 2 else 118.0)
	var n := int(MR * 60.0 / bpm / 4.0)
	var inv := 1.0 / MR
	var s16 := step % 16
	if s16 == 0:
		bar += 1
	var ci := (bar / 2) % 4
	var root: int = ROOTS[ci]
	var chord: Array = CHORDS[ci]
	# --- note events
	for k in 3:
		var f := _mtof(root + 12 + chord[k] + (12 if k == 1 else 0))
		pad_inc[k * 2] = f * 0.997 * inv
		pad_inc[k * 2 + 1] = f * 1.004 * inv
	var pad_target := 0.11 if lvl < 3 else 0.085
	var kick := false
	var hat := 0.0
	var snare := 0.0
	if lvl == 1:
		kick = s16 == 0 or s16 == 10
		hat = 0.25 if s16 % 4 == 2 else 0.0
		if s16 == 0 or s16 == 6 or s16 == 10:
			bass_f = _mtof(root)
			bass_env = 0.8
	elif lvl == 2:
		kick = s16 % 4 == 0 or s16 == 14
		hat = 0.5 if s16 % 2 == 0 else 0.22
		snare = 0.7 if s16 == 4 or s16 == 12 else 0.0
		if s16 % 2 == 0 or s16 == 15:
			bass_f = _mtof(root + (12 if s16 % 8 == 6 else 0))
			bass_env = 1.0
	elif lvl >= 3:
		kick = s16 % 4 == 0 or s16 == 7 or s16 == 14
		hat = 0.55 if s16 % 4 == 2 else 0.3
		snare = 0.9 if s16 == 4 or s16 == 12 else (0.35 if s16 == 15 and mr.randf() < 0.5 else 0.0)
		bass_f = _mtof(root + (12 if s16 % 4 == 3 else 0) + (7 if s16 == 13 else 0))
		bass_env = 1.0
		# lead motif, 2-bar phrase
		var motif := [0, -1, -1, 3, -1, 2, 0, -1, 7, -1, -1, 5, -1, 3, 2, -1]
		var mv: int = motif[s16]
		if mv >= 0:
			lead_tf = _mtof(root + 36 + mv + (0 if bar % 2 == 0 else (2 if mv == 7 else 0)))
			lead_env = 1.0
			lead_gate = true
		elif s16 % 4 == 2:
			lead_gate = false
	if kick:
		kick_t = 0.0
		kick_ph = 0.0
	if hat > 0.0:
		hat_env = hat
	if snare > 0.0:
		sn_env = snare
	# arp: random walk over the scale, denser with intensity
	var dens: float = [0.22, 0.45, 0.7, 0.9][lvl]
	if (s16 % 2 == 0 or lvl >= 2) and mr.randf() < dens:
		arp_idx = clampi(arp_idx + mr.randi_range(-2, 2), 0, 13)
		if mr.randf() < 0.3:
			arp_idx = [0, 2, 4, 7, 9, 11][mr.randi() % 6]
		var deg: int = SCALE[arp_idx % 7] + 12 * (arp_idx / 7)
		arp_f = _mtof(62 + deg + (12 if lvl == 3 and s16 % 4 == 1 else 0))
		arp_env = 0.5 + 0.5 * mr.randf()
		arp_pan = 0.2 + 0.6 * mr.randf()
	var drone_inc := _mtof(38) * inv
	var bass_inc := bass_f * inv
	var arp_inc := arp_f * inv
	var bass_gain := 0.0 if lvl == 0 else (0.30 if lvl == 1 else 0.36)
	var drive := 1.0 + cur_int * 0.6
	var out := PackedVector2Array()
	out.resize(n)
	var p0 := pad_ph[0]; var p1 := pad_ph[1]; var p2 := pad_ph[2]; var p3 := pad_ph[3]; var p4 := pad_ph[4]; var p5 := pad_ph[5]
	var i0 := pad_inc[0]; var i1 := pad_inc[1]; var i2 := pad_inc[2]; var i3 := pad_inc[3]; var i4 := pad_inc[4]; var i5 := pad_inc[5]
	var pk := 0.0
	var sq := 0.0
	for i in n:
		lfo += inv
		# pad
		p0 += i0; p1 += i1; p2 += i2; p3 += i3; p4 += i4; p5 += i5
		if p0 >= 1.0: p0 -= 1.0
		if p1 >= 1.0: p1 -= 1.0
		if p2 >= 1.0: p2 -= 1.0
		if p3 >= 1.0: p3 -= 1.0
		if p4 >= 1.0: p4 -= 1.0
		if p5 >= 1.0: p5 -= 1.0
		pad_amp += (pad_target - pad_amp) * 0.0002
		var cut := 0.035 + 0.03 * sin(lfo * 0.7) + 0.02 * cur_int
		var pl := p0 + p2 + p4 - 1.5
		var pr := p1 + p3 + p5 - 1.5
		pad_lp += cut * (pl - pad_lp)
		pad_lp2 += cut * (pr - pad_lp2)
		var duck := 1.0
		if lvl >= 2:
			duck = minf(0.35 + kick_t * 4.0, 1.0)
		var l := pad_lp * pad_amp * duck
		var r := pad_lp2 * pad_amp * duck
		# drone
		drone_ph += drone_inc
		if drone_ph >= 1.0: drone_ph -= 1.0
		drone_ph2 += drone_inc * 1.4983
		if drone_ph2 >= 1.0: drone_ph2 -= 1.0
		var dr := (sin(drone_ph * TAU) * 0.5 + sin(drone_ph2 * TAU) * 0.22 * (0.5 + 0.5 * sin(lfo * 0.31))) * (0.26 if lvl < 2 else 0.12)
		l += dr
		r += dr
		# bass
		if bass_gain > 0.0:
			bass_ph += bass_inc
			if bass_ph >= 1.0: bass_ph -= 1.0
			bass_env *= 0.99965
			var bx := (bass_ph * 2.0 - 1.0) + (0.5 if bass_ph < 0.5 else -0.5)
			var bc := 0.02 + 0.22 * bass_env * bass_env
			bass_y1 += bc * (bx - bass_y1)
			bass_y2 += bc * (bass_y1 - bass_y2)
			var bo := bass_y2 * bass_env * bass_gain * drive
			bo = bo / (1.0 + absf(bo))
			l += bo
			r += bo
		# arp pluck
		if arp_env > 0.001:
			arp_ph += arp_inc
			if arp_ph >= 1.0: arp_ph -= 1.0
			arp_env *= 0.99975
			var ax := (absf(arp_ph * 4.0 - 2.0) - 1.0) + (0.25 if arp_ph < 0.3 else -0.25)
			var ao := ax * arp_env * arp_env * 0.16
			l += ao * (1.0 - arp_pan)
			r += ao * arp_pan
		# lead
		if lead_env > 0.001:
			lead_f += (lead_tf - lead_f) * 0.002
			lead_ph += lead_f * inv * (1.0 + 0.006 * sin(lfo * 34.0))
			if lead_ph >= 1.0: lead_ph -= 1.0
			if not lead_gate:
				lead_env *= 0.9997
			var lx := (lead_ph * 2.0 - 1.0) + (1.0 if lead_ph < 0.5 else -1.0) * 0.5
			lead_y += 0.22 * (lx - lead_y)
			var lo := lead_y * lead_env * 0.085
			l += lo
			r += lo
		# kick
		if kick_t < 0.5:
			kick_t += inv
			kick_ph += (44.0 + 130.0 * exp(-kick_t * 30.0)) * inv
			var ko := sin(kick_ph * TAU) * exp(-kick_t * 8.0) * 0.6
			l += ko
			r += ko
		# hat + snare (noise)
		if hat_env > 0.002 or sn_env > 0.002:
			var nzv := mr.randf() * 2.0 - 1.0
			var hp := nzv - hat_prev
			hat_prev = nzv
			hat_env *= 0.9988
			sn_env *= 0.9996
			sn_ph += 196.0 * inv
			var ho := hp * hat_env * 0.07
			var so := (nzv * 0.6 + sin(sn_ph * TAU) * 0.5) * sn_env * sn_env * 0.24
			l += ho * 0.7 + so
			r += ho + so
		# soft clip
		l = l / (1.0 + absf(l) * 0.35)
		r = r / (1.0 + absf(r) * 0.35)
		out[i] = Vector2(l, r)
		var a := absf(l)
		if a > pk:
			pk = a
		sq += l * l
	pad_ph[0] = p0; pad_ph[1] = p1; pad_ph[2] = p2; pad_ph[3] = p3; pad_ph[4] = p4; pad_ph[5] = p5
	m_peak = maxf(m_peak, pk)
	m_sq += sq
	m_n += n
	step += 1
	return out
