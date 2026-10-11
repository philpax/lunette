// The Luau type checker, as a C surface for `lunette check`.
//
// The frontend setup mirrors `CLI/src/Analyze.cpp`.

#include "analyze_navigation.h"
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Config.h"
#include "Luau/ExperimentalFlags.h"
#include "Luau/Frontend.h"
#include "Luau/Parser.h"
#include "Luau/RequireNavigator.h"
#include "Luau/Type.h"
#include "Luau/TypePack.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <tuple>
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

std::optional<std::string> readAnnotationSource(const std::string& path)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        return std::nullopt;

    std::string contents;
    char buffer[8192];
    while (stream.read(buffer, sizeof(buffer)))
        contents.append(buffer, static_cast<size_t>(stream.gcount()));
    contents.append(buffer, static_cast<size_t>(stream.gcount()));
    if (stream.bad() || !stream.eof())
        return std::nullopt;
    return contents;
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

    DirectoryConfigResolver()
    {
        defaults.mode = Luau::Mode::Strict;
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
        // A `.luaurc` that omits the mode must not lower the caller's choice.
        config.mode = defaults.mode;

        if (std::optional<std::string> contents = slurp(directory + "/" + Luau::kConfigName))
        {
            // A relative alias resolves against its `.luaurc`'s directory,
            // not the working directory.
            Luau::ConfigOptions options;
            options.aliasOptions = Luau::ConfigOptions::AliasOptions{directory, true};
            Luau::parseConfig(*contents, config, options);
        }

        return cache.emplace(directory, std::move(config)).first->second;
    }
};

// Resolves a module with Luau's require traversal and a filesystem context that follows symlinks.
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

        CheckerNavigationContext navigation{context->name};
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

// Matches luau-analyze's setLuauFlagsDefault, without which the checker
// accepts a different language.
//
// The flags are process-global and checks may run concurrently, so they are
// set once. A static initializer cannot, because the flags register from other
// translation units' static initializers in an unspecified order.
void enableDefaultFlags()
{
    static std::once_flag once;
    std::call_once(once, [] {
        for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next)
            if (strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name))
                flag->value = true;
    });
}

char* copy(const std::string& text)
{
    char* owned = new char[text.size() + 1];
    std::memcpy(owned, text.c_str(), text.size() + 1);
    return owned;
}

struct Collector
{
    std::vector<lunette_luau_diagnostic> diagnostics;
    std::vector<char*> checked;

    Collector() = default;
    Collector(const Collector&) = delete;
    Collector& operator=(const Collector&) = delete;

    ~Collector()
    {
        for (const lunette_luau_diagnostic& diagnostic : diagnostics)
        {
            delete[] diagnostic.module;
            delete[] diagnostic.message;
        }
        for (char* root : checked)
            delete[] root;
    }

    void add(int kind, const std::string& module, const Luau::Location& location, const std::string& message)
    {
        std::unique_ptr<char[]> ownedModule(copy(module));
        std::unique_ptr<char[]> ownedMessage(copy(message));
        lunette_luau_diagnostic diagnostic;
        diagnostic.kind = kind;
        diagnostic.module = ownedModule.get();
        diagnostic.line = static_cast<int>(location.begin.line) + 1;
        diagnostic.column = static_cast<int>(location.begin.column);
        diagnostic.end_line = static_cast<int>(location.end.line) + 1;
        diagnostic.end_column = static_cast<int>(location.end.column);
        diagnostic.message = ownedMessage.get();
        diagnostics.push_back(diagnostic);
        ownedModule.release();
        ownedMessage.release();
    }

    void addChecked(const std::string& root)
    {
        std::unique_ptr<char[]> owned(copy(root));
        checked.push_back(owned.get());
        owned.release();
    }
};

struct ValueReturns : Luau::AstVisitor
{
    bool found = false;

    bool visit(Luau::AstStatReturn* statement) override
    {
        // A returned call is an expression even when inference would give it no values.
        found = found || statement->list.size > 0;
        return false;
    }

    bool visit(Luau::AstExprFunction*) override
    {
        return false;
    }
};

struct FunctionAnnotations : Luau::AstVisitor
{
    Collector& collected;
    const std::string& root;

    FunctionAnnotations(Collector& collected, const std::string& root)
        : collected(collected)
        , root(root)
    {
    }

    bool visit(Luau::AstExprFunction* function) override
    {
        // The implicit receiver is in `self`, not `args`, and has no source annotation.
        for (Luau::AstLocal* argument : function->args)
            if (argument->annotation == nullptr)
                collected.add(LUNETTE_LUAU_LINT_ERROR, root, argument->location,
                    std::string("parameter '") + argument->name.value + "' requires a type annotation");

        if (function->vararg && function->varargAnnotation == nullptr)
            collected.add(LUNETTE_LUAU_LINT_ERROR, root, function->varargLocation,
                "variadic parameter requires a type annotation");

        if (function->returnAnnotation == nullptr)
        {
            ValueReturns returns;
            function->body->visit(&returns);
            if (returns.found)
                collected.add(LUNETTE_LUAU_LINT_ERROR, root, Luau::Location(function->location.begin, 8),
                    "function with return expressions requires a return type annotation");
        }

        return true;
    }

    bool visit(Luau::AstType*) override
    {
        return true;
    }

    bool visit(Luau::AstTypePack*) override
    {
        return true;
    }
};

lunette_luau_report* finish(Collector& collected, const std::string* failure = nullptr)
{
    std::unique_ptr<lunette_luau_report> report(new lunette_luau_report{});
    std::unique_ptr<char[]> reason(failure == nullptr ? nullptr : copy(*failure));
    std::unique_ptr<lunette_luau_diagnostic[]> diagnostics;
    std::unique_ptr<char*[]> checked;

    report->diagnostic_count = collected.diagnostics.size();
    if (report->diagnostic_count > 0)
    {
        diagnostics.reset(new lunette_luau_diagnostic[report->diagnostic_count]);
        std::copy(collected.diagnostics.begin(), collected.diagnostics.end(), diagnostics.get());
    }

    report->checked_count = collected.checked.size();
    if (report->checked_count > 0)
    {
        checked.reset(new char*[report->checked_count]);
        std::copy(collected.checked.begin(), collected.checked.end(), checked.get());
    }

    report->failure = reason.release();
    report->diagnostics = diagnostics.release();
    report->checked = checked.release();
    collected.diagnostics.clear();
    collected.checked.clear();
    return report.release();
}

// Whether a type is `{ read witness: (T) -> T }` at T = unknown. An
// uninstantiated `plugin.capability` leaves T unknown, and every read through
// it then goes unchecked silently.
bool isUnnamedCapability(Luau::TypeId type)
{
    const Luau::TableType* table = Luau::get<Luau::TableType>(Luau::follow(type));
    if (table == nullptr || table->props.size() != 1 || table->indexer)
        return false;

    auto witness = table->props.find("witness");
    if (witness == table->props.end() || !witness->second.readTy)
        return false;

    const Luau::FunctionType* function = Luau::get<Luau::FunctionType>(Luau::follow(*witness->second.readTy));
    if (function == nullptr)
        return false;

    auto [arguments, tail] = Luau::flatten(function->argTypes);
    return arguments.size() == 1 && !tail && Luau::get<Luau::UnknownType>(Luau::follow(arguments[0])) != nullptr;
}

// Finds each call whose result is a capability with an unknown service type.
struct UnnamedCapabilities : Luau::AstVisitor
{
    const Luau::Module& module;
    std::vector<Luau::Location> found;

    explicit UnnamedCapabilities(const Luau::Module& module)
        : module(module)
    {
    }

    bool visit(Luau::AstExprCall* call) override
    {
        if (const Luau::TypePackId* results = module.astTypePacks.find(call))
        {
            std::optional<Luau::TypeId> first = Luau::first(*results);
            if (first && isUnnamedCapability(*first))
                found.push_back(call->location);
        }
        return true;
    }
};

const char* const kUnnamedCapability =
    "this capability's service type is unknown, so nothing read through it is checked; name it with "
    "plugin.capability<<Service>> { ... }";

lunette_luau_report* fail(const std::string& message, Collector& collected)
{
    return finish(collected, &message);
}

} // namespace

namespace
{
lunette_luau_report* check_within(const lunette_luau_request* request);
lunette_luau_report* check_annotations_within(const lunette_luau_request* request);
}

extern "C"
{

// Rust declares this `extern "C"`, so an exception crossing the boundary is
// undefined behaviour, and every exception becomes a failure report.
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

lunette_luau_report* lunette_luau_check_annotations(const lunette_luau_request* request) noexcept
{
    try
    {
        return check_annotations_within(request);
    }
    catch (const std::exception& raised)
    {
        try
        {
            Collector collected;
            return fail(std::string("the annotation checker raised: ") + raised.what(), collected);
        }
        catch (...)
        {
            // Reporting an allocation failure may itself fail to allocate.
            return nullptr;
        }
    }
    catch (...)
    {
        try
        {
            Collector collected;
            return fail("the annotation checker raised something that is not an exception", collected);
        }
        catch (...)
        {
            return nullptr;
        }
    }
}

} // extern "C"

namespace
{

lunette_luau_report* check_annotations_within(const lunette_luau_request* request)
{
    Collector collected;
    if (request == nullptr)
        return fail("no request was given", collected);
    if (request->root_count == 0)
        return fail("no roots were given", collected);
    if (request->roots == nullptr)
        return fail("the roots were not given", collected);

    enableDefaultFlags();

    std::vector<std::string> roots;
    for (size_t index = 0; index < request->root_count; ++index)
    {
        if (request->roots[index] == nullptr)
            return fail("a root was not given", collected);
        roots.emplace_back(request->roots[index]);
    }
    std::sort(roots.begin(), roots.end());
    roots.erase(std::unique(roots.begin(), roots.end()), roots.end());

    for (const std::string& root : roots)
    {
        std::optional<std::string> source = readAnnotationSource(root);
        if (!source)
        {
            collected.add(LUNETTE_LUAU_SYNTAX_ERROR, root, Luau::Location(), "the file could not be read");
            continue;
        }

        Luau::Allocator allocator;
        Luau::AstNameTable names(allocator);
        Luau::ParseResult parsed = Luau::Parser::parse(source->data(), source->size(), names, allocator);
        for (const Luau::ParseError& error : parsed.errors)
            collected.add(LUNETTE_LUAU_SYNTAX_ERROR, root, error.getLocation(), error.getMessage());
        if (!parsed.errors.empty())
            continue;
        if (parsed.root == nullptr)
        {
            collected.add(LUNETTE_LUAU_SYNTAX_ERROR, root, Luau::Location(), "the parser returned no syntax tree");
            continue;
        }

        FunctionAnnotations annotations(collected, root);
        parsed.root->visit(&annotations);
        collected.addChecked(root);
    }

    std::sort(collected.diagnostics.begin(), collected.diagnostics.end(),
        [](const lunette_luau_diagnostic& left, const lunette_luau_diagnostic& right) {
            int module = std::strcmp(left.module, right.module);
            if (module != 0)
                return module < 0;
            auto leftLocation = std::tie(left.line, left.column, left.end_line, left.end_column, left.kind);
            auto rightLocation = std::tie(right.line, right.column, right.end_line, right.end_column, right.kind);
            if (leftLocation != rightLocation)
                return leftLocation < rightLocation;
            return std::strcmp(left.message, right.message) < 0;
        });
    return finish(collected);
}

lunette_luau_report* check_within(const lunette_luau_request* request)
{
    Collector collected;

    if (request == nullptr)
        return fail("no request was given", collected);

    enableDefaultFlags();

    Luau::FrontendOptions options;
    options.runLintChecks = true;
    // The unnamed-capability check reads each expression's type after the
    // module is checked, and the frontend discards them otherwise.
    options.retainFullTypeGraphs = true;

    DirectoryConfigResolver config;
    PathResolver files;
    Luau::Frontend frontend(Luau::SolverMode::New, &files, &config, options);
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

        // The frontend asserts on a module it cannot read.
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

            Luau::ModulePtr module = frontend.moduleResolver.getModule(root);
            const Luau::SourceModule* source = frontend.getSourceModule(root);
            if (module && source && source->root)
            {
                UnnamedCapabilities unnamed(*module);
                source->root->visit(&unnamed);
                for (const Luau::Location& location : unnamed.found)
                    collected.add(LUNETTE_LUAU_TYPE_ERROR, root, location, kUnnamedCapability);
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
            collected.addChecked(root);
    }

    return finish(collected);
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
