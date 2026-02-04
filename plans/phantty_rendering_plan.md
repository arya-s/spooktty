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

After each phase builds successfully, the LLM must present **2–3 manual
test cases** to the user so they can verify the phase works as intended
before moving on. Test cases should be concrete actions the user can
perform in the running terminal, with expected observable outcomes.

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

**Manual test cases** (tell the user these after the phase builds):
1. **Basic operation**: Open phantty, type a command (`dir` or `ls`), see output. Open a second tab with Ctrl+Shift+T, switch between them. Close a tab with Ctrl+W. This confirms the Surface abstraction didn't break tab lifecycle.
2. **Tab titles**: Run a command that changes the working directory (`cd ..`). Verify the tab title updates in the titlebar. This confirms OSC title scanning still works after moving to Surface.zig.
3. **Config hot-reload**: Press Ctrl+, to open the config, change the theme or font-size, save. Verify it applies live. This confirms the config reload path works through the new module boundaries.

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

**Manual test cases** (tell the user these after the phase builds):
1. **High-throughput flood**: Open two tabs. In tab 1, run a flood command (PowerShell: `1..100000 | ForEach-Object { $_ }`; WSL: `yes | head -100000`). While it's running, Ctrl+Tab to tab 2. Verify you can type immediately — the UI should not freeze. Switch back to tab 1; output should have continued accumulating.
2. **Background tab draining**: In tab 1, start `ping -t localhost`. Switch to tab 2, wait 5 seconds, switch back. Verify output kept accumulating while you were away — no burst of catch-up, no stalled output.
3. **Clean shutdown under load**: Run a long-running command (`ping -t localhost`), then close the tab with Ctrl+W or close the window entirely. Verify it shuts down promptly with no hang — the IO thread should unblock and join cleanly.

---

### Phase 3: Font Atlas

**Goal**: Replace per-glyph textures with a single font atlas. Modeled after
Ghostty's `src/font/Atlas.zig` -- a lazy, on-demand 2D rectangle bin packer
with atomic dirty tracking for GPU sync.

**Files**: `src/font/Atlas.zig`, `src/renderer/OpenGL.zig`

**Reference**: Ghostty uses a best-height-then-best-width bin packing algorithm
(from Jukka Jylänki's "A Thousand Ways to Pack the Bin"). Glyphs are rasterized
on first use, not at startup. The atlas starts at 512x512 and doubles when full.
Two atlases: grayscale (text) and BGRA (color emoji, later).

1. Implement `src/font/Atlas.zig`:
   - Core struct:
     ```zig
     data: []u8,                                // CPU-side pixel buffer
     size: u32,                                 // width = height (always square)
     nodes: std.ArrayListUnmanaged(Node),       // free-space horizontal spans
     format: Format,                            // .grayscale | .bgra
     modified: std.atomic.Value(usize),         // bumped on every pixel write
     ```
   - `Node = struct { x: u32, y: u32, width: u32 }` -- tracks available spans
   - `init()`: allocate 512x512 `u8` buffer, seed nodes with single span `(1, 1, size-2)` (1px border)
   - `reserve(width, height) -> Region`: best-height-then-best-width bin pack
     - Walk nodes for best fit, insert new node, shrink/remove overlaps, merge adjacent
     - Returns `Region { x, y, width, height }` for UV calculation
   - `set(region, bitmap_data)`: copy pixels into `data`, bump `modified` atomically
   - `grow(new_size)`: realloc to larger square, re-pack is NOT needed (just expand), bump `modified` and `resized`
   - On `error.AtlasFull`: caller calls `grow(size * 2)` and retries
2. Glyph cache (in `OpenGL.zig` or a `GlyphCache` struct):
   - `HashMap(GlyphKey, Glyph)` where `Glyph = struct { region: Atlas.Region, offset_x, offset_y, advance }`
   - Lookup before rasterizing -- cache hit = return atlas coordinates immediately
   - Cache miss = FreeType rasterize → `atlas.reserve()` → `atlas.set()` → insert into map
3. GPU texture sync (in `OpenGL.zig`):
   - Store `atlas_texture: GLuint` and `atlas_modified: usize = 0`
   - Before drawing: compare `atlas.modified.load(.monotonic)` vs `atlas_modified`
     - If changed and atlas grew: `glDeleteTextures` + `glGenTextures` + `glTexImage2D` at new size
     - If changed same size: `glTexSubImage2D` to upload full atlas
     - Update `atlas_modified`
   - Bind atlas texture to shader sampler
4. Modify `Character` struct: replace `texture_id: GLuint` with `region: Atlas.Region`
5. `loadGlyph()`: rasterize with FreeType, pack into atlas instead of creating per-glyph texture
6. Font fallback: skip rendering missing glyphs (empty cell). No DirectWrite on render path.
7. Delete all per-glyph `glGenTextures`/`glDeleteTexture` calls

**Verification**: Build and run. ASCII text looks correct. Colors work. No visual regressions. Confirm single atlas texture with `glGetIntegerv(GL_TEXTURE_BINDING_2D)`.

**Manual test cases** (tell the user these after the phase builds):
1. **Visual correctness**: Open phantty, run a command with colored output (PowerShell: `Get-ChildItem`; WSL: `ls --color`). Verify text renders identically to before — same glyph shapes, same colors, same spacing. No garbled characters, no missing glyphs, no offset issues. This confirms the atlas UV mapping is correct.
2. **Box drawing / special characters**: Run a TUI app that uses box drawing characters (e.g. `htop`, `btop`, or a `tree` command in WSL). Verify box-drawing lines connect properly and powerline/braille symbols render. This confirms sprite glyphs pack into the atlas correctly.
3. **Font hot-reload**: Press Ctrl+, and change `font-family` or `font-size` in the config, save. Verify the terminal re-renders with the new font. This confirms the atlas is cleared and rebuilt correctly on config reload.

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

**Manual test cases** (tell the user these after the phase builds):
1. **FPS improvement**: Enable the FPS overlay (`phantty-debug-fps = true` in config). Open a terminal with a full screen of text (run `dir /s` or `find /`). Compare the FPS counter to the value before this phase — it should be noticeably higher since we went from O(rows×cols) draw calls to 2.
2. **Cursor and selection**: Click and drag to select text, verify the selection highlight renders. Verify cursor blink works in all styles (block, bar, underline — change via `cursor-style` in config). This confirms cursor/selection are integrated into the batched cell buffers.
3. **Colored output + backgrounds**: Run something with ANSI background colors (e.g. `git diff` with colored output, or a colorful prompt). Verify both foreground text colors and background cell colors render correctly. This confirms the BG and FG cell buffers are both working.

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

**Manual test cases** (tell the user these after the phase builds):
1. **Idle CPU usage**: Open phantty, don't type anything, just leave it sitting at a prompt. Check CPU usage in Task Manager — it should be near zero (no per-frame cell rebuilds when nothing changed). Compare to the previous phase where it rebuilt every frame.
2. **Typing latency**: Type a long command character by character. Only the row with the cursor should be rebuilt each keypress. Verify the FPS overlay stays high and typing feels snappy — no full-grid rebuilds on each keystroke.
3. **Scroll vs full rebuild**: Run a command that produces many lines of output (`dir /s` or `find /`). Verify scrollback scrolling (Shift+PageUp/Down) is smooth. Then resize the window — this should trigger a full rebuild. Verify resize still works correctly and the terminal reflows properly.

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
