# Plan: Ghostty-Inspired Rendering Architecture for Phantty

## Problem Statement

Phantty currently has everything in a single `main.zig` (3700+ lines) on a
single thread. Running high-throughput commands locks up the UI. Each glyph
is a separate draw call with its own texture. No dirty tracking.

## Current Inefficiencies

1. **Single-threaded**: PTY read blocks rendering, rendering blocks PTY read
2. **One draw call per glyph**: O(rows*cols) draw calls per frame
3. **One texture per glyph**: No font atlas
4. **No dirty tracking**: Full grid re-rendered every frame
5. **Cell-by-cell read**: `screen.pages.getCell()` per cell (pointer chasing)
6. **Font fallback on render thread**: DirectWrite calls during rendering
7. **Monolithic file**: 3700+ lines in main.zig, no module separation

## Target File Structure

Modeled after Ghostty's module layout, adapted for our simpler needs:

```
src/
  main.zig              -- entry point, window creation, event loop (slim)
  Surface.zig           -- a terminal surface (owns PTY, terminal, IO thread)
  renderer.zig          -- module root, re-exports
  renderer/
    OpenGL.zig           -- OpenGL-specific GPU code (atlas texture, buffers, shaders)
    State.zig            -- shared render state (mutex, terminal pointer)
    cell.zig             -- GPU cell data types (CellBg, CellFg)
    cursor.zig           -- cursor rendering logic
    size.zig             -- grid/screen/cell size types
  termio.zig             -- module root, re-exports
  termio/
    Thread.zig            -- IO reader thread (blocking ReadFile loop)
  font/
    Atlas.zig             -- font atlas (glyph packing, UV lookup)
    sprite.zig            -- (existing) sprite/box drawing
    sprite/               -- (existing) sprite draw modules
    embedded.zig          -- (existing) embedded font data
  config.zig             -- (existing) configuration
  config_watcher.zig     -- (existing) config file watcher
  directwrite.zig        -- (existing) DirectWrite font discovery
  pty.zig                -- (existing) ConPTY wrapper
  win32.zig              -- (existing) Win32 backend
  themes.zig             -- (existing) theme definitions
```

## Architecture

```
Per-Surface IO Thread            Main Thread (shared)
+---------------------------+    +----------------------------------+
| termio/Thread.zig         |    | main.zig                         |
| blocking ReadFile() loop  |    | pollEvents()                     |
| lock surface.state.mutex  |    | for each visible surface:        |
|   vtStream.nextSlice()    |    |   if surface.dirty (atomic):     |
|   set dirty flag (atomic) |    |     lock mutex briefly            |
| unlock mutex              |    |     snapshot terminal state       |
+------------+--------------+    |     unlock mutex                  |
             |                   |     rebuildCells (dirty rows only) |
             | mutex             |   batch draw (2 draw calls)       |
             +-- brief --------->| swapBuffers()                     |
                                 +----------------------------------+
```

A Surface owns a PTY, terminal, and IO thread. Tabs hold one Surface;
splits will hold multiple later.

## Implementation Plan

Each phase ends with a **build + run check**. We do NOT proceed to the
next phase until the current one compiles and runs correctly.

---

### Phase 1: Module Extraction + Surface Abstraction

**Goal**: Break `main.zig` into proper modules. Introduce Surface. No threading yet.

**Step 1a -- Extract renderer module**:
- Create `src/renderer.zig` (module root with re-exports)
- Create `src/renderer/size.zig` -- move cell_width/height/baseline types
- Create `src/renderer/cursor.zig` -- move `renderCursor()`, cursor types
- Create `src/renderer/cell.zig` -- define `CellBg`, `CellFg` types (empty for now, populated in Phase 4)
- Create `src/renderer/State.zig` -- the shared state struct:
  ```zig
  pub const State = struct {
      mutex: std.Thread.Mutex = .{},
      terminal: *ghostty_vt.Terminal,
  };
  ```
- Create `src/renderer/OpenGL.zig` -- move shader compilation, buffer init, glyph rendering, quad rendering

**Step 1b -- Extract font atlas module**:
- Create `src/font/Atlas.zig` -- stub for now (will be implemented in Phase 3)
- Keep existing `src/font/sprite.zig` and `src/font/embedded.zig` as-is

**Step 1c -- Extract termio module**:
- Create `src/termio.zig` (module root)
- Create `src/termio/Thread.zig` -- stub for now (will be implemented in Phase 2)

**Step 1d -- Create Surface.zig**:
- Create `src/Surface.zig` that owns:
  - `terminal: ghostty_vt.Terminal`
  - `pty: Pty`
  - `selection: Selection`
  - `render_state: renderer.State`
  - `dirty: std.atomic.Value(bool)`
  - OSC title state
  - `io_thread: ?std.Thread` (null for now)
- `TabState` in main.zig becomes:
  ```zig
  const TabState = struct {
      surface: *Surface,
  };
  ```

**Step 1e -- Slim down main.zig**:
- main.zig keeps: entry point, window creation, event loop, tab management, titlebar rendering
- All terminal rendering delegated to `Surface.render()` or similar
- All GPU setup delegated to `renderer.OpenGL`

**Verification**: `zig build -Duse_win32=true && zig-out\bin\phantty.exe` -- everything works exactly as before. This is a pure refactor with no behavior changes.

---

### Phase 2: IO Thread -- Decouple PTY Reading

**Goal**: Each Surface gets a dedicated IO reader thread. Main thread only renders.

**Files**: `src/Surface.zig`, `src/termio/Thread.zig`

1. Implement `src/termio/Thread.zig`:
   - `threadMain(surface: *Surface)` function
   - Blocking `ReadFile` loop on `surface.pty.pipe_in_read`
   - On data: lock `surface.render_state.mutex`, feed through `vtStream().nextSlice()`, scan for OSC titles, set `surface.dirty.store(true, .release)`, unlock
   - On EOF/error: set `surface.exited = true`, break
2. In `Surface.init()`: spawn IO thread, store handle in `surface.io_thread`
3. In `Surface.deinit()`: close read pipe to unblock `ReadFile`, join thread
4. Main loop changes:
   - Remove PTY polling block
   - Before rendering a surface: check `dirty.swap(false, .acquire)`
   - Lock mutex only during terminal state read, unlock before GPU work
5. Background tabs: IO threads keep running (draining PTY data even when not visible)

**Verification**: Build and run. Multiple tabs work. High-throughput output doesn't freeze UI. Tab switching is instant.

---

### Phase 3: Font Atlas

**Goal**: Replace per-glyph textures with a single font atlas.

**Files**: `src/font/Atlas.zig`, `src/renderer/OpenGL.zig`

1. Implement `src/font/Atlas.zig`:
   - `init()`: allocate 1024x1024 `u8` buffer, create GL texture
   - `addGlyph(bitmap, width, height) -> AtlasRegion` -- pack glyph, return UV rect
   - Row-based packing (left-to-right, new row when full)
   - `modified: bool` flag, `sync()` to upload dirty region via `glTexSubImage2D`
   - `getUV(region) -> {u0, v0, u1, v1}`
2. Modify `Character` struct: replace `texture_id` with `AtlasRegion`
3. `loadGlyph()` in OpenGL.zig: render with FreeType, add to atlas instead of creating texture
4. Font fallback: skip rendering missing glyphs (empty cell). No DirectWrite on render path.
5. Delete per-glyph `glGenTextures`/`glDeleteTexture`

**Verification**: Build and run. ASCII text looks correct. Colors work. No visual regressions.

---

### Phase 4: Batched Draw Calls

**Goal**: 2 draw calls per frame instead of O(rows*cols).

**Files**: `src/renderer/OpenGL.zig`, `src/renderer/cell.zig`

1. Define cell types in `cell.zig`:
   ```zig
   pub const CellBg = extern struct {
       grid_col: u16, grid_row: u16,
       r: f32, g: f32, b: f32,
   };
   pub const CellFg = extern struct {
       grid_col: u16, grid_row: u16,
       glyph_offset_x: f32, glyph_offset_y: f32,
       glyph_size_x: f32, glyph_size_y: f32,
       uv_x: f32, uv_y: f32, uv_w: f32, uv_h: f32,
       r: f32, g: f32, b: f32,
   };
   ```
2. CPU-side cell buffers in OpenGL.zig (pre-allocated for max grid size)
3. New instanced shaders:
   - BG: vertex expands grid position to quad, fragment uses flat color
   - FG: vertex expands grid position to quad + glyph offset, fragment samples atlas
4. `rebuildCells(surface)`: iterate terminal grid, fill bg/fg buffers
5. `drawFrame()`: upload buffers, 2x `glDrawArraysInstanced`
6. Cursor and selection integrated into the cell buffers

**Verification**: Build and run. Rendering identical. Test colors, cursor, selection. Check FPS improvement.

---

### Phase 5: Dirty Row Tracking

**Goal**: Only rebuild GPU cells for changed rows.

**Files**: `src/Surface.zig`, `src/renderer/OpenGL.zig`

1. Per-row dirty tracking:
   - Use ghostty_vt's `Page.dirty` / `Row.dirty` flags if exposed
   - Otherwise track in Surface: `row_dirty: [MAX_ROWS]bool`
2. `rebuildCells` checks dirty state:
   - `.false` -> skip entirely, reuse previous GPU buffers
   - `.partial` -> only rebuild dirty rows in CPU buffer, upload sub-region
   - `.full` -> rebuild everything (resize, screen switch)
3. `drawFrame` early-out: if no cells rebuilt and no size change, skip GPU upload
4. Static terminal = zero per-frame CPU work

**Verification**: Build and run. Static terminal has minimal CPU. Interactive typing updates only affected rows. High-throughput maintains FPS.

---

## Files Created/Modified Summary

| File | Status | Description |
|------|--------|-------------|
| `src/main.zig` | Modified | Slimmed to entry point + event loop + tab management |
| `src/Surface.zig` | **New** | Terminal surface (PTY, terminal, IO thread, render state) |
| `src/renderer.zig` | **New** | Renderer module root |
| `src/renderer/OpenGL.zig` | **New** | GL shaders, buffers, atlas sync, draw calls |
| `src/renderer/State.zig` | **New** | Shared render state (mutex + terminal pointer) |
| `src/renderer/cell.zig` | **New** | GPU cell data types |
| `src/renderer/cursor.zig` | **New** | Cursor rendering logic |
| `src/renderer/size.zig` | **New** | Size/dimension types |
| `src/termio.zig` | **New** | Termio module root |
| `src/termio/Thread.zig` | **New** | IO reader thread |
| `src/font/Atlas.zig` | **New** | Font atlas (glyph packing + GL texture) |
| `src/pty.zig` | Minor | Possibly small changes for thread safety |

## Build & Run Verification (after EVERY phase)

```
zig build -Duse_win32=true && zig-out\bin\phantty.exe
```

Checklist per phase:
- [ ] Program builds without errors
- [ ] Terminal opens and shows shell prompt
- [ ] Can type commands and see output
- [ ] Can create/close/switch tabs (Ctrl+T, Ctrl+W, Ctrl+Tab)
- [ ] High-throughput output doesn't lock UI (Phase 2+)
- [ ] FPS overlay shows stable frame rate
- [ ] Colors render correctly
- [ ] Cursor blink works
- [ ] Window resize works
- [ ] Selection works
