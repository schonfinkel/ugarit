ZIG ?= zig
NIX ?= nix
INSTALL ?= install
OPTIMIZE ?= Debug
PREFIX ?= /usr/local
DESTDIR ?=
NIX_FLAKE ?= path:.
ARGS ?=

.DEFAULT_GOAL := build

.PHONY: build release run test check fmt fmt-check install static nix-check clean

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

release:
	$(ZIG) build -Doptimize=ReleaseSafe

run:
	$(ZIG) build run -Doptimize=$(OPTIMIZE) -- $(ARGS)

test:
	$(ZIG) build test -Doptimize=$(OPTIMIZE) --summary all

check: fmt-check test

fmt:
	$(ZIG) fmt src build.zig

fmt-check:
	$(ZIG) fmt --check src build.zig

install: build
	$(INSTALL) -Dm755 zig-out/bin/ugarit "$(DESTDIR)$(PREFIX)/bin/ugarit"

static:
	$(NIX) build $(NIX_FLAKE)#static

nix-check:
	$(NIX) flake check $(NIX_FLAKE)

clean:
	rm -rf .zig-cache zig-out
