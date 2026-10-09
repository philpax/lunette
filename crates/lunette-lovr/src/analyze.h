// The C surface over Luau's frontend. The implementation is in analyze.cpp.

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
    // The roots that produced a source module. A missing root means the
    // checker never read that root; the diagnostic count does not show this.
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
void lunette_luau_report_free(lunette_luau_report* report);

#ifdef __cplusplus
}
#endif

#endif
