# mosaic

把一帧像素变成终端字节，并选对技法。

M0 只做**与终端能力无关的核心**：把 `(采样) → cell → 字节` 这条管线打通，并证明它够快、够省。

```
Source ──blitter──> Grid ──transport──> bytes ──> tty
         CPU 受限              带宽受限
```

## 已实现

| 模块 | 内容 |
|---|---|
| `types` | `RGB` `Cell` `Grid` `Mode`（密度表：ascii 1x1 / bars 1x4 / half 1x2 / quad 2x2 / sextant 2x3 / braille 2x4） |
| `source` | `Frame`（像素缓冲）、`Sampler`（程序化求值）、`sampler(&scene)` 绑定器 |
| `blit` | 各档打包器；`render(src, comptime mode, ...)`；`renderAny(src, mode, ...)` 用 `inline else` 保持零成本 |
| `emit` | SGR 合并（fg+bg 一条）、CRLF 换行、`row_skip` 按行 diff |

## 关键设计

**一个入口，两种源。** `render` 只要求源提供 `at(u, v) RGB`：

```zig
mosaic.render(&frame, .braille, &grid, .{});
mosaic.render(mosaic.sampler(&scene), .half, &grid, .{ .uv = .square });
```

**模式可以是运行时的，仍然零成本：**

```zig
mosaic.renderAny(src, caps.mode, &grid, .{});   // 展开成 6 份特化
```

**`uv` 有两种语义**：`.stretch` 铺满网格（图片），`.square` 居中正方、按 `cell_px` 校正纵横比（程序化场景，圆就是圆）。

## 实测（ReleaseFast, 120x36 = 4320 cell）

| 指标 | 值 |
|---|---|
| raymarch（48 步 × 2 采样/cell） | **4.0 ms/帧**（≈247 fps） |
| 字节/帧 | 23,273 |
| 字节/cell | **5.4**（大面积同色被 SGR 状态跟踪吃掉） |

作为对比：VinZ 每 cell 无条件重发两条 SGR，实测 37.5 字节/cell。同样的画面，mosaic 在平坦区域只花 3 字节（就是字符本身）。

## 构建

```sh
export ZIG_GLOBAL_CACHE_DIR=../.zig/global
export ZIG_LOCAL_CACHE_DIR=../.zig/local
zig build test
zig build -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast
```

`zig build` 需要写全局缓存；沙箱环境把它指到工作区内即可。

## 下一步

- `caps`：终端能力（rgb/sixel/kitty/2026）与字体能力（braille/sextant/octant）分开，带回退与覆盖
- `transport.sixel`
- `pacer`：按字节预算降档（实测 Alacritty 通道 ~1 MB/s，WT ~3.8 MB/s）
