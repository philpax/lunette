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

.PHONY: all build install install-binary install-lua install-config check check-format check-rust check-clippy check-test check-definitions check-luau clean

# The generator owns this list. It includes Lua sources, Luau declarations,
# generated LÖVR definitions, and installed alias metadata. Specs and probes
# are excluded.
install_manifest := $(CARGO) run -p lunette-generate-definitions -- --manifest

all: build

build:
	$(CARGO) build --profile $(PROFILE) --workspace

# `check` runs the standing checks CONTRIBUTING.md lists, in the order
# .github/workflows/ci.yml runs them. Each check is its own target; a failure
# can be repeated on its own.
check: check-format check-rust check-definitions check-luau

check-format:
	$(CARGO) +nightly fmt --all -- --check
	stylua --check lua etc/xdg/lunette examples $(wildcard crates/lunette/tests/plugin_*/)

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

# The check includes every shipped root, the ordinary spec harness modules,
# the default configuration, and the examples.
# Negative specs and probe runners stay out; their dedicated tests assert those
# diagnostics and the runner's computed requires are not statically followable.
check-luau:
	$(CARGO) run -p lunette --bin lunette -- check --definitions etc/lunette/definitions.luau $$(find lua/lunette lua/lunette-plugin lua/lunette-contracts lua/lunette-plugins lua/lunette-desktop -type f -name '*.luau' -print | sort) lua/spec/suite.luau lua/spec/expect.luau etc/xdg/lunette/main.luau $$(find examples -type f -name '*.luau' -print | sort)

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

# The manifest owns installed modules, declarations, and Lua-root alias metadata.
# Required entries fail when absent; optional roots may be omitted. Directory
# entries contribute only Luau files. Explicit files include .luaurc.
install-lua:
	@set -e; \
	manifest="$$( $(install_manifest) )" || exit $$?; \
	printf '%s\n' "$$manifest" | while read -r source destination required; do \
		if test -d "$$source"; then \
			files="$$($(FIND) "$$source" -type f -name '*.luau' -print)" || exit $$?; \
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
		elif test "$$required" = "false"; then \
			echo "make: skipping missing optional artifact: $$source" >&2; \
		else \
			echo "make: install artifact is missing: $$source" >&2; exit 1; \
		fi; \
	done

# cli::CONFIG_ARTIFACTS is the source of truth. The source .luaurc is
# intentionally excluded: dump-config generates one with absolute installed roots.
# The list may sit on one line or several, as rustfmt lays it out; every quoted
# string from the declaration to its closing bracket is an artifact.
config_artifacts := $(shell awk '/^const CONFIG_ARTIFACTS:/{found=1} found {done = index($$0, "];") > 0; while (match($$0, /"[^"]*"/)) {printf "%s ", substr($$0, RSTART + 1, RLENGTH - 2); $$0 = substr($$0, RSTART + RLENGTH)} if (done) exit}' crates/lunette/src/cli.rs)

install-config:
	@set -e; \
	for artifact in $(config_artifacts); do \
		test -f "etc/xdg/lunette/$$artifact" && test ! -L "etc/xdg/lunette/$$artifact" || { echo "make: install config artifact is missing or unsupported: $$artifact" >&2; exit 1; }; \
	done; \
	unsupported="$$($(FIND) etc/xdg/lunette ! -type d ! -type f -print)" || exit $$?; \
	if test -n "$$unsupported"; then \
		printf '%s\n' "$$unsupported" | while IFS= read -r entry; do \
			echo "make: install config contains unsupported content: $$entry" >&2; exit 1; \
		done || exit $$?; \
	fi; \
	directories="$$($(FIND) etc/xdg/lunette -mindepth 1 -type d -print)" || exit $$?; \
	if test -n "$$directories"; then \
		printf '%s\n' "$$directories" | while IFS= read -r directory; do \
			echo "make: install config contains an undeclared directory: $${directory#etc/xdg/lunette/}" >&2; exit 1; \
		done || exit $$?; \
	fi; \
	config_files="$$($(FIND) etc/xdg/lunette -type f -print)" || exit $$?; \
	if test -n "$$config_files"; then \
		printf '%s\n' "$$config_files" | while IFS= read -r file; do \
			relative="$${file#etc/xdg/lunette/}"; \
			case " $(config_artifacts) .luaurc " in *" $$relative "*) ;; *) echo "make: install config contains an undeclared file: $$relative" >&2; exit 1 ;; esac; \
		done || exit $$?; \
	fi; \
	$(INSTALL) -d $(confdir); \
	for artifact in $(config_artifacts); do \
		$(INSTALL) -d "$(confdir)/$$(dirname "$$artifact")"; \
		$(INSTALL_DATA) "etc/xdg/lunette/$$artifact" "$(confdir)/$$artifact"; \
	done

clean:
	$(CARGO) clean
