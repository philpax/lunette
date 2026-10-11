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

#ifdef __cplusplus
}
#endif

#endif
