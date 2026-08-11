#!/usr/bin/env bash
# The sixth check: typecheck the mullion standard library and the shipped
# configuration with the Luau type checker (luau-analyze) built from the
# vendored LÖVR Luau fork.
#
# LÖVR's CMake excludes Luau.Analysis and CLI.lib from the default build, so the
# checker is built here as a standalone target from the same tree. The build is
# cached under the Cargo target directory so a normal `make check` does not
# reconfigure every time.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
luau_tree="$repo_root/vendor/lovr/deps/luau"
build_dir="${CARGO_TARGET_DIR:-$repo_root/target}/luau-checker"
definitions="$repo_root/etc/lunette/definitions.luau"

if [[ ! -x "$build_dir/luau-analyze" ]]; then
    cmake -S "$luau_tree" -B "$build_dir" \
        -DLUAU_BUILD_CLI=ON \
        -DBUILD_TESTING=OFF \
        -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$build_dir" --target Luau.Analyze.CLI -j"$(nproc)" >/dev/null
fi

# mullion and the config resolve `require 'mullion.*'` and `require 'lunette'`.
# luau-analyze resolves requires through its VFS relative to each file, so run
# from lua/ (where mullion/ lives) and pass the config explicitly. The spec
# suite is deliberately excluded: it runs under Luau as the in-binary test job,
# and its harness globals are not a typecheck target.
#
# The default report format is what makes this check able to fail. luau-analyze
# ends with `if (format == ReportFormat::Luacheck) return 0;`, because luacheck's
# contract is that its output is parsed rather than its status read, so
# `--formatter=plain` reports every diagnostic and still exits 0. The default
# format writes `file(line,col): TypeError: ...` to stderr and returns
# `failed ? 1 : 0`, which is what `set -e` above needs to see.
cd "$repo_root/lua"
"$build_dir/luau-analyze" \
    --mode=strict \
    --definitions="$definitions" \
    $(find mullion -name '*.lua' -o -name '*.luau' | sort) \
    "$repo_root/etc/xdg/lunette/main.lua"
