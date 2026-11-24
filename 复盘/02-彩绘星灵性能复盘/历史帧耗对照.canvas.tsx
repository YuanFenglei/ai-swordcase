import { Button, Divider, H1, H2, H3, Pill, Row, Stack, Table, Text, useCanvasAction, useState } from "cursor/canvas";

const reports = "F:/我的/万剑匣/复盘/02-彩绘星灵性能复盘/依据-6e55caa/docs/reviews/";
const evidence = "F:/我的/万剑匣/复盘/01-视频技术与源码分析/";
const sections = [
  {
    title: "16 只星灵",
    heading: "同一组 16 只星灵，仅优化 CPU 路径就缩短了慢帧",
    scope: "11 月 19 日 · 5779d14 加当时改动 · Windows 无窗口 · 固定负载与帧时钟 · 前后 1,800 步全局状态哈希一致",
    columns: ["历史阶段", "物理步均值（ms）", "无窗口帧间隔 P99（ms）"],
    rows: [
      ["修改前", "11.9", "约 45"],
      ["修改后", "8.6–9.2", "约 27"]
    ],
    reading: "改动涉及索敌、步内可见性、地伤计时、笔刷几何、接触遮罩、角色对齐和显示快照等。相同结算结果下，CPU 路径能决定相当一部分慢帧。这组汇总没有测 GPU，也没有把同一帧内 16 宠同时释放单独计时。",
    file: "F:/我的/万剑匣/复盘/02-彩绘星灵性能复盘/依据-6e55caa/docs/handoff/当前状态.md",
    companion: "F:/我的/万剑匣/复盘/02-彩绘星灵性能复盘/依据-6e55caa/docs/architecture/主游戏代码架构.md"
  },
  {
    title: "首星守卫战",
    heading: "首星的三场守卫战，大部分帧接近 60 FPS 的时间预算",
    scope: "11 月 18 日 · 历史工作区 15fdbee 加本地改动 · Windows / RTX 4060 / 540 × 960 · 程序操作正常游戏入口",
    columns: ["节点", "保留帧数", "整帧 P95（ms）", "整帧最慢（ms）", "GPU P95（ms）"],
    rows: [
      ["5", "1,895", "16.73", "38.25", "6.03"],
      ["6", "3,428", "16.73", "49.39", "6.14"],
      ["1", "802", "16.74", "33.70", "6.05"]
    ],
    reading: "报告剔除了面板和保存截图干扰的区间。剩余帧里仍有偶发长帧，但三个节点均未呈现持续低帧。开新局是另一个现象，五次点击后分别记录到 1.34–1.81 秒范围内的最长单帧。",
    file: reports + "节点与关卡/首星实测证据/战斗帧耗.json",
    companion: reports + "节点与关卡/首星玩家视角实测.md"
  },
  {
    title: "六伙伴短测",
    heading: "重用旧笔迹几何后，大部分超时帧消失",
    scope: "11 月 15 日 · bf4ba94 加当时改动 · Windows / RTX 4060 · 6 只一阶伙伴与移动高血量靶 · 上限 60 FPS",
    columns: ["同一夹具", "有效帧数", "整帧均值（ms）", "整帧 P95（ms）", "超过 33 ms"],
    rows: [
      ["修改前", "540", "29.09", "130.28", "111 帧"],
      ["修改后", "540", "16.68", "16.69", "1 帧"]
    ],
    reading: "10 个模拟秒，去掉开头 60 帧。改动合并了喷溅几何复用、shader 动画、UV 计算和攻击候选裁剪。前后差值属于整组改动，不能精确分摊给其中某一项。",
    file: reports + "性能分析/performance-verification.json",
    companion: reports + "性能分析/启动与运行时性能验证.md"
  },
  {
    title: "300 模拟秒压力",
    heading: "持续喷彩的加速压力夹具里，优化后仍有长帧",
    scope: "11 月 17 日 · 35b465a 的窗口版前后对照 · RTX 5060 / OpenGL 3.3 / 540 × 960 · 6 伙伴和移动高血量靶",
    columns: ["末 30 模拟秒", "帧均值（ms）", "整帧 P95（ms）", "物理回调 P95（ms）"],
    rows: [
      ["修改前", "38.19", "76.34", "74.00"],
      ["修改后", "33.66", "66.80", "64.44"]
    ],
    reading: "夹具手动推进 3,000 个 0.1 秒步长。另一段插桩中，喷溅构网占笔刷显示耗时约 69%，分母限于笔刷显示。回调还包含游戏脚本和显示同步。历史版本的自动存档也有尖峰。不能从这些分项推出当前版本每帧的耗时分布。",
    file: reports + "性能分析/石碑染色与长时性能验证_2026-11-17.json",
    companion: reports + "性能分析/石碑染色与长时性能验证_2026-11-17.md"
  }
];

export default function GodotPerformanceComparison() {
  const [index, setIndex] = useState(0);
  const action = useCanvasAction();
  const section = sections[index];
  const open = (path: string) => action({ type: "openFile", path });
  return <Stack gap={16} style={{ padding: 16 }}>
    <H1>十万单位与一笔颜料，各自算了什么？</H1>
    <Text>视频中的 Neon 把同类单位成批算在显卡上。《彩绘星灵》还要让一次攻击改变碰撞、伤害和之后能查询到的地色。两边的帧数对应不同的工作。</Text>
    <Row wrap><Button onClick={() => open(evidence + "视频与源码技术对照.html")}>打开图文对照</Button><Button variant="ghost" onClick={() => open(evidence + "Neon-画面字幕.srt")}>查看带时间码字幕</Button></Row>
    <Divider />
    <H2>《彩绘星灵》的已有测试</H2>
    <Row wrap gap={6}>{sections.map((item, i) => <Pill key={item.title} active={i === index} onClick={() => setIndex(i)}>{item.title}</Pill>)}</Row>
    <Stack gap={8}>
      <H3>{section.heading}</H3>
      <Text tone="secondary" size="small">{section.scope}</Text>
      <Table headers={section.columns} rows={section.rows} />
      <Text>{section.reading}</Text>
      <Text tone="secondary" size="small">P95 表示 95% 的帧耗时不超过该值。60 FPS 的单帧预算约为 16.67 ms。</Text>
      <Row wrap><Button variant="ghost" onClick={() => open(section.file)}>原始数据</Button><Button variant="ghost" onClick={() => open(section.companion)}>测试报告</Button></Row>
    </Stack>
    <Divider />
    <H2>视频读数怎样解释</H2>
    <Text>03:14 的 HUD 同时显示十万单位、317 FPS 和 90 次绘制调用。作者口播 RTX 3060 约 305 FPS。一个网格区域只存一个代表敌人的位置，邻近部队共享流场，显示端直接从 GPU 纹理读取状态。</Text>
    <Text>05:27 的流体展区显示 280 FPS，粒子数为 36,864。06:11 的密度着色器对每个邻域格的链表最多遍历 44 项，画面采用朝向相机的球形贴片。这些做法控制了密集场景的邻居搜索和水面绘制成本。</Text>
    <Row wrap><Button variant="ghost" onClick={() => open(evidence + "关键帧/03分14秒-十万单位与帧率.jpg")}>看十万单位 HUD</Button><Button variant="ghost" onClick={() => open(evidence + "关键帧/06分11秒-邻域遍历上限.jpg")}>看流体循环上限</Button></Row>
  </Stack>;
}
