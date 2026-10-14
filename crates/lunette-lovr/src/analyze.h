// The C surface over Luau's frontend.

#ifndef LUNETTE_ANALYZE_H
#define LUNETTE_ANALYZE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUNETTE_LUAU_TYPE_ERROR 0
#define LUNETTE_LUAU_SYNTAX_ERROR 1
#define LUNETTE_LUAU_LINT_ERROR 2
#define LUNETTE_LUAU_LINT_WARNING 3

typedef struct
{
    // The definitions file to load into the global scope, or null for none.
    const char* definitions;
    // The files to check, as paths, which are also their module names.
    const char* const* roots;
    size_t root_count;
} lunette_luau_request;

typedef struct
{
    int kind;
    char* module;
    // One-based lines, zero-based columns, matching Luau's numbering.
    int line;
    int column;
    int end_line;
    int end_column;
    char* message;
} lunette_luau_diagnostic;

typedef struct
{
    lunette_luau_diagnostic* diagnostics;
    size_t diagnostic_count;
    // The roots that produced a source module or parsed successfully, which
    // distinguishes checked roots from skipped roots.
    char** checked;
    size_t checked_count;
    // Why no check ran, or null. Diagnostics may still be present.
    char* failure;
} lunette_luau_report;

lunette_luau_report* lunette_luau_check(const lunette_luau_request* request)
#ifdef __cplusplus
    noexcept
#endif
    ;
// Parses roots without definitions or inference and requires parameter and value-return annotations.
lunette_luau_report* lunette_luau_check_annotations(const lunette_luau_request* request)
#ifdef __cplusplus
    noexcept
#endif
    ;
void lunette_luau_report_free(lunette_luau_report* report);

// Named paths reachable from global declarations, excluding function arguments and return types.
typedef struct
{
    char** path;
    size_t path_count;
    bool optional;
    // A string indexer declares all string keys at this path.
    bool string_indexed;
} lunette_luau_surface_member;

typedef struct
{
    lunette_luau_surface_member* members;
    size_t member_count;
    char* failure;
} lunette_luau_surface;

lunette_luau_surface* lunette_luau_definition_surface(const char* source, size_t length)
#ifdef __cplusplus
    noexcept
#endif
    ;
void lunette_luau_surface_free(lunette_luau_surface* surface);

// Require observations are parser-backed; locations match the diagnostics above.
#define LUNETTE_REQUIRE_RESOLVED 0
#define LUNETTE_REQUIRE_PRELOADED 1
#define LUNETTE_REQUIRE_DYNAMIC 2
#define LUNETTE_REQUIRE_ESCAPED 3
#define LUNETTE_REQUIRE_OVERWRITTEN 4
#define LUNETTE_REQUIRE_UNSUPPORTED 5
#define LUNETTE_REQUIRE_UNRESOLVED 6

typedef struct
{
    const char* name;
    const char* path;
} lunette_require_alias;

typedef struct
{
    const char* literal;
    const char* anchor;
} lunette_configured_require;

typedef struct
{
    const char* source;
    const char* const* allowed_roots;
    size_t allowed_root_count;
    const lunette_require_alias* aliases;
    size_t alias_count;
    const char* const* preloaded;
    size_t preloaded_count;
    const lunette_configured_require* configured;
    size_t configured_count;
} lunette_require_request;

typedef struct
{
    int line;
    int column;
    // Null means no literal; the length preserves embedded NUL bytes in literals.
    char* requested;
    size_t requested_length;
    int outcome;
    char* detail;
} lunette_require_observation;

typedef struct
{
    lunette_require_observation* observations;
    size_t observation_count;
    lunette_luau_diagnostic* diagnostics;
    size_t diagnostic_count;
    char* failure;
} lunette_require_report;

lunette_require_report* lunette_luau_inspect_requires(const lunette_require_request* request)
#ifdef __cplusplus
    noexcept
#endif
    ;
// Observes dot, colon, and constant-index calls with the named member, independently of receiver binding.
lunette_require_report* lunette_luau_inspect_member_calls(const char* source, const char* member_name)
#ifdef __cplusplus
    noexcept
#endif
    ;
void lunette_require_report_free(lunette_require_report* report);

#ifdef __cplusplus
}
#endif

#endif
