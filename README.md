# farewell

终端图形库：像素进，ANSI 字节出。
用于创作终端艺术。

```
Source ──blit──> Grid ──ansi──> bytes ──> tty
        CPU 受限        带宽受限
```

M0 只做与终端能力无关的核心：把这条管线打通，并证明它够快、够省。

## 模块

| 文件 | 内容 |
| --- | --- |
| `src/types.zig` | `RGB` `Cell` `Grid` `Mode`（ascii / bars / half / quad / sextant / braille 的密度表） |
| `src/source.zig` | `Frame`、`Sampler`、`sampler(&scene)` 绑定器 |
| `src/blit.zig` | 各档打包器；`render`、`renderAny` |
| `src/ansi.zig` | SGR 合并、CRLF 换行、`row_skip` 按行 diff |

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

## 构建

```sh
zig build test
zig build -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast
zig build fmt
```

沙箱环境需要额外指定缓存目录，见 `AGENTS.md`。

## 实测（ReleaseFast，120×36 = 4320 cell）

| 指标 | 值 |
| --- | --- |
| raymarch 48 步 × 2 采样/格 | 4.0 ms/帧 |
| 字节/帧 | 23,273 |
| 字节/cell | 5.4 |

字节/cell 取决于画面：平坦区域只付一个字符（3 字节），渐变更贵。任何固定常数
（比如「36 字节/cell」）都会给出错误预算。

## 下一步

- `caps`：终端能力（rgb / sixel / kitty / 2026）与字体能力（braille / sextant / octant）
  分开，带默认值与覆盖
- `transport.sixel`
- `pacer`：按字节预算降档

## License

MIT
