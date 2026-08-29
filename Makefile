# Building and installing lunette.
#
# Cargo builds the binary. The install step puts the runtime files where a
# session that did not build in place can find them. docs/build-and-development.md
# states the paths, and the install targets realise them.
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
# `option_env!` and compiles in as the defaults it resolves against. The
# build and the install that follows it must be told the prefix once, here,
# not twice.
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

.PHONY: all build install install-binary install-lua install-config check check-format check-rust check-clippy check-test check-definitions check-luau clean

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

# `check` runs the standing checks CONTRIBUTING.md lists, in the order
# .github/workflows/ci.yml runs them. Each check is its own target; a failure
# can be repeated on its own.
check: check-format check-rust check-definitions check-luau

check-format:
	$(CARGO) +nightly fmt --all -- --check
	stylua --check lua etc/xdg/lunette

# The target splits in two because clippy and the tests share no artifacts.
# The clippy build runs through RUSTC_WORKSPACE_WRAPPER and produces its own
# artifact set. CI runs the halves as separate jobs at the same time.
# `check-rust` runs both.
check-rust: check-clippy check-test

check-clippy:
	$(CARGO) clippy --workspace --all-targets --all-features -- -D warnings
	$(CARGO) clippy --workspace --all-targets --no-default-features -- -D warnings

check-test:
	$(CARGO) test --workspace
	$(CARGO) test --workspace --no-default-features

# Both generated files are checked in: the LOVR definitions from lovr-docs,
# and the `lunette` module from the Rust registration surface. A stale
# artifact fails the `--check` run, and is not left to surface later.
check-definitions:
	$(CARGO) run -p lunette-generate-definitions -- --check

# The check includes `lua/spec/suite.lua` and `lua/spec/expect.lua`, which
# are ordinary modules. The spec files and `lua/spec/runner.lua` are not
# included; see CONTRIBUTING.md.
check-luau:
	$(CARGO) run -p lunette --bin lunette -- check --definitions etc/lunette/definitions.luau $$(find lua/mullion -type f \( -name '*.lua' -o -name '*.luau' \) -print | sort) lua/spec/suite.lua lua/spec/expect.lua etc/xdg/lunette/main.lua

install: install-binary install-lua install-config

# The LOVR libraries are found, not named, because cmake stages them under a
# directory whose name carries a Cargo metadata hash. `liblovr.so` is the one
# stable name in that tree; the search returns the directory that contains it.
#
# They are installed flat. `liblovr.so` has an rpath of `$$ORIGIN/bin:$$ORIGIN`,
# and the binary has one that reaches this directory. The flat layout then
# resolves for both and needs no nested `bin` inside a `lib` directory.
#
# The newest is taken, not the first. A tree built under two sets of
# build-script inputs holds one staged directory per fingerprint, and the
# newest directory holds the current build's output.
lovr_build := $(shell find $(build_dir)/build -maxdepth 4 -name liblovr.so -printf '%T@ %h\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)

install-binary: build
	@test -n "$(lovr_build)" || \
		{ echo "make: liblovr.so was not found under $(build_dir)/build; run make build first" >&2; exit 1; }
	$(INSTALL) -d $(bindir) $(libdir)
	$(INSTALL_PROGRAM) $(build_dir)/lunette $(bindir)/lunette
	$(INSTALL_PROGRAM) $(build_dir)/lunctl $(bindir)/lunctl
	$(INSTALL_PROGRAM) $(lovr_build)/liblovr.so $(libdir)/liblovr.so
	$(INSTALL_PROGRAM) $(lovr_build)/bin/* $(libdir)/

# `lua/spec/` is not installed: the tests cover the standard library and are
# not part of it.
#
# The tree is walked, not listed. A module added under a new subdirectory
# installs without an edit to this rule. A file the rule misses resolves in
# the working tree, where LUNETTE_STDLIB_PATH points during development, and
# is absent from an installed session. The defect appears only in an installed
# session and nowhere in the working tree.
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
