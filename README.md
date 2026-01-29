# Phantty

A Windows terminal emulator written in Zig, powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

## Features

- **Ghostty's terminal emulation** - Uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** - Find system fonts by name
- **FreeType rendering** - High-quality glyph rasterization
- **Per-glyph font fallback** - Automatic fallback for missing characters
- **Sprite rendering** - Box drawing, block elements, braille patterns, powerline symbols
- **Ghostty-style font metrics** - Proper ascent/descent/line_gap from hhea/OS2 tables
- **Theme support** - Ghostty-compatible theme files (default: Poimandres)

## Building

```bash
# Debug build (console subsystem, debug output visible)
make debug

# Release build (GUI subsystem, no background console window)
make release

# Clean build artifacts
make clean
```

Or directly with zig:
```bash
zig build                          # debug
zig build -Doptimize=ReleaseFast   # release
```

## Usage

```bash
phantty.exe [options]

Options:
  --font, -f <name>            Set font (default: JetBrains Mono)
  --font-style <style>         Font weight (default: semi-bold)
                                Options: thin, extra-light, light, regular,
                                         medium, semi-bold, bold, extra-bold, black
  --cursor-style <style>       Cursor shape (default: block)
                                Options: block, bar, underline, block_hollow
  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
  --theme <path>               Load a Ghostty theme file
  --window-height <rows>       Initial window height in cells (default: 28, min: 4)
  --window-width <cols>        Initial window width in cells (default: 110, min: 10)
  --list-fonts                 List available system fonts
  --test-font-discovery        Test DirectWrite font discovery
  --help                       Show help
```

## License

MIT
