# 蚀原

Godot 4.7 零素材 3D 游戏。工程里只有 `.gd`、`.gdshader`、`.tscn`、`project.godot` 和这份说明；网格、动画、贴图、天空、特效、音效和音乐全部在运行时由代码生成。

## 运行

```
godot --path .                  # 正常游玩
godot --path . -- --demo        # 自动演示（约 109 秒一轮，循环）
godot --path . -- --shots       # 逐段跳转演示，截图存到 _shots/，打印 FPS 后退出
godot --path . -- --shots --scene=5   # 只跑第 5 段（0–7）
godot --path . -- --selftest    # 自动走一遍 标题→游玩→Boss→胜利→失败，截图后退出
godot --path . -- --demo --probe=4    # 实时跑一轮演示，每 4 秒存一张缩略截图后退出
```

## 操作

| 按键 | 动作 |
| --- | --- |
| W A S D | 移动 |
| 鼠标 | 瞄准 |
| 左键 | 脉冲炮 |
| 右键 | 光束（消耗能量） |
| Shift | 冲刺 |
| 空格 | 震爆（消耗能量） |
| Enter | 开始 / 再来一次 |
| Esc | 回到标题 / 退出 |

## 流程

收集 5 个能量核心，每个核心附近会钻出虫群；集齐后蚀母破土，击杀即胜利。

## 文件

| 文件 | 内容 |
| --- | --- |
| `mb.gd` | 网格构建器：放样、管、车削、二十面球，输出 ArrayMesh |
| `terrain.gd` `shaders/terrain.gdshader` | 噪声高度场、碰撞、三平面程序化地表 |
| `scatter.gd` | 岩石、骨肋、石柱、晶簇、芦苇、球茎树 |
| `world.gd` `shaders/sky.gdshader` | 环境、后期、程序化天空 |
| `leg.gd` | 解析式两段 IK 腿与步态调度 |
| `walker.gd` | 六足行者：机体、炮塔、武器、弹簧机身 |
| `creature.gd` `boss.gd` | 虫群与 28 条腿的蚀母 |
| `fx.gd` `beam.gd` `core.gd` | 粒子、弹体、爆炸、冲击波、屏幕后期、能量核心 |
| `audio.gd` | 合成音效与生成式音乐 |
| `hud.gd` `main.gd` `director.gd` | 界面、流程、演示导演 |
