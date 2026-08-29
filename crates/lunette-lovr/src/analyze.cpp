// The Luau type checker, as a C surface for `lunette check`.
//
// The frontend setup mirrors `CLI/src/Analyze.cpp`. The standing check and
// the user-facing command both use this checker, so the two cannot differ.

#include "Luau/AnalyzeRequirer.h"
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Config.h"
#include "Luau/ExperimentalFlags.h"
#include "Luau/Frontend.h"
#include "Luau/RequireNavigator.h"

#include <cstring>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "analyze.h"

namespace
{

std::optional<std::string> slurp(const std::string& path)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        return std::nullopt;

    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

std::string directoryOf(const std::string& path)
{
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

// Reads the `.luaurc` for a module's directory and every directory above it,
// for the language mode and lint settings. The navigator handles aliases.
struct DirectoryConfigResolver : Luau::ConfigResolver
{
    Luau::Config defaults;
    mutable std::unordered_map<std::string, Luau::Config> cache;

    explicit DirectoryConfigResolver(Luau::Mode mode)
    {
        defaults.mode = mode;
    }

    const Luau::Config& getConfig(const Luau::ModuleName& name, const Luau::TypeCheckLimits&) const override
    {
        return forDirectory(directoryOf(name));
    }

    const Luau::Config& forDirectory(const std::string& directory) const
    {
        auto found = cache.find(directory);
        if (found != cache.end())
            return found->second;

        const std::string parent = directoryOf(directory);
        Luau::Config config = (parent == directory || directory == "." || directory.empty())
            ? defaults
            : forDirectory(parent);
        // The mode is not inherited from a parent's `.luaurc`. The caller
        // chooses the mode, and a `.luaurc` that omits it must not lower it.
        config.mode = defaults.mode;

        if (std::optional<std::string> contents = slurp(directory + "/" + Luau::kConfigName))
        {
            // Aliases are parsed when the alias options are set. An alias
            // carries the directory of the `.luaurc` that declared it, so a
            // relative alias resolves against that directory. The working
            // directory is not used.
            Luau::ConfigOptions options;
            options.aliasOptions = Luau::ConfigOptions::AliasOptions{directory, true};
            Luau::parseConfig(*contents, config, options);
        }

        return cache.emplace(directory, std::move(config)).first->second;
    }
};

// Resolves a module by path. A require goes through Luau's own navigator, so
// a require means here what it means in an editor.
struct PathResolver : Luau::FileResolver
{
    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override
    {
        if (std::optional<std::string> contents = slurp(name))
            return Luau::SourceCode{*contents, Luau::SourceCode::Module};
        return std::nullopt;
    }

    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo* context, Luau::AstExpr* node, const Luau::TypeCheckLimits&)
        override
    {
        Luau::AstExprConstantString* literal = node->as<Luau::AstExprConstantString>();
        if (literal == nullptr || context == nullptr)
            return std::nullopt;

        // A `.luau` configuration is not executed. Executing one needs a
        // `lua_State` and a time limit passed through the navigator. Lunette
        // writes and documents `.luaurc`.
        FileNavigationContext navigation{context->name};
        Luau::Require::ErrorHandler silent;
        Luau::Require::Navigator navigator(navigation, silent);

        std::string required{literal->value.data, literal->value.size};
        if (navigator.navigate(std::move(required)) != Luau::Require::Navigator::Status::Success)
            return std::nullopt;
        if (!navigation.isModulePresent())
            return std::nullopt;

        if (std::optional<std::string> identifier = navigation.getIdentifier())
            return Luau::ModuleInfo{*identifier};
        return std::nullopt;
    }
};

// The flag set is the same as luau-analyze's setLuauFlagsDefault. Without it
// the checker accepts a different language: `declare class` still parses,
// although current Luau no longer accepts the syntax.
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

// Collects the inputs to the report.
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
        diagnostic.column = static_cast<int>(location.begin.column);
        diagnostic.end_line = static_cast<int>(location.end.line) + 1;
        diagnostic.end_column = static_cast<int>(location.end.column);
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

namespace
{
lunette_luau_report* check_within(const lunette_luau_request* request);
}

extern "C"
{

// The function is `noexcept`, and the body is wrapped. Rust declares this
// `extern "C"`, not `extern "C-unwind"`, so an exception crossing the boundary
// is undefined behaviour. The frontend's construction, the definitions load,
// and `freeze` can all raise, and the body catches exceptions and turns them
// into a failure report.
lunette_luau_report* lunette_luau_check(const lunette_luau_request* request) noexcept
{
    try
    {
        return check_within(request);
    }
    catch (const std::exception& raised)
    {
        Collector collected;
        return fail(std::string("the checker raised: ") + raised.what(), collected);
    }
    catch (...)
    {
        Collector collected;
        return fail("the checker raised something that is not an exception", collected);
    }
}

} // extern "C"

namespace
{

lunette_luau_report* check_within(const lunette_luau_request* request)
{
    Collector collected;

    if (request == nullptr)
        return fail("no request was given", collected);

    enableDefaultFlags();

    Luau::FrontendOptions options;
    options.runLintChecks = true;

    DirectoryConfigResolver config(request->strict ? Luau::Mode::Strict : Luau::Mode::Nonstrict);
    PathResolver files;
    Luau::SolverMode solver = request->old_solver ? Luau::SolverMode::Old : Luau::SolverMode::New;

    Luau::Frontend frontend(solver, &files, &config, options);
    Luau::registerBuiltinGlobals(frontend, frontend.globals);

    if (request->definitions != nullptr)
    {
        std::optional<std::string> source = slurp(request->definitions);
        if (!source)
            return fail(std::string("the definitions file could not be read: ") + request->definitions, collected);

        Luau::LoadDefinitionFileResult loaded =
            frontend.loadDefinitionFile(frontend.globals, frontend.globals.globalScope, *source, "@definitions", false);

        if (!loaded.success)
        {
            // The loader reports both failure modes: a definitions file that
            // does not parse, and one that parses and does not typecheck.
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

        // The frontend asserts on a module it cannot read, so each root is
        // read first. An unreadable root becomes a syntax error and is not
        // passed to the frontend.
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

        // Lets a caller distinguish a passed file from a skipped one.
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

} // namespace

extern "C"
{

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
