# Building and installing lunette.
#
# docs/development/build-and-development.md states the installed paths. Five sets ship:
#
#   $(PREFIX)/bin/lunette              the binary
#   $(PREFIX)/bin/lunctl               the control client
#   $(PREFIX)/lib/lunette/             LOVR and the shared libraries it needs
#   $(PREFIX)/share/lunette/            Lua modules and LÖVR definitions
#   $(SYSCONFDIR)/xdg/lunette/          the default configuration
#
# PREFIX and SYSCONFDIR are compiled into the binary through `option_env!`, so
# the build and the install share one prefix. DESTDIR prefixes every
# destination and is never compiled in.

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

# Cargo names the `dev` profile's directory `debug`.
profile_dir := $(if $(filter dev,$(PROFILE)),debug,$(PROFILE))
build_dir := $(CARGO_TARGET_DIR)/$(profile_dir)

bindir := $(DESTDIR)$(PREFIX)/bin
libdir := $(DESTDIR)$(PREFIX)/lib/lunette
datadir := $(DESTDIR)$(PREFIX)/share/lunette
luadir := $(datadir)/lua
confdir := $(DESTDIR)$(SYSCONFDIR)/xdg/lunette

export LUNETTE_PREFIX = $(PREFIX)
export LUNETTE_SYSCONFDIR = $(SYSCONFDIR)

.PHONY: all build run install install-binary install-lua install-config check check-install check-format check-headset check-headset-runtime check-graphics check-rust check-clippy check-test check-definitions check-luau check-luau-annotations clean

# The generator owns the install list. It omits the testing root.
install_manifest := $(CARGO) run -p lunette-generate-definitions -- --manifest

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

run:
	LUNETTE_STDLIB_PATH="$(CURDIR)/lua" LUNETTE_CONFIG_PATH="$(CURDIR)/dev" $(CARGO) run -p lunette --bin lunette -- $(ARGS)

# The standing checks, in the order .github/workflows/ci.yml runs them.
check: check-format check-install check-headset check-graphics check-rust check-definitions check-luau-annotations check-luau

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

# The caller selects Mesa lavapipe explicitly; the harness rejects an absent or hardware ICD.
check-graphics:
	$(CARGO) test -p lunette --features graphics-tests --test graphics

check-format:
	$(CARGO) +nightly fmt --all -- --check
	stylua --check lua etc/xdg/lunette examples dev crates/lunette/tests/luau_check crates/lunette/tests/graphics/fixtures

# Split in two because clippy builds through RUSTC_WORKSPACE_WRAPPER and shares
# no artifacts with the tests, so CI runs the halves in parallel.
check-rust: check-clippy check-test

check-clippy:
	$(CARGO) clippy --workspace --all-targets --all-features -- -D warnings
	$(CARGO) clippy --workspace --all-targets --no-default-features -- -D warnings

check-test:
	$(CARGO) test --workspace
	$(CARGO) test --workspace --no-default-features

# Fails when a checked-in generated artifact is stale.
check-definitions:
	$(CARGO) run -p lunette-generate-definitions -- --check

# This safe-mode fixture intentionally contains invalid syntax to exercise startup recovery.
# Find and sort run separately so either failure prevents Cargo from checking a partial list.
check-luau-annotations: SHELL := /usr/bin/env bash
check-luau-annotations:
	@set -eu; \
	listing=$$(mktemp); \
	trap 'rm -f "$$listing"' EXIT; \
	$(FIND) -P lua etc/xdg/lunette examples dev crates -type f -name '*.luau' ! -path 'crates/lunette/tests/fixtures/safe-mode/lunette/main.luau' -print0 > "$$listing"; \
	LC_ALL=C sort -z -o "$$listing" "$$listing"; \
	mapfile -d '' -t roots < "$$listing"; \
	if [ "$${#roots[@]}" -eq 0 ]; then printf '%s\n' 'make: no Luau files found for annotation checking' >&2; exit 1; fi; \
	$(CARGO) run -p lunette --example check_annotations -- "$${roots[@]}"

# Tests and lua/testing stay out, because they build partial handles and fake
# natives that strict checking would force them to cast.
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

# Required manifest entries fail when absent; optional roots may be omitted.
install-lua:
	@set -e; \
	manifest="$$( $(install_manifest) )" || exit $$?; \
	printf '%s\n' "$$manifest" | while read -r source destination; do \
		if test -d "$$source"; then \
			files="$$($(FIND) "$$source" -type d -name tests -prune -o -type f -print)" || exit $$?; \
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

# The files cli::DEFAULT_CONFIGURATION embeds. The source .luaurc is excluded,
# because dump-config generates one with absolute installed roots.
install-config:
	$(INSTALL) -d "$(confdir)"
	$(INSTALL_DATA) etc/xdg/lunette/main.luau etc/xdg/lunette/conf.luau "$(confdir)/"

clean:
	$(CARGO) clean
