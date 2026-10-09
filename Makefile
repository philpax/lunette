# Building and installing lunette.
#
# Cargo builds the binary. The install step puts the runtime files where a
# session that did not build in place can find them. docs/dev/build-and-development.md
# states the paths, and the install targets realise them.
#
# Five sets ship:
#
#   $(PREFIX)/bin/lunette              the binary
#   $(PREFIX)/bin/lunctl               the control client
#   $(PREFIX)/lib/lunette/             LOVR and the shared libraries it needs
#   $(PREFIX)/share/lunette/            Lua modules and LÖVR definitions
#   $(SYSCONFDIR)/xdg/lunette/          the default configuration
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
PATCHELF ?= patchelf
INSTALL_PROGRAM ?= $(INSTALL) -m 755
INSTALL_DATA ?= $(INSTALL) -m 644
FIND ?= find

# Cargo names the `dev` profile's directory `debug`; every other profile's
# directory is its own name.
profile_dir := $(if $(filter dev,$(PROFILE)),debug,$(PROFILE))
build_dir := $(CARGO_TARGET_DIR)/$(profile_dir)

bindir := $(DESTDIR)$(PREFIX)/bin
libdir := $(DESTDIR)$(PREFIX)/lib/lunette
datadir := $(DESTDIR)$(PREFIX)/share/lunette
luadir := $(datadir)/lua
confdir := $(DESTDIR)$(SYSCONFDIR)/xdg/lunette

export LUNETTE_PREFIX = $(PREFIX)
export LUNETTE_SYSCONFDIR = $(SYSCONFDIR)

.PHONY: all build run install install-binary install-lua install-config check check-install check-format check-headset check-headset-runtime check-rust check-clippy check-test check-definitions check-luau clean

# The generator owns this list. It includes Lua sources, Luau declarations,
# generated LÖVR definitions, and installed alias metadata. The testing root
# is not listed, and install-lua skips every tests directory.
install_manifest := $(CARGO) run -p lunette-generate-definitions -- --manifest

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

run:
	LUNETTE_STDLIB_PATH="$(CURDIR)/lua" LUNETTE_CONFIG_PATH="$(CURDIR)/dev" $(CARGO) run -p lunette --bin lunette -- $(ARGS)

# `check` runs the standing checks CONTRIBUTING.md lists, in the order
# .github/workflows/ci.yml runs them. Each check is its own target; a failure
# can be repeated on its own.
check: check-format check-install check-headset check-rust check-definitions check-luau

check-install:
	python3 crates/lunette/tests/fixtures/install.py

check-headset:
	cmake -S vendor/lovr -B $(CARGO_TARGET_DIR)/headset-tests -DLOVR_BUILD_HEADSET_TESTS=ON -DLOVR_ENABLE_OPENVR=ON -DLOVR_BUILD_EXE=OFF -DLOVR_BUILD_SHARED=OFF -DLOVR_ENABLE_AUDIO=OFF -DLOVR_ENABLE_DATA=OFF -DLOVR_ENABLE_PHYSICS=OFF -DLOVR_USE_GLFW=OFF -DLOVR_USE_LUAJIT=OFF -DLOVR_USE_GLSLANG=ON -DLOVR_USE_STEAM_AUDIO=OFF
	cmake --build $(CARGO_TARGET_DIR)/headset-tests --target headset_native_tests
	ctest --test-dir $(CARGO_TARGET_DIR)/headset-tests --output-on-failure -L headset

check-headset-runtime:
	@test -n "$(OPENVR_SCENE_PID)" || { printf '%s\n' 'make: OPENVR_SCENE_PID must name an already-running scene application' >&2; exit 1; }
	cmake -S vendor/lovr -B $(CARGO_TARGET_DIR)/openvr-coexistence -DLOVR_BUILD_SHARED=ON -DLOVR_BUILD_EXE=OFF -DLOVR_BUILD_WITH_SYMBOLS=ON -DLOVR_ENABLE_OPENVR=ON -DLOVR_BUILD_OPENVR_COEXISTENCE=ON -DLOVR_ENABLE_AUDIO=OFF -DLOVR_ENABLE_PHYSICS=OFF -DLOVR_USE_GLFW=OFF -DLOVR_USE_LUAJIT=OFF -DLOVR_USE_GLSLANG=ON -DLOVR_USE_STEAM_AUDIO=OFF
	cmake --build $(CARGO_TARGET_DIR)/openvr-coexistence --target lovr_openvr_coexistence
	timeout --signal=TERM --kill-after=5s 90s $(CARGO_TARGET_DIR)/openvr-coexistence/runtime-tests/lovr_openvr_coexistence --expected-scene-pid "$(OPENVR_SCENE_PID)"

check-format:
	$(CARGO) +nightly fmt --all -- --check
	stylua --check lua etc/xdg/lunette examples dev crates/lunette/tests/luau_check

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

# The check includes every shipped root, the default and development
# configurations, and the examples. The tests directories and lua/testing stay out: test files build
# partial handles and fake natives, which strict checking would make them cast
# at every turn, and CONTRIBUTING.md records the stance.
check-luau:
	$(CARGO) run -p lunette --bin lunette -- check --definitions etc/lunette/definitions.luau $$(find lua/lunette lua/lunette-plugin lua/lunette-contracts lua/lunette-plugins lua/lunette-desktop -type d -name tests -prune -o -type f -name '*.luau' -print | sort) etc/xdg/lunette/main.luau etc/xdg/lunette/conf.luau $$(find examples dev -type d -name tests -prune -o -type f -name '*.luau' -print | sort)

install: install-binary install-lua install-config

install-binary: build
	@set -eu; \
	rpath=$$($(PATCHELF) --print-rpath "$(build_dir)/lunette"); \
	lovr_build=; \
	old_ifs=$$IFS; IFS=:; \
	for directory in $$rpath; do \
		case "$$directory" in /*) \
			if test -f "$$directory/liblovr.so"; then lovr_build=$$directory; break; fi ;; \
		esac; \
	done; IFS=$$old_ifs; \
	test -n "$$lovr_build" || \
		{ echo "make: the linked liblovr.so was not found in $(build_dir)/lunette's rpath" >&2; exit 1; }; \
	$(INSTALL) -d -m 755 "$(bindir)" "$(libdir)"; \
	$(INSTALL_PROGRAM) "$(build_dir)/lunette" "$(bindir)/lunette"; \
	$(INSTALL_PROGRAM) "$(build_dir)/lunctl" "$(bindir)/lunctl"; \
	$(INSTALL_PROGRAM) "$$lovr_build/liblovr.so" "$(libdir)/liblovr.so"; \
	$(INSTALL_PROGRAM) "$$lovr_build"/bin/* "$(libdir)/"; \
	$(PATCHELF) --set-rpath '$$ORIGIN:$$ORIGIN/../lib/lunette' "$(bindir)/lunette" "$(bindir)/lunctl"; \
	if test -d "$$lovr_build/lovr-openvr"; then \
		$(INSTALL) -d -m 755 "$(libdir)/lovr-openvr"; \
		$(INSTALL_DATA) "$$lovr_build"/lovr-openvr/* "$(libdir)/lovr-openvr/"; \
	fi

# The manifest owns installed modules, declarations, and Lua-root alias metadata.
# Required entries fail when absent; optional roots may be omitted. Directory
# entries contribute only Luau files outside tests directories. Explicit files
# include .luaurc and bundled font and licence assets.
install-lua:
	@set -e; \
	manifest="$$( $(install_manifest) )" || exit $$?; \
	printf '%s\n' "$$manifest" | while read -r source destination; do \
		if test -d "$$source"; then \
			files="$$($(FIND) "$$source" -type d -name tests -prune -o -type f -name '*.luau' -print)" || exit $$?; \
			if test -n "$$files"; then \
				printf '%s\n' "$$files" | while IFS= read -r file; do \
					relative="$${file#$$source/}"; \
					$(INSTALL) -d "$(DESTDIR)$(PREFIX)/share/lunette/$$(dirname "$$destination/$$relative")" || exit $$?; \
					$(INSTALL_DATA) "$$file" "$(DESTDIR)$(PREFIX)/share/lunette/$$destination/$$relative" || exit $$?; \
				done || exit $$?; \
			fi; \
		elif test -f "$$source"; then \
			$(INSTALL) -d "$(DESTDIR)$(PREFIX)/share/lunette/$$(dirname "$$destination")" || exit $$?; \
			$(INSTALL_DATA) "$$source" "$(DESTDIR)$(PREFIX)/share/lunette/$$destination" || exit $$?; \
		else \
			echo "make: install artifact is missing: $$source" >&2; exit 1; \
		fi; \
	done

# The files cli::DEFAULT_CONFIGURATION embeds. The source .luaurc is excluded:
# dump-config generates one with absolute installed roots.
install-config:
	$(INSTALL) -d "$(confdir)"
	$(INSTALL_DATA) etc/xdg/lunette/main.luau etc/xdg/lunette/conf.luau "$(confdir)/"

clean:
	$(CARGO) clean
