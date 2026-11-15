# farewell

终端图形库：像素进，ANSI 字节出。
用于创作终端艺术。

```
Source ──blit──> Grid ──ansi──> bytes ──> tty
        CPU 受限        带宽受限
```

管线本身不碰终端：能力位由调用方给，字节由调用方写。

## 模块

| 文件 | 内容 |
| --- | --- |
| `src/types.zig` | `RGB` `Cell` `Grid` `Size` `Mode`（ascii / bars / half / quad / sextant / braille 的密度表） |
| `src/source.zig` | `Frame`、`Sampler`、`sampler(&scene)` 绑定器 |
| `src/blit.zig` | 各档打包器；`render`、`renderAny` |
| `src/ansi.zig` | SGR 合并、CRLF 换行、`row_skip` 按行 diff |
| `src/caps.zig` | 终端与字体能力位、来源轨迹、覆盖语法、降级阶梯 |
| `src/present.zig` | 帧装配：grid + 模式 + 缓冲，整帧一次写出 |

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
    const bytes = try p.drawDiff(farewell.sampler(&scene));
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
| `--mode=NAME` | 起始档位：`ascii` `bars` `half` `quad` `sextant` `braille` |
| `--caps=SPEC` | 覆盖能力位，例如 `--caps=+sync_output,-octant` |

退出时往 stderr 打一行：帧数、实际 fps、render 与 write 各自的毫秒数、每帧字节、
每 cell 字节、最终档位与尺寸、超预算的帧数。

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

## 状态与路线

M0–M3 完成：像素进、ANSI 字节出的链路已经闭合。`caps` 决定用哪档密度，
`Presenter` 负责一帧的装配与一次写出，demo 直接跑在真实终端上。

下一步见 [ROADMAP.md](ROADMAP.md)。

## License

MIT
