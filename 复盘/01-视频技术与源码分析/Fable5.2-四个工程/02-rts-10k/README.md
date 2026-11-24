# 万人战场 — 10k-vs-10k RTS battle in pure GDScript

Godot 4.7.2, Forward+. Only `.gd`, `.gdshader`, `.tscn`, `project.godot`. No GDExtension, no C#, no imported assets:
every mesh (soldiers, horses, banners, arrows, rocks, bridges, keeps, terrain) is built in code.

## Run

```
GODOT=D:/Game/Godot_v4.7.2-stable_win64_console.exe

$GODOT --path .                       # skirmish: you command blue, an AI commander plays red
$GODOT --path . -- --units=40000      # skirmish with another army size
$GODOT --path . -- --demo             # self-running trailer, ~112 s, loops (ramps 20k -> 100k)
$GODOT --path . -- --demo --max=150000
$GODOT --path . -- --shots            # highlights -> _shots/*.png, prints the benchmark table, quits
$GODOT --path . -- --bench=100000     # one battle of N units, 5 s measurement, prints one table row, quits
```

VSync is off in every mode, so the FPS counter is the real frame rate.

## Controls (skirmish)

| Input | Action |
| --- | --- |
| W A S D / arrows | pan camera |
| Q / E, middle-drag | rotate (drag also tilts) |
| mouse wheel | zoom |
| left-drag | box select |
| left-click | select one unit |
| right-click | move (ground or minimap) |
| Ctrl + right-click | attack-move |
| F | selected units hunt the nearest enemy |
| H | hold position |
| Ctrl + A | select the whole army |
| Ctrl + 1..9 / 1..9 | assign / recall control group |
| left-click on minimap | jump camera |
| Esc | quit |

## Architecture

- **`scripts/sim.gd`** — the simulation. Struct-of-arrays in `Packed*Array`s (position, velocity, facing, hp, team,
  target, state, order, cooldown ...). Fixed 20 Hz tick on its own thread; the tick fans out over
  `WorkerThreadPool` in 512-unit chunks. Each unit per tick: 3x3 lookup in a uniform grid (1.25 m cells, 4 slots,
  double buffered, refilled by the units themselves) for separation and the nearest enemy, then melee / ranged /
  order logic, steering along a flow field, obstacle slide, and it writes its own 16 floats of the MultiMesh buffer.
- **Flow fields** (256x256, 2.5 m cells, second thread): cost field -> integration field (wavefront, then an
  Eikonal fast-sweeping pass so streams do not collapse into 8-direction lanes) -> flow field. One "nearest enemy"
  field per army is recomputed continuously (~5-8 Hz); every move / attack-move order gets its own field.
  Ranged units find targets by walking the enemy field.
- **Rendering** — one MultiMesh per 512-unit chunk (frustum culled, distance LOD, per-chunk shadow casting).
  The instance transform is not a transform: the 12 floats + colour carry previous/current position and facing,
  state, state start time, last hit time, speed, team, selection, seed. `shaders/unit.gdshader` interpolates between
  the last two ticks and animates walk cycle, attack swing, bow draw, gallop and death fall per vertex.
  Arrows are a ring buffer of instances whose whole ballistic arc is evaluated in the vertex shader.
- **`scripts/world.gd`** — procedural height map, river with two bridges and a ford, rocks, keeps, cost field,
  terrain / water shaders, lighting. Deaths and marching write into a stain map that the terrain shader reads.
- **`scripts/main.gd`** — RTS controls, AI commander, demo director, `--shots` / `--bench` runners.
- 4 unit types: swordsmen, archers, lancers, standard bearers.

One 4.7 gotcha that shaped the hot loops: integer `/` and `%` do not scale across threads in GDScript
(16 threads ran slower than 1), so the threaded code uses shifts, masks and `int(float)` only.

## Measured

RTX 3060, Ryzen 9950X (32 threads), 1920x1080, VSync off, whole battlefield in view, both armies fighting.
Three other GPU projects were running on the same machine during the measurements; the table is the least
disturbed run of three, the frame rate under load was as low as a quarter of it.

| units | FPS avg | 1% low | sim tick ms (20 Hz budget = 50) | neighbours / brain / move ms | GPU ms | flow field ms |
| ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 20,000 | 284 | 270 | 8.1 | 4.8 / 0.9 / 2.2 | 3.4 | 110 |
| 50,000 | 191 | 177 | 14.8 | 8.5 / 1.6 / 4.5 | 5.0 | 124 |
| 100,000 | 127 | 105 | 25.9 | 15.1 / 3.1 / 7.4 | 7.3 | 145 |
| 130,000 | 111 | 48 | 32.8 | 19.9 / 3.5 / 9.0 | 8.0 | 175 |
| 170,000 | 104 | 98 | 44.9 | 28.0 / 4.1 / 12.2 | 9.1 | 206 |
| 200,000 | 74 | 64 | 56.8 (tick rate falls to ~15 Hz) | 36.1 / 5.2 / 14.9 | 12.7 | 258 |
| 300,000 | 71 | 63 | 94.2 (~10 Hz) | 65.3 / 6.7 / 21.3 | 13.7 | 204 |

- The tick runs on worker threads, so its time is wall time across the pool, not main-thread time.
  The three sub-columns come from timers on every 64th unit, scaled to the measured pass.
- Rendering stays above 60 FPS up to 300k in this view. What gives out first is the simulation: the 20 Hz tick
  holds up to about 170k units; above that the tick stretches and the battle runs in slow motion.
- Main-thread cost per tick (buffer upload + orders): 0.4 ms at 20k, 1.8 ms at 100k.

## Known limits

- The grid keeps 4 units per cell and concurrent melee hits on the same target are not atomic: under extreme
  crowding a neighbour or a hit can be missed for a tick.
- Arrow hits are resolved at the predicted landing point (2.2 m radius), not swept.
- No morale. Plain right-click moves arrive as a blob; only the scripted advances keep formation.
- The AI commander only advances and then hunts.
