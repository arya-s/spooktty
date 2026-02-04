# Phantty vs Ghostty: Architecture Differences

Comparison of Phantty's rendering architecture against Ghostty's, after the
`research/ghostty-rendering-architecture` branch changes.

## What We Match

| Area | Status | Notes |
|------|--------|-------|
| IO thread per surface | ✅ | 1KB reads, blocking ReadFile, lock per chunk |
| Split lock pattern | ✅ | Cell rebuild under mutex, GL draw outside |
| Font atlas (skyline packing) | ✅ | reserve/set/grow, 1px padding |
| Instanced rendering | ✅ | Separate BG/FG passes, glDrawArraysInstanced |
| Dirty tracking flags | ✅ | terminal.flags.dirty, screen.dirty, row.dirty, page.dirty |
| CancelIoEx for tab close | ✅ | Matches Ghostty's termio/Exec.zig |
| rowIterator for cell building | ✅ | Direct page memory access, no per-cell getCell() |

## Remaining Differences

### 1. No RenderState Copy (Major)

**Ghostty**: `RenderState` (`terminal/render.zig`) copies terminal row data into
its own `MultiArrayList(Row)` with per-row arenas during `update()`. `rebuildCells`
then works entirely on this copy — never touches the terminal under the lock.

**Us**: `rebuildCells` reads directly from terminal page memory. The lock is held
for the entire rebuild + state read.

**Impact**: Our lock hold time includes the full rebuild (~350-500µs). Ghostty's
critical section is just a fast memcpy of row data.

### 2. Flat Cell Arrays vs Per-Row FG Lists (Moderate)

**Ghostty**: `Contents` (`renderer/cell.zig`) uses `bg_cells[row * cols + col]`
(flat grid, one entry per cell) for BG, and `fg_rows` (per-row
`ArrayList(CellText)`) for FG. This enables partial row rebuild — only dirty rows
get their FG list regenerated.

**Us**: Flat `bg_cells[]` and `fg_cells[]` arrays, appended sparsely. No per-row
structure — we rebuild everything or nothing.

**Impact**: Can't do partial row rebuild. Fine for normal use (350-500µs full
rebuild) but could matter for very large terminals.

### 3. Cell Struct Size (Minor)

**Ghostty**: `CellText` is 32 bytes (grid pos as `u16`, colors as `u8`, packed
fields). `CellBg` is 4 bytes (`[4]u8` RGBA).

**Us**: `CellFg` is 52 bytes (13 × f32). `CellBg` is 20 bytes (5 × f32).

**Impact**: ~2x more GPU bandwidth per cell. For a 200×50 grid, ~520KB vs ~320KB
per frame upload. Not a bottleneck but wasteful.

### 4. BG Cell Storage (Minor)

**Ghostty**: Fixed-size flat grid — every cell has a BG entry (default = 0,0,0,0).

**Us**: Sparse — only cells with non-default backgrounds get entries.

### 5. No draw_mutex (Minor)

**Ghostty**: Separate `draw_mutex` for GPU operations, decoupled from the terminal
state mutex.

**Us**: No separate draw mutex — GL work runs on the main thread only.

**Impact**: None currently. Would matter if we added a separate render thread.

### 6. No Viewport Pin Tracking (Known Issue)

**Ghostty**: Stores `viewport_pin` in `RenderState`, compares each frame to detect
`scrollClear` and scroll position changes.

**Us**: Track `viewport == .active` but not the actual pin position. This causes
`clear` after `cat /dev/urandom` to sometimes not fully repaint.

### 7. Monolithic main.zig (Structural)

**Ghostty**: Rendering split across `generic.zig` (3620 lines), `OpenGL.zig` (461),
`cell.zig` (680), `render.zig` (1464), `shaders.zig`.

**Us**: `main.zig` is ~4200 lines containing window management, input, rendering,
cell building, shaders, debug overlay, titlebar, post-processing.

### 8. No Color Emoji Atlas (Feature Gap)

**Ghostty**: Separate atlas textures for grayscale glyphs vs color emoji
(`CellText.Atlas` enum).

**Us**: Single grayscale atlas. No color emoji support.

### 9. No Minimum Contrast (Feature Gap)

**Ghostty**: `minimum-contrast` config adjusts FG color for readability against BG.

**Us**: No contrast adjustment.

### 10. No Synchronized Output (Feature Gap)

**Ghostty**: Checks `synchronized_output` terminal mode — pauses rendering while
the application is batching updates (DEC private mode 2026).

**Us**: No synchronized output support. Could cause visual tearing for TUI
frameworks that use it.
