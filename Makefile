# Building and installing lunette.
#
# Cargo builds the binary. The install step puts the runtime files where a
# session that did not build in place can find them. docs/dev/build-and-development.md
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
PATCHELF ?= patchelf
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

.PHONY: all build run install install-binary install-lua install-config check check-install check-format check-headset check-rust check-clippy check-test check-definitions check-luau clean

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

run:
	LUNETTE_STDLIB_PATH="$(CURDIR)/lua" LUNETTE_CONFIG_PATH="$(CURDIR)/etc/xdg/lunette" $(CARGO) run -p lunette --bin lunette -- $(ARGS)

# `check` runs the standing checks CONTRIBUTING.md lists, in the order
# .github/workflows/ci.yml runs them. Each check is its own target; a failure
# can be repeated on its own.
check: check-format check-install check-headset check-rust check-definitions check-luau

check-install:
	python3 crates/lunette/tests/fixtures/install.py

check-headset:
	cmake -S vendor/lovr -B $(CARGO_TARGET_DIR)/headset-tests -DLOVR_BUILD_HEADSET_TESTS=ON -DLOVR_ENABLE_OPENVR=ON -DLOVR_BUILD_EXE=OFF -DLOVR_BUILD_SHARED=OFF -DLOVR_ENABLE_AUDIO=OFF -DLOVR_ENABLE_DATA=OFF -DLOVR_ENABLE_PHYSICS=OFF -DLOVR_USE_GLFW=OFF -DLOVR_USE_LUAJIT=OFF -DLOVR_USE_GLSLANG=OFF -DLOVR_USE_STEAM_AUDIO=OFF
	cmake --build $(CARGO_TARGET_DIR)/headset-tests --target headset_native_tests
	ctest --test-dir $(CARGO_TARGET_DIR)/headset-tests --output-on-failure -L headset

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
	cache_dir=$$lovr_build; \
	while ! test -f "$$cache_dir/CMakeCache.txt" && test "$$cache_dir" != /; do \
		cache_dir=$$(dirname "$$cache_dir"); \
	done; \
	cache="$$cache_dir/CMakeCache.txt"; \
	if grep -q '^LOVR_ENABLE_OPENVR:BOOL=ON$$' "$$cache"; then \
		openvr=enabled; \
	elif grep -q '^LOVR_ENABLE_OPENVR:BOOL=OFF$$' "$$cache"; then \
		openvr=disabled; \
	else \
		echo "make: cannot determine OpenVR build state from $$cache" >&2; exit 1; \
	fi; \
	assets='actions.json bindings_vive_controller.json bindings_knuckles.json bindings_oculus_touch.json'; \
	if test "$$openvr" = enabled || test -e "$$lovr_build/lovr-openvr"; then \
		for asset in $$assets; do \
			test -f "$$lovr_build/lovr-openvr/$$asset" || \
				{ echo "make: $$openvr OpenVR build has an incomplete action bundle: $$lovr_build/lovr-openvr/$$asset is missing" >&2; exit 1; }; \
		done; \
	fi; \
	$(INSTALL) -d -m 755 "$(bindir)" "$(libdir)"; \
	$(INSTALL_PROGRAM) "$(build_dir)/lunette" "$(bindir)/lunette"; \
	$(INSTALL_PROGRAM) "$(build_dir)/lunctl" "$(bindir)/lunctl"; \
	$(INSTALL_PROGRAM) "$$lovr_build/liblovr.so" "$(libdir)/liblovr.so"; \
	$(INSTALL_PROGRAM) "$$lovr_build"/bin/* "$(libdir)/"; \
	$(PATCHELF) --set-rpath '$$ORIGIN:$$ORIGIN/../lib/lunette' "$(bindir)/lunette" "$(bindir)/lunctl"; \
	if test -d "$$lovr_build/lovr-openvr"; then \
		$(INSTALL) -d -m 755 "$(libdir)/lovr-openvr"; \
		for asset in $$assets; do \
			$(INSTALL_DATA) "$$lovr_build/lovr-openvr/$$asset" "$(libdir)/lovr-openvr/$$asset"; \
		done; \
	fi

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
	$(INSTALL) -d "$(confdir)"
	$(INSTALL_DATA) etc/xdg/lunette/main.lua etc/xdg/lunette/conf.lua "$(confdir)/"

clean:
	$(CARGO) clean
