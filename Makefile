.PHONY: debug release clean

debug:
	zig build

release:
	zig build -Doptimize=ReleaseFast

clean:
	rm -rf zig-out .zig-cache
