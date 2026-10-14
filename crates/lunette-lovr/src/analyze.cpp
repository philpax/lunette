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
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
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

std::unique_ptr<char[]> copy(const std::string& text)
{
    auto owned = std::make_unique<char[]>(text.size() + 1);
    std::memcpy(owned.get(), text.c_str(), text.size() + 1);
    return owned;
}

struct Diagnostic
{
    int kind;
    std::string module;
    Luau::Location location;
    std::string message;
};

struct Collector
{
    std::vector<Diagnostic> diagnostics;
    std::vector<std::string> checked;
    std::set<std::pair<std::string, std::string>> dependencies;

    void add(int kind, const std::string& module, const Luau::Location& location, const std::string& message)
    {
        diagnostics.push_back({kind, module, location, message});
    }

    void addChecked(const std::string& root)
    {
        checked.push_back(root);
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

lunette_luau_report* finish(const Collector& collected, const std::string* failure = nullptr)
{
    std::unique_ptr<lunette_luau_report, decltype(&lunette_luau_report_free)> report(
        std::make_unique<lunette_luau_report>().release(), &lunette_luau_report_free);

    // Zero-initialized arrays let the report deleter clean up partially copied strings.
    if (!collected.diagnostics.empty())
    {
        report->diagnostics = std::make_unique<lunette_luau_diagnostic[]>(collected.diagnostics.size()).release();
        report->diagnostic_count = collected.diagnostics.size();
        for (size_t index = 0; index < report->diagnostic_count; ++index)
        {
            const Diagnostic& source = collected.diagnostics[index];
            lunette_luau_diagnostic& diagnostic = report->diagnostics[index];
            diagnostic.kind = source.kind;
            diagnostic.line = static_cast<int>(source.location.begin.line) + 1;
            diagnostic.column = static_cast<int>(source.location.begin.column);
            diagnostic.end_line = static_cast<int>(source.location.end.line) + 1;
            diagnostic.end_column = static_cast<int>(source.location.end.column);
            diagnostic.module = copy(source.module).release();
            diagnostic.message = copy(source.message).release();
        }
    }

    if (!collected.checked.empty())
    {
        report->checked = std::make_unique<char*[]>(collected.checked.size()).release();
        report->checked_count = collected.checked.size();
        for (size_t index = 0; index < report->checked_count; ++index)
            report->checked[index] = copy(collected.checked[index]).release();
    }

    if (!collected.dependencies.empty())
    {
        report->dependencies = std::make_unique<lunette_luau_dependency[]>(collected.dependencies.size()).release();
        report->dependency_count = collected.dependencies.size();
        size_t index = 0;
        for (const auto& [source, target] : collected.dependencies)
        {
            auto& dependency = report->dependencies[index++];
            dependency.source = copy(source).release();
            dependency.target = copy(target).release();
        }
    }

    if (failure != nullptr)
        report->failure = copy(*failure).release();
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
        [](const Diagnostic& left, const Diagnostic& right) {
            int module = std::strcmp(left.module.c_str(), right.module.c_str());
            if (module != 0)
                return module < 0;
            auto leftLocation = std::make_tuple(static_cast<int>(left.location.begin.line) + 1,
                static_cast<int>(left.location.begin.column), static_cast<int>(left.location.end.line) + 1,
                static_cast<int>(left.location.end.column), left.kind);
            auto rightLocation = std::make_tuple(static_cast<int>(right.location.begin.line) + 1,
                static_cast<int>(right.location.begin.column), static_cast<int>(right.location.end.line) + 1,
                static_cast<int>(right.location.end.column), right.kind);
            if (leftLocation != rightLocation)
                return leftLocation < rightLocation;
            return std::strcmp(left.message.c_str(), right.message.c_str()) < 0;
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

    for (const auto& [source, node] : frontend.sourceNodes)
        for (const auto& [target, location] : node->requireLocations)
            collected.dependencies.emplace(source, target);

    return finish(collected);
}

// Only value declarations contribute paths. Types inside function signatures describe values
// supplied by callers or returned later, not members of the runtime's module tables.
struct DefinitionSurface
{
    std::unordered_map<std::string, Luau::AstType*> aliases;
    std::set<std::string> genericAliases;
    std::set<std::string> externTypes;
    std::map<std::vector<std::string>, bool> members;
    std::set<std::vector<std::string>> stringIndexed;
    std::set<Luau::AstType*> active;

    bool nilType(Luau::AstType* type, std::set<Luau::AstType*> seen = {})
    {
        if (!seen.insert(type).second)
            throw std::runtime_error("recursive type in a runtime declaration");
        if (type->is<Luau::AstTypeOptional>())
            return true;
        if (auto group = type->as<Luau::AstTypeGroup>())
            return nilType(group->type, seen);
        if (auto reference = type->as<Luau::AstTypeReference>())
        {
            if (std::strcmp(reference->name.value, "nil") == 0)
                return true;
            auto alias = aliases.find(reference->name.value);
            return alias != aliases.end() && nilType(alias->second, seen);
        }
        return false;
    }

    bool nullable(Luau::AstType* type, std::set<Luau::AstType*> seen = {})
    {
        if (!seen.insert(type).second)
            throw std::runtime_error("recursive type in a runtime declaration");
        if (type->is<Luau::AstTypeOptional>())
            return true;
        if (auto group = type->as<Luau::AstTypeGroup>())
            return nullable(group->type, seen);
        if (auto reference = type->as<Luau::AstTypeReference>())
        {
            if (std::strcmp(reference->name.value, "nil") == 0)
                return true;
            auto alias = aliases.find(reference->name.value);
            return alias != aliases.end() && nullable(alias->second, seen);
        }
        if (auto unionType = type->as<Luau::AstTypeUnion>())
        {
            for (Luau::AstType* part : unionType->types)
                if (nullable(part, seen))
                    return true;
        }
        if (auto intersection = type->as<Luau::AstTypeIntersection>())
        {
            for (Luau::AstType* part : intersection->types)
                if (!nullable(part, seen))
                    return false;
            return true;
        }
        return false;
    }

    void walk(Luau::AstType* type, const std::vector<std::string>& path, bool optional)
    {
        optional = optional || nullable(type);
        auto [entry, inserted] = members.emplace(path, optional);
        if (!inserted)
            entry->second = entry->second && optional;
        if (!active.insert(type).second)
            throw std::runtime_error("recursive type in a runtime declaration");

        if (auto table = type->as<Luau::AstTypeTable>())
        {
            if (table->indexer != nullptr)
            {
                auto key = table->indexer->indexType->as<Luau::AstTypeReference>();
                if (key == nullptr || key->prefix || std::strcmp(key->name.value, "string") != 0)
                    throw std::runtime_error("only string-indexed runtime tables can be enumerated");
                // Indexed event handlers have no statically named keys or nested table members.
                Luau::AstType* value = table->indexer->resultType;
                if (auto optionalValue = value->as<Luau::AstTypeUnion>())
                {
                    size_t alternatives = 0;
                    for (Luau::AstType* part : optionalValue->types)
                        if (!nilType(part))
                        {
                            value = part;
                            ++alternatives;
                        }
                    if (alternatives != 1)
                        throw std::runtime_error("a runtime indexer must have one non-nil function alternative");
                }
                while (auto group = value->as<Luau::AstTypeGroup>())
                    value = group->type;
                if (!value->is<Luau::AstTypeFunction>())
                    throw std::runtime_error("only function-valued runtime indexers can be enumerated");
                stringIndexed.insert(path);
            }
            for (const Luau::AstTableProp& property : table->props)
            {
                std::vector<std::string> child = path;
                child.emplace_back(property.name.value);
                walk(property.type, child, false);
            }
        }
        else if (auto reference = type->as<Luau::AstTypeReference>())
        {
            if (reference->prefix || reference->hasParameterList || genericAliases.count(reference->name.value))
                throw std::runtime_error("a qualified or generic runtime type cannot be enumerated");
            auto alias = aliases.find(reference->name.value);
            if (alias != aliases.end())
                walk(alias->second, path, optional);
            else if (!externTypes.count(reference->name.value) &&
                std::strcmp(reference->name.value, "number") != 0 &&
                std::strcmp(reference->name.value, "string") != 0 &&
                std::strcmp(reference->name.value, "boolean") != 0 &&
                std::strcmp(reference->name.value, "thread") != 0 &&
                std::strcmp(reference->name.value, "buffer") != 0 &&
                std::strcmp(reference->name.value, "nil") != 0)
                throw std::runtime_error(std::string("unresolved runtime type: ") + reference->name.value);
        }
        else if (auto group = type->as<Luau::AstTypeGroup>())
            walk(group->type, path, optional);
        else if (auto intersection = type->as<Luau::AstTypeIntersection>())
            for (Luau::AstType* part : intersection->types)
                walk(part, path, optional);
        else if (auto unionType = type->as<Luau::AstTypeUnion>())
        {
            size_t alternatives = 0;
            for (Luau::AstType* part : unionType->types)
                if (!nilType(part))
                    ++alternatives;
            if (alternatives > 1)
                throw std::runtime_error("a runtime union must have at most one non-nil alternative");
            for (Luau::AstType* part : unionType->types)
                if (!nilType(part))
                    walk(part, path, optional);
        }
        else if (!type->is<Luau::AstTypeFunction>() && !type->is<Luau::AstTypeOptional>() &&
            !type->is<Luau::AstTypeSingletonBool>() && !type->is<Luau::AstTypeSingletonString>())
            throw std::runtime_error("unsupported type in a runtime declaration");
        active.erase(type);
    }

    void collect(Luau::AstStatBlock* root)
    {
        for (Luau::AstStat* statement : root->body)
        {
            if (auto alias = statement->as<Luau::AstStatTypeAlias>())
            {
                if (alias->generics.size != 0 || alias->genericPacks.size != 0)
                    genericAliases.emplace(alias->name.value);
                else
                    aliases.emplace(alias->name.value, alias->type);
            }
            else if (auto external = statement->as<Luau::AstStatDeclareExternType>())
                externTypes.emplace(external->name.value);
        }
        for (Luau::AstStat* statement : root->body)
        {
            if (auto global = statement->as<Luau::AstStatDeclareGlobal>())
                walk(global->type, {global->name.value}, false);
            else if (auto function = statement->as<Luau::AstStatDeclareFunction>())
                members.emplace(std::vector<std::string>{function->name.value}, false);
            else if (!statement->is<Luau::AstStatTypeAlias>() && !statement->is<Luau::AstStatDeclareExternType>())
                throw std::runtime_error("unsupported statement in runtime definitions");
        }
    }
};

} // namespace

extern "C"
{

lunette_luau_surface* lunette_luau_definition_surface(const char* source, size_t length) noexcept
{
    try
    {
        if (source == nullptr)
            throw std::runtime_error("no definitions source was given");
        Luau::Allocator allocator;
        Luau::AstNameTable names(allocator);
        Luau::ParseOptions options;
        options.allowDeclarationSyntax = true;
        Luau::ParseResult parsed = Luau::Parser::parse(source, length, names, allocator, options);
        if (!parsed.errors.empty())
            throw std::runtime_error(parsed.errors.front().getMessage());
        if (parsed.root == nullptr)
            throw std::runtime_error("the parser returned no syntax tree");
        DefinitionSurface collected;
        collected.collect(parsed.root);
        std::unique_ptr<lunette_luau_surface, decltype(&lunette_luau_surface_free)> result(
            new lunette_luau_surface{}, &lunette_luau_surface_free);
        result->members = new lunette_luau_surface_member[collected.members.size()]{};
        result->member_count = collected.members.size();
        size_t index = 0;
        for (const auto& [path, optional] : collected.members)
        {
            auto& member = result->members[index++];
            member.optional = optional;
            member.string_indexed = collected.stringIndexed.count(path) != 0;
            member.path = new char*[path.size()]{};
            member.path_count = path.size();
            for (size_t part = 0; part < path.size(); ++part)
                member.path[part] = copy(path[part]).release();
        }
        return result.release();
    }
    catch (const std::exception& raised)
    {
        try
        {
            auto result = std::make_unique<lunette_luau_surface>();
            result->failure = copy(raised.what()).release();
            return result.release();
        }
        catch (...)
        {
            return nullptr;
        }
    }
    catch (...)
    {
        return nullptr;
    }
}

void lunette_luau_surface_free(lunette_luau_surface* surface)
{
    if (surface == nullptr)
        return;
    for (size_t index = 0; index < surface->member_count; ++index)
    {
        auto& member = surface->members[index];
        for (size_t part = 0; part < member.path_count; ++part)
            delete[] member.path[part];
        delete[] member.path;
    }
    delete[] surface->members;
    delete[] surface->failure;
    delete surface;
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

    for (size_t index = 0; index < report->dependency_count; ++index)
    {
        delete[] report->dependencies[index].source;
        delete[] report->dependencies[index].target;
    }
    delete[] report->dependencies;

    delete[] report->failure;
    delete report;
}

} // extern "C"
