# Implement Terminal Splits (like Ghostty)

## Context

Phantty currently supports multiple tabs, each owning a single `Surface`. The user wants split panes like Ghostty, where a tab can be divided into multiple terminal surfaces arranged in a binary tree (horizontal/vertical splits). Ghostty's implementation was studied via `gh` CLI to ensure we follow their architecture closely (per AGENTS.md).

**Ghostty reference:** `src/datastruct/split_tree.zig` (immutable binary tree), `src/apprt/gtk/class/split_tree.zig` (GTK widget), `src/input/Binding.zig` (actions), `src/config/Config.zig` (config keys).

---

## Phase 1: Split Tree Data Structure

**Create:** `src/split_tree.zig`

Port Ghostty's `src/datastruct/split_tree.zig` — an immutable binary tree where mutations return new trees. Phantty monomorphizes with `*Surface` instead of Ghostty's generic `V`.

```
SplitTree
  arena: ArenaAllocator
  nodes: []const Node       // flat array, index 0 = root
  zoomed: ?Node.Handle

  Node = union(enum) { leaf: *Surface, split: Split }
  Node.Handle = enum(u16) { root = 0, _ }  // 16-bit index into nodes[]

  Split = struct { layout: Layout, ratio: f16, left: Handle, right: Handle }
  Split.Layout = enum { horizontal, vertical }
```

**Core operations** (all return new tree, old tree freed separately):
- `init(gpa, *Surface) !SplitTree` — single-leaf tree
- `split(gpa, at, direction, ratio, insert) !SplitTree` — split a leaf
- `remove(gpa, at) !SplitTree` — remove a leaf, collapse parent
- `resize(gpa, from, layout, ratio_delta) !SplitTree` — adjust nearest parent ratio
- `equalize(gpa) !SplitTree` — weight-based ratio balancing
- `goto(alloc, from, Goto) !?Handle` — navigation (prev/next/spatial)
- `spatial(alloc) !Spatial` — compute normalized 2D layout for navigation/rendering
- `zoom(handle)` / `zoom(null)` — in-place toggle (the one mutable op)
- `iterator() Iterator` — iterate over leaves

**Spatial navigation** (matching Ghostty): builds a normalized 2D grid where each leaf gets a slot `{x, y, width, height}`, then finds nearest leaf by Euclidean distance in the given direction.

**Modify:** `src/Surface.zig` — add reference counting for tree mutations:
```zig
ref_count: u32 = 1,
pub fn ref(self: *Surface) *Surface { self.ref_count += 1; return self; }
pub fn unref(self: *Surface, alloc: Allocator) void { self.ref_count -= 1; if (self.ref_count == 0) self.deinit(alloc); }
```

---

## Phase 2: Tab → SplitTree Integration

**Modify:** `src/AppWindow.zig`

Change `TabState` to own a split tree instead of a single surface:

```zig
const TabState = struct {
    tree: SplitTree,
    focused: SplitTree.Node.Handle = .root,

    fn focusedSurface(self: *const TabState) ?*Surface { ... }
    fn getTitle(self: *const TabState) []const u8 { ... }  // from focused surface
    fn deinit(self: *TabState, alloc: Allocator) void { self.tree.deinit(); }
};
```

Update `activeSurface()` → returns `tab.focusedSurface()`.
Update `spawnTabWithCwd()` → creates `SplitTree.init(alloc, surface)`.
Update `closeTab()` → `tab.tree.deinit()` unrefs all surfaces.

**Invariant:** With one leaf (no splits), behavior is identical to current code.

---

## Phase 3: Multi-Surface Rendering

**Modify:** `src/AppWindow.zig`

Each leaf gets a pixel rect computed from the tree's spatial layout:

```zig
const SplitRect = struct { x: i32, y: i32, width: i32, height: i32, cols: u16, rows: u16 };
```

**`computeSplitLayout(tab, content_x, content_y, content_w, content_h, divider_width)`:**
1. Call `tab.tree.spatial(alloc)` to get normalized slots
2. Map each leaf's `{x,y,w,h}` from [0,1] to pixel coordinates within content area
3. Inset by half-divider-width on edges adjacent to other splits
4. Compute `cols = width / cell_width`, `rows = height / cell_height`

**Render loop** (replaces current single-surface render):
1. Clear window, draw titlebar (full viewport)
2. `glEnable(GL_SCISSOR_TEST)`
3. For each leaf: lock → `updateTerminalCellsForSurface(surface, is_focused)` → unlock → `rebuildCells()` → set `glViewport`+`glScissor` to rect → `drawCells(rect.height, 0, 0)` → draw unfocused overlay if not focused
4. `glDisable(GL_SCISSOR_TEST)`
5. Draw split dividers in full viewport

Cell buffers (`bg_cells`, `fg_cells`, etc.) are reused — surfaces render sequentially, each overwriting the buffers.

**Refactor `updateTerminalCells`** → `updateTerminalCellsForSurface(surface, is_focused)` that takes a specific surface instead of reading from `activeSurface()`. Unfocused surfaces show `block_hollow` cursor.

**Divider rendering:** Walk tree nodes — for each `split` node, draw a 2px line at the ratio boundary using the spatial slots.

**Per-surface resize:** Each surface gets its own cols/rows from its `SplitRect`. On window resize, recompute layout for all tabs, resize each surface's terminal + PTY independently.

**Post-processing shader:** If enabled, apply per-surface (render each surface to FBO at its viewport, then composite). Alternatively, disable with splits initially and add back later.

---

## Phase 4: Input Routing & Keybindings

**Modify:** `src/AppWindow.zig`

**New keybindings** (Ghostty Linux defaults, Windows-friendly):

| Keys | Action |
|------|--------|
| `Ctrl+Shift+O` | `new_split:right` |
| `Ctrl+Shift+E` | `new_split:down` |
| `Ctrl+Alt+Arrows` | `goto_split:{up,down,left,right}` |
| `Ctrl+Shift+[` / `]` | `goto_split:previous` / `next` |
| `Ctrl+Shift+Alt+Arrows` | `resize_split:{up,down,left,right}` |
| `Ctrl+Shift+Enter` | `toggle_split_zoom` |
| `Ctrl+Shift+Z` | `equalize_splits` |
| `Ctrl+W` | Close focused split (or tab if single surface) |

**Split operation functions:**
- `splitFocused(direction)` — create new Surface, `tree.split()`, update `tab.focused` to new leaf
- `closeFocusedSplit()` — `tree.goto(.next_wrapped)` for new focus, then `tree.remove(focused)`
- `gotoSplit(Goto)` — `tree.goto(alloc, focused, direction)`, update `tab.focused`
- `resizeSplit(layout, delta)` — `tree.resize(alloc, focused, layout, delta)`
- `equalizeSplits()` — `tree.equalize(alloc)`
- `toggleSplitZoom()` — `tree.zoom(focused)` or `tree.zoom(null)`

**Mouse focus:** In `handleMouseButton`, hit-test click against `g_split_rects[]` to determine which split was clicked, update `tab.focused`.

**Mouse-to-cell conversion:** `mouseToCell()` finds the split rect the cursor is in, uses that rect's origin for coordinate calculation.

---

## Phase 5: Config & Polish

**Modify:** `src/config.zig`

| Config Key | Type | Default | Description |
|------------|------|---------|-------------|
| `unfocused-split-opacity` | f32 | 0.7 | Opacity of unfocused splits (0.15-1.0) |
| `split-divider-color` | Color | mid-gray | Color of the divider line |
| `focus-follows-mouse` | bool | false | Mouse hover changes split focus |

**Unfocused overlay rendering:** Draw a semi-transparent quad over unfocused split viewports. Alpha = `1.0 - unfocused_split_opacity`.

**Hot-reload:** Update split config values in `checkConfigReload()`.

---

## Files Summary

| File | Action | Phases |
|------|--------|--------|
| `src/split_tree.zig` | Create | 1 |
| `src/Surface.zig` | Modify (add ref_count, ref/unref) | 1 |
| `src/AppWindow.zig` | Modify (TabState, render loop, input, layout, dividers) | 2-5 |
| `src/config.zig` | Modify (add split config keys) | 5 |

---

## Verification

1. **Build:** `make release` after each phase
2. **Phase 1:** Unit test `split_tree.zig` with `zig test` (mock surfaces)
3. **Phase 2:** Existing tab functionality works identically (single-leaf trees)
4. **Phase 3:** `Ctrl+Shift+O` creates a vertical split, both surfaces render side-by-side with correct sizes, divider visible
5. **Phase 4:** `Ctrl+Alt+Left/Right` moves focus between splits (cursor changes from block to block_hollow), `Ctrl+W` closes focused split, mouse click changes focus
6. **Phase 5:** Config values apply (change `unfocused-split-opacity` in config, hot-reload works)
7. **Full test:** Multiple splits (3+), nested horizontal+vertical, resize with keyboard, equalize, zoom toggle, tab switching preserves split state
