# farewell

终端图形库：像素进，ANSI 字节出。
用于创作终端艺术。

```
Source ──blit──> Grid ──post──> Grid ──ansi──> bytes ──> tty
        CPU 受限         后处理        带宽受限
```

管线本身不碰终端：能力位由调用方给，字节由调用方写。

## 模块

| 文件 | 内容 |
| --- | --- |
| `src/types.zig` | `RGB` `Cell` `Grid` `Size` `Mode`（ascii / bars / half / quad / sextant / braille / ink / ink16 的密度表） |
| `src/source.zig` | `Frame`、`Sampler`、`sampler(&scene)` 绑定器 |
| `src/blit.zig` | 各档打包器；`render`、`renderAny` |
| `src/ansi.zig` | SGR 合并（真彩色或调色板索引）、CRLF 换行、`row_skip` 按行 diff |
| `src/post.zig` | 后处理阶段的接线：效果按元组传入，逐格与整帧两档 |
| `src/quant.zig` | 调色板、最近色、两槽混色（`mix`）、`quant.Fixed` 量化效果 |
| `src/dither.zig` | 有序抖动：Bayer 阈值把混色铺到格上 |
| `src/ink.zig` | 符号墨量匹配：网格、字形表、剪影匹配、两色重算 |
| `src/ink-ascii-8x8.zig` | 量出来的字形掩码，8×8 网格（`zig build inkmap` 生成） |
| `src/ink-ascii-8x16.zig` | 同上，8×16 网格 |
| `src/caps.zig` | 终端与字体能力位、来源轨迹、覆盖语法、降级阶梯 |
| `src/present.zig` | 帧装配：grid + 模式 + 缓冲，整帧一次写出 |
| `src/pacer.zig` | 帧预算：超预算先降帧率，到底后降档，回升走反方向 |

演示在 `demo/`：`raymarch.zig` 是场景本身，`host.zig` 是终端设备层（尺寸、按键、raw mode、一帧一次写）。这两份只服务演示，不进入包 API。

## 用法

```zig
var grid = try farewell.Grid.init(alloc, 120, 36);
defer grid.deinit(alloc);

farewell.render(farewell.sampler(&scene), .half, &grid, .{ .uv = .square });
const stats = try farewell.emit(&grid, buf, .{});
```

源只要是「能回答 `at(u, v) RGB` 的类型」即可，`Frame` 和 `Sampler` 都满足它。
模式可以是运行时值：`farewell.renderAny(src, mode, &grid, .{})`。

`uv` 有两种语义：`.stretch` 铺满网格（图片），`.square` 居中正方并按 `cell_px`
校正纵横比（程序化场景，圆就是圆）。

## 接入宿主

库只管「像素 → cell → 字节」，跟终端说话的永远是宿主。两种形态选一种。

**① 自己写字节**：`Presenter` 装配好一整片，宿主一次写出去。

```zig
var p = try farewell.Presenter.init(alloc, size, caps, .half);
defer p.deinit();

while (running) {
    try p.resize(host.refreshSize());            // 尺寸没变时是空操作
    const bytes = try p.drawDiff(farewell.sampler(&scene), .{});
    if (bytes.len > 0) try host.write(bytes);    // 没变化时不用写
}
```

`resize` 之后的第一帧一定是整帧；`drawDiff` 返回的切片在下次 `draw`/`resize`/`deinit`
前有效。切档就改 `p.want`，再用 `farewell.select(caps, want)` 让能力位修正它。
`demo/host.zig` 是完整的参考实现，它只做四件事：问尺寸、读一个键、进 raw mode、
一帧写一次。

**② 已经有事件循环**：把 cell 画进宿主的容器，diff、写入、同步输出都交给它。

```zig
const Canvas = struct {
    w: u16,
    h: u16,
    win: vaxis.Window,
    glyphs: []u8, // 4 字节/cell，跨帧复用

    pub fn size(self: Canvas) farewell.Size {
        return .{ .cols = self.w, .rows = self.h };
    }

    pub fn put(self: *Canvas, x: u16, y: u16, c: farewell.Cell) void {
        const off = (@as(usize, y) * self.w + x) * 4;
        const n = std.unicode.utf8Encode(c.cp, self.glyphs[off..][0..4]) catch unreachable;
        self.win.writeCell(x, y, .{
            .char = .{ .grapheme = self.glyphs[off..][0..n], .width = 1 },
            .style = .{
                .fg = .{ .rgb = .{ c.fg.r, c.fg.g, c.fg.b } },
                .bg = .{ .rgb = .{ c.bg.r, c.bg.g, c.bg.b } },
                .bold = c.attr.bold,
                .dim = c.attr.dim,
                .italic = c.attr.italic,
                .blink = c.attr.blink,
                .reverse = c.attr.reverse,
                .strikethrough = c.attr.strike,
                .ul_style = if (c.attr.underline) .single else .off,
            },
        });
    }
};

farewell.render(farewell.sampler(&scene), .half, &canvas, .{ .uv = .square });
```

sink 的契约只有两条：`size() Size` 和 `put(x, y, Cell)`。`farewell.Grid` 自己就满足，
所以「先画进 Grid 再用」也不需要适配器。

用 vaxis 当例子，三点要留意（换别的宿主同理）：

- **字形字节要活得比 `put` 久**。vaxis 的 `Cell.char.grapheme` 是切片，写进去只存指针，
  真正读是在它 render 的时候；所以按 `4 字节/cell` 预分配、跨帧复用。
- **颜色是单向的**。我们只有具体 RGB，vaxis 的 `Color.default`（跟随主题）我们表达不
  出来；反方向会丢语义，所以不提供映射回来。
- **下划线**在 vaxis 里不是 bool，是 `ul_style`；其余七个属性一一对应。

## 后处理

`blit` 把像素变成格，`ansi` 把格变成字节，中间那一段是后处理。效果就是**带方法的类型**，按元组传给绘制调用：

```zig
const quantised = farewell.quant.Fixed{ .table = .xterm256 };
const bytes = try p.drawDiff(farewell.sampler(&scene), .{&quantised});
```

声明哪个方法就进哪个阶段：

| 方法 | 时机 | 能看见 |
| --- | --- | --- |
| `cell(self, c, x, y) Cell` | 每格产出时 | 这一格 + 位置 |
| `grid(self, g, shown) void` | 整帧渲染完、编码前 | 整帧 + 上一帧（`shown`） |

顺序就是元组顺序，`.{}` 表示不做后处理（那条路径与没有这个功能时逐字节相同）。作者自己的效果是十行：

```zig
const Invert = struct {
    pub fn cell(_: *const Invert, c: farewell.Cell, _: u16, _: u16) farewell.Cell {
        return .{ .cp = c.cp, .attr = c.attr, .fg = sub(c.fg), .bg = sub(c.bg) };
    }
};
```

量化自带一个效果（`quant.Fixed`）：把每格颜色吸附到调色板，并声明 `palette()`，编码器据此写
`38;5;N` 而不是 `38;2;r;g;b`。没有声明就写真彩色——效果的输出和编码方式只有一个真相源。

### 抖动

`quant.Fixed` 只回答「最近的是哪个槽位」。在它旁边还有一个问题：**能不能用两个槽位把一个颜色
平均出来**。`quant.mix` 找的是这样一对：沿两点连线取 `fraction` 得到的平均值，离原色最近；
找不到更好的就退回单色（`fraction = 0`）。候选只取该颜色所在的立方体格、它的六个面邻居、
以及灰阶两侧——面邻居总比角邻居近，所以次近槽位必在其中。

`dither.Bayer` 把这件事铺到格子上：

```zig
const bayer = farewell.dither.Bayer{ .table = .xterm256, .matrix = .x8 };
const bytes = try p.drawDiff(farewell.sampler(&scene), .{&bayer});
```

阈值只由位置决定，落在 `fraction` 以下的格取 `alt`，其余的取 `slot`。所以一个 tile 的
平均值就是你画的颜色，而原来撞在同一个槽位上的相邻格现在分担了两个槽位——色阶变成了网点。

256 色灰阶从 0 走到 255，整块 tile 的平均误差最坏是 **8 级（不抖）→ 0.5 级（`bayer4`）
→ 0.13 级（`bayer8`）**。代价照实说：**不在槽位上的纯色也会被抖成网点**，在 10×20 px 的
cell 上这很扎眼，字节也会从 9.6 KB/帧 涨到 28 KB/帧（见下面的实测）。所以默认关闭，
要不要换这点质感由画面决定。

它敢放进逐格阶段，仍是因为那条约束：阈值是 `(x, y)` 的纯函数。时间抖动要用帧号，会把
`row_skip` diff 弄错，仍然得等 M6d。

两条约束：

- **逐格效果必须是 `(cell, x, y)` 的纯函数**。`prev` 里存的是后处理之后的格，diff 拿它和新帧比；
  带历史状态的逐格效果会让 diff 误判（时间抖动因此要单独设计）。
- **整帧效果可以改几何**（读写两份格），逐格效果只能改格本身。

## 符号匹配

`ascii` 档一格一个样本，只能回答「多黑」；一个样本分不清「上暗下亮」和「均匀中灰」。
`ink` 档把一格拆成网格采样，于是能问形状：

```zig
farewell.render(farewell.sampler(&scene), .ink, &grid, .{});
```

每格做四件事：取通道跨度最大的那端两色 → 把采样按「离谁近」压成一张剪影位图 →
在字形表里按 Hamming 距离取前 `work` 个候选 → 每个候选用**它自己的**两组均值重算两色、
算重建误差，取最小。

关键在最后一步：**字形决定形状，两个均值决定颜色**。一个 50% 灰的格子会拿到约 50% 覆盖的
字形、配上两个只差一点的灰——这才是「抗锯齿」，亮度斜坡表达不了这个。

### 网格是一族选项

`ink` 是 8×8 = 64 个采样，`ink16` 是 8×16 = 128 个（在 10×20 的 cell 里子格变成正方形，
字母的墨迹从三行变成六行）。两者共用一套匹配器，网格是它的编译期参数，档位就是选择方式。

**实测之后要泼一盆冷水**：8×16 不带来精度。拿 600 个合成格子（边缘、渐变、圆盘、噪声）
比较重建误差，两者都按 8×16 还原到同一个源上：

| 图案 | 8×8 误差 | 8×16 误差 | 比值 |
| --- | --- | --- | --- |
| 边缘 | 800,308 | 799,285 | 1.001 |
| 渐变 | 484,803 | 484,761 | 1.000 |
| 圆盘 | 830,134 | 843,149 | 0.985 |
| 噪声 | 144,052 | 153,051 | 0.941 |

**这一层的瓶颈不是网格，是一格两种颜色。** 加一行只是把边界挪半行，而残差的大头是
「一侧内部的颜色散布」，两色压不下去。噪声上 8×16 反而更差——8×8 的两行平均本身就在降噪。
所以 `ink16` 的意义是「同一个匹配器的另一个网格」，不是一个应许的升级。

### 表

表分两半，`src/ink.zig` 里各占一段：

| 来源 | 内容 | 数量 |
| --- | --- | --- |
| comptime 算 | U+2580..U+259F 块字符（定义就是格子的 k/8，网格行数是 8 的倍数时一格一档） | 28 |
| 字体里量 | ASCII 0x20..0x7E | 93（8×8）/ 95（8×16） |

块字符必须算：量出来的话 `U+2584` 和 `U+2585` 会落到同一张掩码上，色调阶梯直接塌一档。
ASCII 只能量。量需要字体光栅化，所以生成器是 `tools/inkmap.py`（Pillow），生成物入库，
`zig build` 不碰 Python：

```sh
zig build inkmap         # 重新生成两张表
zig build inkmap-check   # 表和工具是否脱节（CI 每次 push 都查）
```

两条约束：`.ink`/`.ink16` 与 `.ascii` 的 `ramp` 无关；平坦格子会选空格、`fg == bg`，
**不许在纯色区域长网点**，有测试守着。

代价（120×36，见下面的实测）：匹配器本身约 1.0 µs/格（8×8）、约 2.0 µs/格（8×16），
而且一格要 64 或 128 次采样——源越贵这一档越贵。
细节（表怎么生成、网格怎么选、许可证上怎么划线）见 [符号墨量匹配](docs/ink-matching.md)。

顺带把 `ascii` 档的一个老毛病量化了：它的 `bg` 恒为黑，字形只盖住格子的一部分，所以同一张
渐变它的平均亮度只有源的 **11%**（14,15,10 对 128,128,100）。`ink` 两色都取自源，平均亮度
是 124,126,97——和 `half` 一样准，因为它的「两色」本来就是两半的均值。
## 帧预算

`Presenter` 不知道时间。宿主把每帧的两段耗时喂给 `Pacer`，它只回答"该动什么"：

```zig
var pacer = farewell.Pacer.init(.{
    .fps = 60,
    .levels = modes.len,          // 本宿主能渲染的档位数量，0 最省
    .level = start_level,
}, caps.terminal.sync_output);

// 每帧
const budget = pacer.budgetNs();
const bytes = try p.drawDiff(farewell.sampler(&scene), .{});
if (bytes.len > 0) try host.write(bytes);

switch (pacer.observe(.{ .render_ns = render, .write_ns = write })) {
    .slower, .faster => {},                            // 读 pacer.fps
    .coarser, .finer => setMode(modes[pacer.level]),   // 读 pacer.level
    .keep => {},
}
```

三条策略：

- **滞回**：连续 3 帧超预算才动手，连续 30 帧有余量才回升。一次慢写是噪声，不是判决。
- **先降帧率，再降档**：60 → 45 → 34 → 26 → 20 → 15，到地板才动档位；回升反过来走，
  档位先回来，帧率后回来。
- **没有原子提交就限速**：终端不支持 mode 2026 时帧率上限 30。没有原子提交，画得越快，
  看到半帧的机会越多。`--caps=+sync_output` 解除这个上限。

（`host.write` 和 `setMode` 是宿主的活儿，这里只是示意。）

`Pacer` 不碰字节数：它判的是"这一帧在不在它的间隔里"，字节由宿主自己记账。

## 构建

```sh
zig build test
zig build -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast
zig build fmt
```

交互模式下 demo 占满窗口：`q` / `Esc` / `Ctrl-C` 退出，空格暂停，`+` / `-` 沿密度阶梯换档。
其余开关：

```sh
zig build run -Doptimize=ReleaseFast -- --frames=120 --fps=60
```

| 开关 | 含义 |
| --- | --- |
| `--frames=N` | 跑满 N 帧就退出；没有 tty 时会自动走这条路 |
| `--fps=N` | 目标帧率，`0` 表示不节流 |
| `--mode=NAME` | 起始档位：`ascii` `bars` `half` `quad` `sextant` `braille` `ink` `ink16` |
| `--caps=SPEC` | 覆盖能力位，例如 `--caps=+sync_output,-octant` |
| `--color=MODE` | `auto`（默认，终端不支持真彩时才走 256）、`truecolor`、`256` |
| `--dither=MODE` | `off`（默认）、`bayer2`、`bayer4`、`bayer8`；隐含 256 色 |
| `--size=COLSxROWS` | 没有 tty 时的回退尺寸（默认 `80x24`），用来复现下面的实测表 |
| `--scene=NAME` | `raymarch`（默认）或 `gradient`；后者是廉价源，用来把档位开销和场景开销分开 |

退出时往 stderr 打一行：帧数、实际 fps、render 与 write 各自的毫秒数、每帧字节、
每 cell 字节、每帧 SGR 条数、最终档位与尺寸、超预算的帧数、pacer 最后定下的帧率
（`0` 表示不节流）。

沙箱环境需要额外指定缓存目录，见 `AGENTS.md`。

## 实测（ReleaseFast，raymarch 48 步）

CPU 侧在 pty 上量；写耗时只有真实终端里才有意义，`zig build run` 退出时那行会把
render 与 write 分开给出。

| 尺寸 | render/帧 | 字节/帧 | 字节/cell |
| --- | --- | --- | --- |
| 120×36 = 4,320 cell | 1.36 ms | 19,604 | 4.5 |
| 200×50 = 10,000 cell | 3.14 ms | 42,101 | 4.2 |

字节/cell 取决于画面：平坦区域只付一个字符（3 字节），渐变更贵，所以更大的网格反而
更便宜。任何固定常数（比如「36 字节/cell」）都会给出错误预算。

色深是比密度更大的杠杆。同一场景、同一尺寸（120×36），同一时段，四种输出：

| 输出 | render/帧 | 字节/帧 | SGR/帧 |
| --- | --- | --- | --- |
| 真彩色 | 1.58 ms | 19,640 | 416 |
| 256 | 1.64 ms | 9,620 | 170 |
| 256 + `--dither=bayer4` | 2.10 ms | 27,997 | 1,173 |
| 256 + `--dither=bayer8` | 2.23 ms | 28,763 | 1,193 |

省的不只是每条 SGR 的字节——量化后相邻格更容易撞成同一个槽位，每帧 SGR 从 416 条降到
170 条。抖动把这个方向反过来：它把撞在一起的格重新拆开，字节涨到真彩色之上，SGR 涨七倍。
这是抖动的价目表，不是它的缺陷——买的是那 8 级色阶。

符号匹配的价比性要分两笔算。同一尺寸（120×36），先看一个廉价源（`--scene=gradient`），
它把「采样」和「匹配」分开：

| 场景 | 档位 | render/帧 | 字节/帧 |
| --- | --- | --- | --- |
| gradient | `ascii` | 0.06 ms | 673 |
| gradient | `half` | 0.07 ms | 1,311 |
| gradient | `ink` | 4.55 ms | 1,311 |
| gradient | `ink16` | 8.28 ms | 1,311 |
| raymarch | `half` | 1.56 ms | 19,617 |
| raymarch | `ink` | 39.6 ms | 20,640 |
| raymarch | `ink16` | 46.3 ms | 21,292 |

两个 ink 档在渐变上的字节数完全相同（1,311）：它们选出来的都是上下半块、颜色都是两半的
均值，也就是**这一档在平滑区域不会比 `half` 多花一个字节**。

**匹配器本身约 1.0 µs/格（8×8）、约 2.0 µs/格（8×16）**：gradient 那几行隔离出来的就是它。
raymarch 那行的 40 ms 里约 35 ms 是场景被求值 64 次，不是匹配器的账——`Frame` 源每样本
只是内存读，代价会低一个数量级。所以「ink 有多贵」取决于源有多贵，这类数字必须连着源一起给。

一个旁证：平滑渐变上 ink 的字节数和 `half` 完全一样（1,311），因为它选出来的就是上下
半块、颜色就是两半的均值。这一档不会在平滑区域凭空长纹理。

（`--size=120x36 --frames=120` 在无 tty 时也能复现这些表；有 tty 时尺寸由终端决定。）

## 状态与路线

M0–M3 完成：像素进、ANSI 字节出的链路已经闭合。`caps` 决定用哪档密度，
`Presenter` 负责一帧的装配与一次写出，demo 直接跑在真实终端上。M5（帧预算）、
M6a（量化）、M6b（抖动）、M6c（符号匹配）也已完成。

下一步见 [ROADMAP.md](ROADMAP.md)。

## License

MIT
