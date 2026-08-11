// The Luau type checker, as a C surface for `lunette check`.
//
// The frontend setup mirrors `CLI/src/Analyze.cpp`, so that the standing check
// and the user-facing command cannot drift apart.

#include "Luau/BuiltinDefinitions.h"
#include "Luau/ExperimentalFlags.h"
#include "Luau/Frontend.h"

#include <cstring>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "analyze.h"

namespace
{

// Reads a module's source from the path its name is.
struct PathResolver : Luau::FileResolver
{
    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override
    {
        std::ifstream stream(name, std::ios::binary);
        if (!stream)
            return std::nullopt;

        std::ostringstream contents;
        contents << stream.rdbuf();
        return Luau::SourceCode{contents.str(), Luau::SourceCode::Module};
    }
};

struct FixedConfigResolver : Luau::ConfigResolver
{
    Luau::Config config;

    explicit FixedConfigResolver(Luau::Mode mode)
    {
        config.mode = mode;
    }

    const Luau::Config& getConfig(const Luau::ModuleName&, const Luau::TypeCheckLimits&) const override
    {
        return config;
    }
};

// What luau-analyze's setLuauFlagsDefault does. Without it the checker accepts
// a different language: `declare class`, which current Luau replaced, parses.
void enableDefaultFlags()
{
    for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next)
        if (strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name))
            flag->value = true;
}

char* copy(const std::string& text)
{
    char* owned = new char[text.size() + 1];
    std::memcpy(owned, text.c_str(), text.size() + 1);
    return owned;
}

std::optional<std::string> readFile(const char* path)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        return std::nullopt;

    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

// Collects into the vectors the report is built from.
struct Collector
{
    std::vector<lunette_luau_diagnostic> diagnostics;
    std::vector<char*> checked;

    void add(int kind, const std::string& module, const Luau::Location& location, const std::string& message)
    {
        lunette_luau_diagnostic diagnostic;
        diagnostic.kind = kind;
        diagnostic.module = copy(module);
        diagnostic.line = static_cast<int>(location.begin.line) + 1;
        diagnostic.column = static_cast<int>(location.begin.column) + 1;
        diagnostic.message = copy(message);
        diagnostics.push_back(diagnostic);
    }
};

lunette_luau_report* fail(const std::string& message, Collector& collected)
{
    lunette_luau_report* report = new lunette_luau_report{};
    report->failure = copy(message);
    report->diagnostic_count = collected.diagnostics.size();
    if (report->diagnostic_count > 0)
    {
        report->diagnostics = new lunette_luau_diagnostic[report->diagnostic_count];
        std::copy(collected.diagnostics.begin(), collected.diagnostics.end(), report->diagnostics);
    }
    return report;
}

} // namespace

extern "C"
{

lunette_luau_report* lunette_luau_check(const lunette_luau_request* request)
{
    Collector collected;

    if (request == nullptr)
        return fail("no request was given", collected);

    enableDefaultFlags();

    Luau::FrontendOptions options;
    options.runLintChecks = true;

    PathResolver files;
    FixedConfigResolver config(request->strict ? Luau::Mode::Strict : Luau::Mode::Nonstrict);
    Luau::SolverMode solver = request->old_solver ? Luau::SolverMode::Old : Luau::SolverMode::New;

    Luau::Frontend frontend(solver, &files, &config, options);
    Luau::registerBuiltinGlobals(frontend, frontend.globals);

    if (request->definitions != nullptr)
    {
        std::optional<std::string> source = readFile(request->definitions);
        if (!source)
            return fail(std::string("the definitions file could not be read: ") + request->definitions, collected);

        Luau::LoadDefinitionFileResult loaded =
            frontend.loadDefinitionFile(frontend.globals, frontend.globals.globalScope, *source, "@definitions", false);

        if (!loaded.success)
        {
            // Both failure modes reach here: a definitions file that does not
            // parse, and one that parses and does not typecheck.
            const std::string module = request->definitions;
            for (const Luau::ParseError& error : loaded.parseResult.errors)
                collected.add(LUNETTE_LUAU_SYNTAX_ERROR, module, error.getLocation(), error.getMessage());
            if (loaded.module)
                for (const Luau::TypeError& error : loaded.module->errors)
                    collected.add(LUNETTE_LUAU_TYPE_ERROR, module, error.location, Luau::toString(error));

            return fail("the definitions file could not be loaded", collected);
        }
    }

    Luau::freeze(frontend.globals.globalTypes);

    for (size_t index = 0; index < request->root_count; ++index)
    {
        const std::string root = request->roots[index];

        // The frontend asserts rather than reports on a module it cannot read.
        if (!files.readSource(root))
        {
            collected.add(LUNETTE_LUAU_SYNTAX_ERROR, root, Luau::Location(), "the file could not be read");
            continue;
        }

        try
        {
            Luau::CheckResult result = frontend.check(root);

            for (const Luau::TypeError& error : result.errors)
            {
                const std::string module = error.moduleName.empty() ? root : error.moduleName;
                if (const Luau::SyntaxError* syntax = Luau::get_if<Luau::SyntaxError>(&error.data))
                    collected.add(LUNETTE_LUAU_SYNTAX_ERROR, module, error.location, syntax->message);
                else
                    collected.add(LUNETTE_LUAU_TYPE_ERROR, module, error.location, Luau::toString(error));
            }

            for (const Luau::LintWarning& warning : result.lintResult.errors)
                collected.add(LUNETTE_LUAU_LINT_ERROR, root, warning.location, warning.text);
            for (const Luau::LintWarning& warning : result.lintResult.warnings)
                collected.add(LUNETTE_LUAU_LINT_WARNING, root, warning.location, warning.text);
        }
        catch (const std::exception& raised)
        {
            collected.add(LUNETTE_LUAU_TYPE_ERROR, root, Luau::Location(), raised.what());
            continue;
        }

        // Lets a caller tell a file that passed from one that was skipped.
        if (frontend.getSourceModule(root) != nullptr)
            collected.checked.push_back(copy(root));
    }

    lunette_luau_report* report = new lunette_luau_report{};

    report->diagnostic_count = collected.diagnostics.size();
    if (report->diagnostic_count > 0)
    {
        report->diagnostics = new lunette_luau_diagnostic[report->diagnostic_count];
        std::copy(collected.diagnostics.begin(), collected.diagnostics.end(), report->diagnostics);
    }

    report->checked_count = collected.checked.size();
    if (report->checked_count > 0)
    {
        report->checked = new char*[report->checked_count];
        std::copy(collected.checked.begin(), collected.checked.end(), report->checked);
    }

    return report;
}

void lunette_luau_report_free(lunette_luau_report* report)
{
    if (report == nullptr)
        return;

    for (size_t index = 0; index < report->diagnostic_count; ++index)
    {
        delete[] report->diagnostics[index].module;
        delete[] report->diagnostics[index].message;
    }
    delete[] report->diagnostics;

    for (size_t index = 0; index < report->checked_count; ++index)
        delete[] report->checked[index];
    delete[] report->checked;

    delete[] report->failure;
    delete report;
}

} // extern "C"
