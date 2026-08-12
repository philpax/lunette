# Building and installing lunette.
#
# Cargo builds the binary; this exists for the part Cargo does not do, which is
# putting the runtime files where a session that did not build in place can find
# them. docs/build-and-development.md states the paths, and this is what
# realises them.
#
# Three sets ship:
#
#   $(PREFIX)/bin/lunette              the binary
#   $(PREFIX)/bin/lunctl               the control client
#   $(PREFIX)/lib/lunette/             LOVR and the shared libraries it needs
#   $(PREFIX)/share/lunette/lua/       the mullion standard library
#   $(SYSCONFDIR)/xdg/lunette/         the default configuration
#
# PREFIX and SYSCONFDIR reach the binary as LUNETTE_PREFIX and
# LUNETTE_SYSCONFDIR, which crates/lunette/src/main.rs reads through
# `option_env!` and compiles in as the defaults it resolves against. That is why
# a build and the install that follows it have to be told the prefix once, here,
# rather than twice.
#
# DESTDIR is honoured for staged installs, per the GNU conventions: it prefixes
# every destination and is never compiled into anything.

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

.PHONY: all build install install-binary install-lua install-config check clean

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

check:
	$(CARGO) clippy --workspace --all-targets --all-features -- -D warnings
	$(CARGO) test --workspace
	stylua --check lua etc/xdg/lunette
	$(CARGO) run -p lunette --bin lunette -- check --definitions etc/lunette/definitions.luau $$(find lua/mullion -type f \( -name '*.lua' -o -name '*.luau' \) -print | sort) etc/xdg/lunette/main.lua

install: install-binary install-lua install-config

# The LOVR libraries are found rather than named, because cmake stages them under
# a directory whose name carries a Cargo metadata hash. `liblovr.so` is the one
# fixed point in that tree, so its directory is what the search returns.
#
# They are installed flat. `liblovr.so` is linked with an rpath of
# `$$ORIGIN/bin:$$ORIGIN`, and the binary with one that reaches this directory,
# so a flat directory resolves for both without a nested `bin` inside a `lib`.
#
# The newest is taken, not the first: a tree that has been built under two sets
# of build-script inputs holds one staged directory per fingerprint, and the one
# the build above produced is the one just written.
lovr_build := $(shell find $(build_dir)/build -maxdepth 4 -name liblovr.so -printf '%T@ %h\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)

install-binary: build
	@test -n "$(lovr_build)" || \
		{ echo "make: liblovr.so was not found under $(build_dir)/build; run make build first" >&2; exit 1; }
	$(INSTALL) -d $(bindir) $(libdir)
	$(INSTALL_PROGRAM) $(build_dir)/lunette $(bindir)/lunette
	$(INSTALL_PROGRAM) $(build_dir)/lunctl $(bindir)/lunctl
	$(INSTALL_PROGRAM) $(lovr_build)/liblovr.so $(libdir)/liblovr.so
	$(INSTALL_PROGRAM) $(lovr_build)/bin/* $(libdir)/

# `lua/spec/` is deliberately not installed: the tests cover the standard library
# and are not part of it.
#
# The tree is walked rather than listed, so a module added under a new
# subdirectory is installed without this rule being remembered. A file the rule
# missed resolves in the working tree — where LUNETTE_STDLIB_PATH points during
# development — and is absent from an installed session, which is the worst shape
# a defect can take.
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
