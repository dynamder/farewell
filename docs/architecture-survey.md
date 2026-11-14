# 终端图形栈：前人做了什么，哪些该重构，哪些该统一

> 依据：`refs/` 里的 13 个仓库源码实测（行数、实现分布、探测方式），不是二手描述。
> 结论先行：**真正重复、真正该统一的是「传输层」，不是「渲染层」。**

---

## 0. 一句话结论

前人不是「一堆 C 项目」，而是**四代、四种不同的角色**。混着看会觉得重复；
分开看会发现：重复只集中在最底层，而那一层正好是 Zig 最擅长的部分。

| 代 | 代表 | 角色 | 规模 |
|---|---|---|---|
| 1 | TMDC / libcaca | 在 16 色文本模式里硬造图像 | 1996–2007，90 个 demo |
| 2 | notcurses / chafa / libsixel | **把「终端图形」做成基础设施** | C，31k / 83k / 39k 行 |
| 3 | VinZ / Consol3 / asciitracing | 纯艺术，单文件，用完即弃 | 746 / 11k / 107 行 |
| 4 | youterm / dcat / Termium | **只做「呈现器」**：渲染在别处，终端只负责搬 | Go / Rust / 闭源 |

第 4 代是转折点：`dcat` 的 `Cargo.toml` 里躺着 `wgpu = "30.0"`——它根本不在 CPU 上
画三角形，而是让 GPU 出图，终端只当显示器。`Termium` 同理（Chromium 出像素）。
**「生产者」和「呈现者」已经在事实上分家了，但没有人写过一个干净的呈现层库。**

这就是空位。

---

## 1. 逐层现状（附证据）

### L0 能力探测 —— 两派，都很脆

| 项目 | 方式 | 体量 | 问题 |
|---|---|---|---|
| notcurses | **主动询问**：`\x1b[c`(DA1)、`\x1bP+q544e;524742;687061`(XTGETTCAP 查 TN/RGB/hpa) | `termdesc.c` 1682 行 | 需要读回响应、要超时、在 tmux/ssh/管道里会污染 stdin；串口/老终端可能不回 |
| chafa | **静态数据库**：TERM_PROGRAM / TERM 匹配 + 每终端一张序列表 | `term-db.c` 1338 + `term-info` + `term-seq` | 新终端要手动加表；同名终端行为不同时立刻错；但零延迟、零副作用 |
| libvaxis（Zig） | 同 notcurses：**不用 terminfo，全靠查询** | — | 同上 |
| youterm | **不探测**，直接写 | `player.go:756` | 在不支持 2026 的终端上是垃圾字节 |

两派各有死穴，且**没有第三个选择被认真做过**：用环境变量/termcap 做**初值**，
用查询做**修正**，用配置文件/命令行做**覆盖**，三者合成一个能力位图。这是第一个该统一的点。

### L1 转义序列生成与批处理

- `chafa-batch.c`：把同色 cell 合并成 run，减少 SGR 数量
- `timg/buffered-write-sequencer.cc`：把整帧拼进一个缓冲再 flush
- `VinZ`：README 明说「single buffer writes to avoid flickering」
- `notcurses/render.c`：**damage map**（只重绘脏区，`crender->s.damaged`）

四种做法，四种取舍，没有一种被抽象成可复用接口。而且**没有任何一个实现了背压**：
终端解析不过来时应该自动降分辨率，只有 `sixvid` 用「发送字节数」粗略估了一下。

### L2 分辨率阶梯（blitter）

notcurses 是唯一把它形式化的（`include/notcurses/notcurses.h`）：

```
1x1, 4x1, 8x1, 2x1, 2x2, 3x2(六分块), 4x2(八分块), BRAILLE, PIXEL
```

其余项目各写各的：timg 三套 canvas（`sixel-canvas.cc` / `kitty-canvas.cc` /
`iterm2-canvas.cc`），chafa 一套 canvas + 多种 pixel mode，VinZ 只有半块。
**「哪些模式可用」的判断逻辑散落在每个项目里**，这就是为什么 notcurses 的默认选择
要写成四级 if（八分块→六分块→象限→半块）。

### L3 图像传输 —— 重复最严重的地方

| 实现 | 行数 | 说明 |
|---|---|---|
| notcurses `sixel.c` | **1793** | 完整 sixel 编码 |
| chafa `chafa-sixel-renderer.c` | 560 | 另一套 |
| timg `sixel-canvas.cc` | 174 | 第三套 |
| libsixel `encoder.c` + `dither.c` + `output.c` + `frame.c` | **4690** | 第四套，且最完整 |
| notcurses `kitty.c` | **1216** | kitty 协议 |
| chafa `chafa-kitty-renderer.c` | 482 | 第二套（**唯一实现了 U+10EEEE 占位符**） |
| timg `kitty-canvas.cc` | 345 | 第三套 |
| dcat（Rust）/ youterm（Go） | — | 第四、五套 |

**同一个协议被独立实现了 4~5 次，累计上万行。** 而这些代码的差异几乎全在
「怎么跟终端协商」而不是「怎么做艺术」——典型的该下沉到库里的东西。

### L4 同步输出（DECSET 2026）

notcurses 把它当能力位（`termdesc.c:703`，仅在有该能力时发 `\x1b[?2026h/l`）；
youterm 无条件硬写。差别是：后者在老终端上会得到**整屏乱码或闪烁**，而它自己不知道。

### L5 量化与抖动

- `libsixel/dither.c` 918 行：有序 + 误差扩散，完整
- `chafa/internal/chafa-dither.c` + `chafa-symbol-map.c` 1946 行：符号选择算法
- `chafa-color-hash.c` + `chafa-color-table.c`：颜色量化

这是**真正有技术含量的部分**，而且两份实现互不借鉴。符号选择（用哪个字形代表这个
cell 的内容）是最值得移植的算法资产。

### L6 场景/生成器（不该统一的部分）

- `VinZ/vinz.c` 746 行：raymarching + 流体 + 种子
- `Consol3/src` 11k 行 C++：光栅化 + 体素 raymarch + 粒子
- `asciitracing/render.cc` 107 行：sphere tracing
- `dcat`：wgpu + `shader.wgsl`

四个项目，四种世界观，**这才是艺术本身**。统一它等于扼杀它。

### L7 宿主框架（跟艺术无关的绝大部分）

notcurses `src/lib` 共 31k 行，其中：

- 渲染+传输核心（blit/kitty/sixel/visual/termdesc/render/…）≈ **18.1k**
- TUI 控件（menu/reel/selector/tree/tabbed/plot/progbar/reader/…）≈ **7.3k（24%）**
- 其余（输入、信号、日志、EGC 池、统计）≈ 6k

**你想做的是艺术，但你要为 24% 的控件代码付集成成本。** 这就是不建议 link notcurses 的
量化理由。

---

## 2. 需要重构的五个点（按优先级）

### ① 能力探测合成（P0）
两派做法都只对一半。目标是一个 `caps` 模块：

```
env/terminfo 表  →  初值（零延迟，覆盖 90%）
主动查询（DA1/XTGETTCAP/2026/kitty）  →  修正（准确，带超时，失败不阻塞）
用户覆盖（--force-color / --force-graphics / $TERM_ART_FORCE）  →  兜底
                ↓
         Capability Bitmap（位图 + 版本 + 缓存到磁盘）
```

缓存很重要：查询要 100~300ms，每次启动都查是不能接受的。

### ② 同步输出不能盲写（P0）
必须作为能力位。同时要处理「终端不支持时不要输出未知私有序列」——
部分老终端会把未知 CSI 当可打印字符吐出来。

### ③ 带宽预算模型（P1）
目前没人做。应该是一个统一的代价模型：

```
cost(cell) = 3 (字符) + 双色 SGR 字节(≈33 truecolor / 13 indexed256) + 属性字节
budget = width × height × cost × fps   →  若超阈值，降 blitter 档位或降 fps
```

`sixvid` 那种「按发送字节数估帧率」的思路是对的，但只做了一半（没反向调分辨率）。

### ④ sixel 色数与调色板策略（P1）
libsixel 有一整套（自适应调色板、256 色、色深协商），其余实现各定各的。
应该由 `caps` + `budget` 决定，而不是写死在编码器里。

### ⑤ 分辨率阶梯的语义（P2）
nine 种 blitter 其实是一个二维参数：`(nx, ny) ∈ {(1,1),(4,1),(8,1),(2,1),(2,2),(3,2),(4,2)}`
加两个特例（braille 有间隙、pixel 走协议）。**统一成 `(nx, ny, mode)` 三元组**，
分支就消失了。

---

## 3. 值得统一整合的三件事

### ① Presenter（传输层）—— 最重要的空位
职责：`frame → bytes → fd`，且只知道三件事：caps、budget、transport。

```
compose(Frame) → plan(caps, budget) → encode(transport) → write(fd) → measure → adjust
```

transport 是个枚举：`{ ansi_cells, sixel, kitty, iterm2 }`。
现在这层被 5 个项目各写一遍，是最大的重复来源。

### ② Frame 数据类型
所有实现都在传「图像」，但没有一个中立的内存表示。建议：

```zig
pub const Frame = struct {
    w: u32, h: u32,
    pix: []const u8,        // RGB8 或 RGBA8，行优先
    alpha: bool,            // 是否有透明
};
```

libsixel 吃 RGB8、kitty 吃 RGBA8、blitter 吃任意——**一个 Frame 就能接所有 producer**。

### ③ Blitter 表
把 notcurses 的九种模式抽成数据驱动的表（字形映射 + 采样率 + 尺寸比），
而不是九段 if。这样加「八分块」只是加一行数据。

---

## 4. 明确**不要**统一的

- 场景/生成器（L6）：艺术不该被抽象。想做流体就写流体。
- TUI 控件（L7）：需要就直接用 libvaxis，别自己造。
- 颜色科学/色调映射：让 producer 决定，presenter 只负责忠实搬运。

---

## 5. Zig 的具体接缝

### 为什么 Zig 在这里确实合适

1. **`zig cc` 自带 C 编译器**：Windows 上不需要 MSVC / autotools 就能把 C 源编进来。
   这是相比 Rust 的实质优势——你面对的全是 C 项目。
2. **`@cImport` + 直接 link**：libsixel 的 API 干净（`sixel_encoder_new/setopt/encode/free`）。
3. **无 GC、无运行时**：启动 ~2ms，帧时延稳定。
4. **`comptime` 适合 blitter 表**：九种模式的字形/采样表可以在编译期生成。

### 复用决策表

| 资产 | 决策 | 理由 |
|---|---|---|
| **libsixel** | **vendor 少量 .c 直接编**（不是 link 安装好的库） | 唯一值得复用的 C 库；但 autotools 的 `config.h` 在 Windows 上是坑，直接 `addCSourceFiles` 更省事 |
| notcurses | **只读，不 link** | 24% 是控件代码，且它的 caps/terminfo 模型跟你的要冲突 |
| chafa | **读算法，不 link** | 依赖 GLib（`configure.ac:115`，glib-2.0 ≥ 2.58），为了符号选择算法背 GLib 不值 |
| 符号选择 / 抖动 | **移植**（`chafa-symbol-map.c` + `dither.c`） | 最值得抄的部分，~2–3k 行逻辑 |
| kitty 协议 | **自己实现**（~400 行） | 协议简单（`a=T` 传输 + `a=p` 放置 + base64/chunk + `U=1` 占位符），比整合别人的省事 |
| libvaxis | **参考或作底座** | 已是 Zig、查询式探测、有 kitty 图像；但**只支持 kitty，没有 sixel**，且锁 Zig 0.17.1（本机 0.17.0） |
| 场景代码 | 参考 `vinz.c` 的结构 | 746 行，最好的「单文件艺术程序」范本 |

### 版本风险（要现在就定）

- 本机 `zig 0.17.0`，libvaxis 要求 `0.17.1`，且它的 README 说主分支跟 `0.18.0-dev`。
  **Zig 的标准库 API 还在频繁破坏性变更**，选 Zig 就要接受「锁版本、不自动升级」。
- 建议：`build.zig.zon` 里锁死 vaxis tag，并在 CI 里固定 zig 版本。

### Windows 现实（你的环境）

- 你有 Windows Terminal 1.22+ → **有 sixel，没有 kitty**
- 所以第一优先的 transport 是 `ansi_cells` + `sixel`；kitty 留接口，在 Ghostty/WezTerm 里再验证
- `zig build` 在本机能直接产出 .exe，不需要 WSL（这是选 Zig 的实际收益）

---

## 6. 建议的模块树

```
src/
  caps.zig        能力位图 + 三源探测 + 磁盘缓存
  caps/probe.zig  DA1 / XTGETTCAP / 2026 / kitty 的异步查询（带超时）
  frame.zig       Frame 类型 + 缩放/裁切
  blitter/
    table.zig     (nx,ny,mode) → 字形表、采样率（comptime 生成）
    render.zig    任意采样 → cell buffer
  quantize/
    dither.zig    有序 / FS / 时间抖动
    palette.zig   xterm256 + 自适应
  transport/
    cells.zig     SGR 生成 + run 合并 + damage
    sixel.zig     sixel 编码（vendor libsixel 的编码核心）
    kitty.zig     kitty 协议（自实现）
  presenter.zig   预算模型 + 背压 + 同步输出
  terminal.zig    raw mode / size / alt screen / cursor
  scene/          艺术层，随意生长
```

边界原则：**`scene/` 只依赖 `Frame`；`transport/` 只依赖 `Frame` + `caps`；
两者永不互相 import。**

---

## 7. 建议的推进顺序

1. `caps` + `terminal` + `cells`（最小可跑：能在 WT 里画一帧）
2. `blitter/table` + `render`（半块 → 六分块 → 盲文，一屏内对照）
3. `presenter` 预算模型（把「每 cell 36 字节」变成可测量、可自适应）
4. `sixel`（WT 就能看，且能验证「照片级」上限）
5. `quantize/dither`（时间抖动是最便宜的高级感）
6. `scene/`（到这一步才开始做艺术）

前五步都是「重复造轮子」，但**造一次，以后每个作品都省事**——这正是前人没做的事。
