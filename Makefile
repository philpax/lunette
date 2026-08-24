# Build and install lunette's binaries, LÖVR libraries, Lua standard library,
# and default configuration; Cargo does not install these runtime files.
# PREFIX and SYSCONFDIR are compiled into the binary as defaults, so the build
# and install must use the same values. DESTDIR prefixes staged outputs only and
# is never compiled into the program.

PREFIX ?= /usr/local
SYSCONFDIR ?= /etc
DESTDIR ?=

CARGO ?= cargo
PROFILE ?= release
CARGO_TARGET_DIR ?= target

INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 755
INSTALL_DATA ?= $(INSTALL) -m 644

# Cargo names the `dev` profile's directory `debug`; every other profile's
# directory is its own name.
profile_dir := $(if $(filter dev,$(PROFILE)),debug,$(PROFILE))
build_dir := $(CARGO_TARGET_DIR)/$(profile_dir)

bindir := $(DESTDIR)$(PREFIX)/bin
libdir := $(DESTDIR)$(PREFIX)/lib/lunette
luadir := $(DESTDIR)$(PREFIX)/share/lunette/lua
confdir := $(DESTDIR)$(SYSCONFDIR)/xdg/lunette

export LUNETTE_PREFIX = $(PREFIX)
export LUNETTE_SYSCONFDIR = $(SYSCONFDIR)

.PHONY: all build install install-binary install-lua install-config check check-format check-rust check-clippy check-test check-definitions check-luau clean

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

# Expose each standing check as a repeatable target.
check: check-format check-rust check-definitions check-luau

check-format:
	$(CARGO) +nightly fmt --all -- --check
	stylua --check lua etc/xdg/lunette

# Clippy and tests use separate artifact caches, so CI runs them in parallel;
# this target runs both for local development.
check-rust: check-clippy check-test

check-clippy:
	$(CARGO) clippy --workspace --all-targets --all-features -- -D warnings
	$(CARGO) clippy --workspace --all-targets --no-default-features -- -D warnings

check-test:
	$(CARGO) test --workspace
	$(CARGO) test --workspace --no-default-features

# Generated definitions and module declarations are checked in and must be
# current. The checker includes only the ordinary spec modules, not the specs
# or their dynamic-require runner.
check-definitions:
	$(CARGO) run -p lunette-generate-definitions -- --check

# `lua/spec/suite.lua` and `lua/spec/expect.lua` are in: they are ordinary
# modules. The specs themselves and `lua/spec/runner.lua` are not; see
# CONTRIBUTING.md.
check-luau:
	$(CARGO) run -p lunette --bin lunette -- check --definitions etc/lunette/definitions.luau $$(find lua/mullion -type f \( -name '*.lua' -o -name '*.luau' \) -print | sort) lua/spec/suite.lua lua/spec/expect.lua etc/xdg/lunette/main.lua

install: install-binary install-lua install-config

# Locate the newest staged liblovr.so because Cargo puts each build-script
# output under a metadata directory. Install its libraries flat: the binary
# and liblovr.so use relative rpaths that resolve this layout.
lovr_build := $(shell find $(build_dir)/build -maxdepth 4 -name liblovr.so -printf '%T@ %h\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)

install-binary: build
	@test -n "$(lovr_build)" || \
		{ echo "make: liblovr.so was not found under $(build_dir)/build; run make build first" >&2; exit 1; }
	$(INSTALL) -d $(bindir) $(libdir)
	$(INSTALL_PROGRAM) $(build_dir)/lunette $(bindir)/lunette
	$(INSTALL_PROGRAM) $(build_dir)/lunctl $(bindir)/lunctl
	$(INSTALL_PROGRAM) $(lovr_build)/liblovr.so $(libdir)/liblovr.so
	$(INSTALL_PROGRAM) $(lovr_build)/bin/* $(libdir)/

# Do not install specs. Walk the tree rather than listing modules so new
# subdirectories are included; otherwise an omitted module works in-place
# but fails in an installed session.
install-lua:
	@set -e; \
	cd lua && find mullion -type f -name '*.lua' | while read -r file; do \
		$(INSTALL) -d "$(luadir)/$$(dirname "$$file")"; \
		$(INSTALL_DATA) "$$file" "$(luadir)/$$file"; \
	done

install-config:
	$(INSTALL) -d $(confdir)
	$(INSTALL_DATA) etc/xdg/lunette/main.lua etc/xdg/lunette/conf.lua $(confdir)/

clean:
	$(CARGO) clean
