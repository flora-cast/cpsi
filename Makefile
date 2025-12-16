ZIG = zig
PREFIX ?= /

.PHONY: all install fmt

setup: 
	cd ./vendor/libtar/ && ./configure 


all:
	zig build -Doptimize=ReleaseFast

clean:
	rm -rf ./external/minisign/zig-out 
	rm -rf ./external/minisign/.zig-cache
	rm -rf ./src/external-bin
	rm -rf ./zig-out
	rm -rf ./.zig-cache

install:
	install -Dm755 ./zig-out/bin/cpsi "$(PREFIX)/usr/sbin/cpsi"

fmt:
	find src -type f -name '*.zig' -exec zig fmt {} +
