# mosaic —— 把前人的技法做成依赖库

> 一句话：**mosaic 把一帧像素变成终端字节，并选对技法。**
> 它不是 TUI 框架，不是场景引擎，不是终端模拟器。

---

## 0. 为什么这一层值得独立存在

调研（`docs/architecture-survey.md`）量化了三件事：

1. sixel 被独立实现 **4 次**（~7.2k 行），kitty 协议 **3 次**（~2k 行），
   能力探测 **2 套哲学**（notcurses 主动查询 / chafa 静态表）。
2. 这些实现的**差异全在「怎么跟终端协商」，不在「怎么做艺术」**。
   协商是可以标准化的，艺术不能。
3. 第 4 代项目（youterm / dcat / Termium）已经证明：**生产者与呈现者分家**。
   但呈现者那一层，至今没有一个干净的库。

mosaic 就是那一层。

---

## 1. 依赖边界（关键决定）

```
        ┌──────────────────────────────────┐
        │  scene/  producer（GPU / CPU / 视频）  │   ← 不属 mosaic
        └───────────────┬──────────────────┘
                        │ Frame
        ┌───────────────▼──────────────────┐
        │              mosaic              │
        │  blit → quant → transport → pacer │
        └───────────────┬──────────────────┘
                        │ bytes + cells
        ┌───────────────▼──────────────────┐
        │  libvaxis（caps 探测 / cell 输出 /   │
        │  kitty 图像 / 输入 / mode 2026）      │
        └──────────────────────────────────┘
```

- **依赖 vaxis**：0.6.0，`minimum_zig_version = 0.17.0`（本机 0.17.0 通过）。
- **不依赖** notcurses / chafa / libsixel。它们只作算法来源。
- **不封装 vaxis 的 widget 层**：要用直接用。

vaxis 已经提供了：查询式 caps（不用 terminfo）、cell grid、kitty graphics、
kitty keyboard、mode 2026/2027/2031/2048、OSC 8/52/22。
**它没有的正是我们要做的**：blitter 阶梯、量化与抖动、sixel、预算与背压。

---

## 2. 模块与接口

### 2.1 `caps` —— 能力位图

```zig
pub const Caps = struct {
    truecolor: bool = false,
    indexed256: bool = false,
    sixel: bool = false,
    kitty: bool = false,
    sync_output: bool = false,
    sextants: bool = false,   // 字体是否真有 U+1FB00 区
    octants: bool = false,    // 大部分字体为 false，实测决定
    braille: bool = true,
    cell_px: ?CellPx = null,  // 用于像素传输的纵横比校正

    pub fn fromVaxis(v: *const vaxis.Vaxis) Caps;
    pub fn applyEnv(*Caps);                 // COLORTERM / TERM_PROGRAM / WT_SESSION
    pub fn applySpec(*Caps, spec: []const u8) void;  // "--caps=+sixel,-octants"
};
```

**三源合成（调研里欠的那件事）**：
env 给初值 → vaxis 的查询结果修正 → `applySpec` 强制覆盖。
sextants/octants 是**字体属性不是终端属性**，只能靠实测或用户指定。

### 2.2 `frame` —— 唯一的数据接口

```zig
pub const Frame = struct {
    w: u32,
    h: u32,
    stride: usize,
    fmt: Fmt,          // .rgb8 / .rgba8 / .gray8
    pix: []const u8,

    pub fn at(self: *const Frame, x: u32, y: u32) Rgba;
    pub fn scaleTo(self: *const Frame, alloc, w: u32, h: u32) !Frame;
};
```

**决定：只用 Frame，不引入场景图。**
想做文字/矢量，用 `Shade` 钩子（每 cell 一个回调，返回字形或颜色），
而不是发明一套画线 API——那是 TUI 库的活。

```zig
pub const Shade = fn (frame: *const Frame, x: u32, y: u32, d: *const BlitDims) CellColor;
```

### 2.3 `blit` —— 分辨率阶梯（数据驱动）

```zig
pub const Mode = enum { ascii, bars4, bars8, half, quad, sextant, octant, braille, pixel };

pub const Spec = struct {
    nx: u8, ny: u8,          // 每 cell 横向/纵向采样数
    kind: enum { ink, dot, pixel },  // ink=字形覆盖度, dot=盲文点, pixel=协议
    aspect: f32,             // 校正 cell 的非方形
};

pub const table = [_]Spec{ ... };   // comptime 生成

pub fn select(f: *const Frame, caps: Caps, budget: Budget) Mode;
pub fn render(f: *const Frame, mode: Mode, out: []vaxis.Cell) void;
```

把 notcurses 的九段 if 变成一张表——加八分块只是加一行。
`ascii` 档的符号选择移植 chafa 的**墨量匹配**算法（1x1 档的抗锯齿）。

### 2.4 `quant` —— 量化与抖动

```zig
pub const Palette = union(enum) {
    truecolor,
    xterm256,
    adaptive: []const u24,
    indexed16,
};

pub const Dither = enum { none, bayer2, bayer4, bayer8, fs, temporal };

pub const Quant = struct {
    palette: Palette = .truecolor,
    dither: Dither = .none,
    frame_index: u64 = 0,        // temporal 抖动需要
    pub fn quantize(self: *Quant, src: []const u8, dst: []u8) void;
};
```

三条来源合一：
- 有序/FS 抖动 ← libsixel `dither.c`（918 行，完整）
- 符号墨量匹配 ← chafa `chafa-symbol-map.c`（1946 行，最值得移植）
- **temporal dither**（每帧变相位）← 没人做过，是空位

### 2.5 `transport` —— 四种编码

```zig
pub const Transport = enum { cells, sixel, kitty, iterm2 };

pub fn encode(
    t: Transport,
    f: *const Frame,
    caps: Caps,
    q: *Quant,
    out: *std.ArrayList(u8),
) !void;
```

- `cells`：SGR 生成 + 同色 run 合并 + damage（只重绘脏 cell）
- `sixel`：移植 libsixel 的编码核心（目标 ~400 行 Zig）
- `kitty`：vaxis 已有 `Image`，可直接用；仅在需要占位符混排时自己发
- `iterm2`：OSC 1337，十行的事，做兼容

### 2.6 `pacer` —— 预算与背压

```zig
pub const Budget = struct {
    bytes_per_sec: u64 = 8 << 20,
    max_fps: u16 = 60,

    pub fn cost(mode: Mode, w: u32, h: u32, caps: Caps) u64;
};

pub const Pacer = struct {
    ema_ns_per_frame: f64 = 0,
    pub fn decide(self: *Pacer, cost: u64, elapsed_ns: u64) Decision;
};

pub const Decision = enum { keep, drop_mode, drop_fps, drop_frame };
```

**这是调研里确认的真空**：只有 sixvid 做了「按字节数估帧率」，
没有一家做「按终端吞吐反向降档」。代价公式已经在调研里算过：
半块真彩 ≈ 36 字节/cell，200×50 全屏 360 KB/帧。

---

## 3. 技法清单：从哪来，怎么落地

| 技法 | 出处 | 落地方式 | 优先级 |
|---|---|---|---|
| blitter 阶梯 9 档 | notcurses `blit.c` (1477) | 数据表重写 | **P0** |
| damage map / 脏区 | notcurses `render.c` | per-cell 脏标记 + run 合并 | P1 |
| 同步输出能力位 | notcurses `termdesc.c:703` | 进 Caps | **P0** |
| 符号墨量匹配 | chafa `symbol-map.c` (1946) | **移植** | P2 |
| 有序/FS 抖动 | libsixel `dither.c` (918) | 移植 | P2 |
| 调色板量化 | libsixel `encoder.c` | 重写（中位切分） | P2 |
| sixel 编码 | libsixel `encoder.c` (~2400) | 移植核心 | P3 |
| kitty 占位符 U+10EEEE | chafa `kitty-renderer.c:52` | 必要时自实现 | P4 |
| 半块单缓冲写出 | VinZ `vinz.c` (746) | 默认路径 | **P0** |
| 带宽估计 / 自适应 | sixvid (788, bash) | 扩展成双通道降档 | P1 |
| 传输选择（三 canvas） | timg `*-canvas.cc` | transport 枚举 | P1 |
| **temporal dither** | 无人 | 新做 | P3 |

**不搬的**：TUI 控件（用 vaxis）、场景/生成器（那是艺术）、notcurses 的
terminfo 模型（与 vaxis 的查询模型冲突）。

---

## 4. 三个已定的设计决定

1. **Frame 是唯一数据接口**，文字/矢量走 `Shade` 钩子，不造场景图。
2. **pacer 是唯一的策略点**：预算、背压、同步输出、降档全在这里，
   其余模块都是纯函数（可测试、可 benchmark）。
3. **量化发生在传输封装内部**，不由调用方决定——因为「用哪个调色板」
   取决于 transport（cells 用 256 色，sixel 用自适应调色板）。

---

## 5. 里程碑

| M | 内容 | 验收 |
|---|---|---|
| M0 | vaxis 接入 + caps + `cells` transport + 半块渐变 | 在 WT 里看到一帧正确渐变，30fps 无撕裂 |
| M1 | blitter 表 1x1→braille 全家桶 | 同一帧在 6 种模式下并排对照 |
| M2 | quant + 抖动（含 temporal） | 同一张图在 truecolor/256/16 下的抖动对照 |
| M3 | sixel transport | WT 里显示一张照片（这是 WT 的上限） |
| M4 | pacer + damage | 400×100 全屏下自动降档，不失稳 |
| M5 | kitty transport | 在 Ghostty/WezTerm 里验证，WT 上自动回退 |
| M6 | 文档 + 示例 + 可选 C ABI | 别人能 10 行代码用起来 |

M0–M2 是「技法库」的核心价值；M3 之后是「覆盖更多终端」。

---

## 6. 风险

| 风险 | 应对 |
|---|---|
| vaxis API 漂移（作者更新频繁） | 锁 0.6.0 tag，`build.zig.zon` 固定 hash；升级作为独立 PR |
| zig 0.17.x 内部 API 还在变 | 不追 master；`minimum_zig_version` 显式写死 |
| 八分块字体缺失 | `octants=false` 默认，靠 `--caps=+octants` 手动开 |
| temporal 抖动视觉上可能很吵 | 做成可调强度，默认关闭 |
| sixel 在 WT 的实际吞吐未知 | M3 第一件事就是测，数据不合格就把 sixel 降为可选 |
