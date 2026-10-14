// Parser observations of module-loader use and named member calls.
#include "analyze.h"
#include "analyze_navigation.h"
#include "analyze_source.h"
#include "Luau/Parser.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

namespace
{

struct Observation
{
    Luau::Location location;
    std::optional<std::string> requested;
    int outcome;
    std::string detail;
};

std::unique_ptr<char[]> copy(const std::string& text)
{
    auto result = std::make_unique<char[]>(text.size() + 1);
    std::memcpy(result.get(), text.data(), text.size());
    result[text.size()] = '\0';
    return result;
}

Luau::AstExpr* ungroup(Luau::AstExpr* expression)
{
    // Grouping and type assertions do not change the runtime expression's identity.
    while (true)
    {
        if (auto group = expression->as<Luau::AstExprGroup>())
            expression = group->expr;
        else if (auto assertion = expression->as<Luau::AstExprTypeAssertion>())
            expression = assertion->expr;
        else
            return expression;
    }
}

bool globalNamed(Luau::AstExpr* expression, const char* name)
{
    auto global = ungroup(expression)->as<Luau::AstExprGlobal>();
    return global && std::strcmp(global->name.value, name) == 0;
}

std::optional<std::string> literal(Luau::AstExpr* expression)
{
    auto string = ungroup(expression)->as<Luau::AstExprConstantString>();
    if (!string)
        return std::nullopt;
    return std::string(string->value.data, string->value.size);
}

std::optional<std::string> member(Luau::AstExpr* expression)
{
    expression = ungroup(expression);
    if (auto index = expression->as<Luau::AstExprIndexName>())
        return std::string(index->index.value);
    if (auto index = expression->as<Luau::AstExprIndexExpr>())
        return literal(index->index);
    return std::nullopt;
}

bool globalTableLoader(Luau::AstExpr* expression)
{
    expression = ungroup(expression);
    auto name = member(expression);
    if (!name || *name != "require")
        return false;
    if (auto index = expression->as<Luau::AstExprIndexName>())
        return globalNamed(index->expr, "_G");
    if (auto index = expression->as<Luau::AstExprIndexExpr>())
        return globalNamed(index->expr, "_G");
    return false;
}

struct NavigationErrors : Luau::Require::ErrorHandler
{
    std::string message;
    void reportError(std::string text) override
    {
        if (!message.empty())
            message += "; ";
        message += text;
    }
};

using Path = std::filesystem::path;

Path canonical(const std::string& path)
{
    std::error_code error;
    auto result = std::filesystem::canonical(Path(path), error);
    if (error)
        throw std::runtime_error("could not canonicalize " + path + ": " + error.message());
    return result;
}

std::string absolute(const std::string& path)
{
    std::error_code error;
    auto result = std::filesystem::absolute(Path(path), error);
    if (error)
        throw std::runtime_error("could not make an absolute path for " + path + ": " + error.message());
    return result.lexically_normal().generic_string();
}

bool contained(const Path& target, const Path& root)
{
    auto targetPart = target.begin();
    for (auto rootPart = root.begin(); rootPart != root.end(); ++rootPart, ++targetPart)
        if (targetPart == target.end() || *targetPart != *rootPart)
            return false;
    return true;
}

bool bare(const std::string& requested)
{
    return !requested.empty() && requested[0] != '.' && requested[0] != '@' && requested[0] != '/' && requested[0] != '\\';
}

struct Resolution
{
    std::string source;
    std::vector<Path> roots;
    CheckerNavigationContext::AliasOverrides aliases;
    std::set<std::string> preloaded;
    std::unordered_map<std::string, std::string> configured;
    LunetteAnalyze::DirectoryConfigResolver config{true};

    explicit Resolution(const lunette_require_request& request)
        : source(absolute(request.source))
    {
        if (request.allowed_root_count == 0 || request.allowed_roots == nullptr)
            throw std::runtime_error("no allowed source roots were given");
        if ((request.alias_count && !request.aliases) || (request.preloaded_count && !request.preloaded) ||
            (request.configured_count && !request.configured))
            throw std::runtime_error("a resolution context array was not given");
        for (size_t index = 0; index < request.allowed_root_count; ++index)
        {
            if (!request.allowed_roots[index])
                throw std::runtime_error("an allowed source root was not given");
            auto root = canonical(request.allowed_roots[index]);
            if (!std::filesystem::is_directory(root))
                throw std::runtime_error("an allowed source root is not a directory: " + root.generic_string());
            roots.push_back(std::move(root));
        }
        if (!inside(canonical(source)))
            throw std::runtime_error("the source is outside the allowed roots: " + source);
        config.forDirectory(LunetteAnalyze::directoryOf(source));
        for (size_t index = 0; index < request.alias_count; ++index)
        {
            const auto& alias = request.aliases[index];
            if (!alias.name || !alias.path || !Luau::isValidAlias(alias.name))
                throw std::runtime_error("an alias override is invalid");
            std::string name(alias.name);
            std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
            if (name == "self" || !aliases.emplace(name, absolute(alias.path)).second)
                throw std::runtime_error("an alias override is reserved or repeated: " + name);
        }
        for (size_t index = 0; index < request.preloaded_count; ++index)
        {
            if (!request.preloaded[index] || !preloaded.emplace(request.preloaded[index]).second)
                throw std::runtime_error("a preloaded name is missing or repeated");
        }
        for (size_t index = 0; index < request.configured_count; ++index)
        {
            const auto& entry = request.configured[index];
            if (!entry.literal || !entry.anchor || !bare(entry.literal))
                throw std::runtime_error("a configured require must name an exact bare literal and anchor");
            auto anchor = absolute(entry.anchor);
            if (!inside(canonical(anchor)) || !std::filesystem::is_regular_file(anchor))
                throw std::runtime_error("a configured anchor is not a file inside the allowed roots: " + anchor);
            config.forDirectory(LunetteAnalyze::directoryOf(anchor));
            if (!configured.emplace(entry.literal, std::move(anchor)).second || preloaded.count(entry.literal))
                throw std::runtime_error("a configured require is repeated or also preloaded");
        }
    }

    bool inside(const Path& target) const
    {
        return std::any_of(roots.begin(), roots.end(), [&](const Path& root) { return contained(target, root); });
    }

    Observation resolve(const Luau::Location& location, std::string requested)
    {
        if (preloaded.count(requested))
            return {location, requested, LUNETTE_REQUIRE_PRELOADED, requested};
        if (requested.find('\0') != std::string::npos)
            return {location, requested, LUNETTE_REQUIRE_UNRESOLVED, "a require literal holds an interior NUL"};
        auto configuredEntry = configured.find(requested);
        const auto& anchor = configuredEntry == configured.end() ? source : configuredEntry->second;
        CheckerNavigationContext navigation(anchor, aliases.empty() ? nullptr : &aliases);
        NavigationErrors errors;
        Luau::Require::Navigator navigator(navigation, errors);
        auto path = configuredEntry == configured.end() ? requested : "./" + requested;
        if (navigator.navigate(std::move(path)) != Luau::Require::Navigator::Status::Success || !navigation.isModulePresent())
            return {location, requested, LUNETTE_REQUIRE_UNRESOLVED,
                errors.message.empty() ? "the requested module is not a source file" : errors.message};
        auto identifier = navigation.getIdentifier();
        if (!identifier)
            return {location, requested, LUNETTE_REQUIRE_UNRESOLVED, "the navigator returned no module identifier"};
        std::error_code error;
        const auto target = std::filesystem::canonical(*identifier, error);
        if (error)
            return {location, requested, LUNETTE_REQUIRE_UNRESOLVED, "could not canonicalize the resolved module: " + error.message()};
        if (!inside(target))
            return {location, requested, LUNETTE_REQUIRE_UNRESOLVED, "the resolved module is outside the allowed source roots: " + target.generic_string()};
        return {location, requested, LUNETTE_REQUIRE_RESOLVED, target.generic_string()};
    }
};

struct RequireObserver : Luau::AstVisitor
{
    Resolution& resolution;
    std::vector<Observation>& observations;
    std::set<Luau::AstExpr*> classified;

    RequireObserver(Resolution& resolution, std::vector<Observation>& observations)
        : resolution(resolution), observations(observations)
    {
    }

    bool visit(Luau::AstType*) override { return true; }
    bool visit(Luau::AstTypePack*) override { return true; }

    bool visit(Luau::AstExprCall* call) override
    {
        auto callee = ungroup(call->func);
        if (globalNamed(callee, "require"))
        {
            classified.insert(callee);
            auto requested = call->args.size == 1 ? literal(call->args.data[0]) : std::nullopt;
            if (requested)
                observations.push_back(resolution.resolve(call->location, *requested));
            else
                observations.push_back({call->location, std::nullopt, LUNETTE_REQUIRE_DYNAMIC, {}});
        }
        else if (globalTableLoader(callee))
        {
            classified.insert(callee);
            auto requested = call->args.size == 1 ? literal(call->args.data[0]) : std::nullopt;
            observations.push_back({call->location, requested, LUNETTE_REQUIRE_UNSUPPORTED, {}});
        }
        // Luau's call visitor does not descend into explicit method type arguments.
        for (const auto& argument : call->typeArguments)
            if (argument.type)
                argument.type->visit(this);
            else if (argument.typePack)
                argument.typePack->visit(this);
        return true;
    }

    bool visit(Luau::AstExprGlobal* expression) override
    {
        if (globalNamed(expression, "require") && !classified.count(expression))
            observations.push_back({expression->location, std::nullopt, LUNETTE_REQUIRE_ESCAPED, {}});
        return true;
    }

    bool visit(Luau::AstExprIndexName* expression) override { return access(expression); }
    bool visit(Luau::AstExprIndexExpr* expression) override { return access(expression); }

    bool access(Luau::AstExpr* expression)
    {
        if (globalTableLoader(expression) && !classified.count(expression))
            observations.push_back({expression->location, std::nullopt, LUNETTE_REQUIRE_UNSUPPORTED, {}});
        return true;
    }

    void assignment(Luau::AstExpr* expression)
    {
        auto target = ungroup(expression);
        if (globalNamed(target, "require") || globalTableLoader(target))
        {
            classified.insert(target);
            observations.push_back({expression->location, std::nullopt,
                globalTableLoader(target) ? LUNETTE_REQUIRE_UNSUPPORTED : LUNETTE_REQUIRE_OVERWRITTEN, {}});
        }
    }

    bool visit(Luau::AstStatAssign* statement) override
    {
        for (auto target : statement->vars)
            assignment(target);
        return true;
    }

    bool visit(Luau::AstStatCompoundAssign* statement) override
    {
        assignment(statement->var);
        return true;
    }

    bool visit(Luau::AstStatFunction* statement) override
    {
        assignment(statement->name);
        return true;
    }
};

struct MemberObserver : Luau::AstVisitor
{
    const std::string name;
    std::vector<Observation>& observations;

    MemberObserver(std::string name, std::vector<Observation>& observations)
        : name(std::move(name)), observations(observations)
    {
    }

    bool visit(Luau::AstType*) override { return true; }
    bool visit(Luau::AstTypePack*) override { return true; }

    bool visit(Luau::AstExprCall* call) override
    {
        auto called = member(call->func);
        if (called && *called == name)
        {
            auto requested = call->args.size == 1 ? literal(call->args.data[0]) : std::nullopt;
            observations.push_back({call->location, requested, LUNETTE_REQUIRE_UNSUPPORTED, {}});
        }
        for (const auto& argument : call->typeArguments)
            if (argument.type)
                argument.type->visit(this);
            else if (argument.typePack)
                argument.typePack->visit(this);
        return true;
    }
};

lunette_require_report* failure(const std::string& reason)
{
    auto report = std::make_unique<lunette_require_report>();
    report->failure = copy(reason).release();
    return report.release();
}

lunette_require_report* finish(std::vector<Observation>& observations)
{
    std::sort(observations.begin(), observations.end(), [](const Observation& left, const Observation& right) {
        return std::tie(left.location.begin.line, left.location.begin.column, left.outcome) <
            std::tie(right.location.begin.line, right.location.begin.column, right.outcome);
    });
    std::unique_ptr<lunette_require_report, decltype(&lunette_require_report_free)> report(
        new lunette_require_report{}, &lunette_require_report_free);
    report->observations = new lunette_require_observation[observations.size()]{};
    report->observation_count = observations.size();
    for (size_t index = 0; index < observations.size(); ++index)
    {
        auto& output = report->observations[index];
        const auto& input = observations[index];
        output.line = static_cast<int>(input.location.begin.line) + 1;
        output.column = static_cast<int>(input.location.begin.column);
        if (input.requested)
        {
            output.requested = copy(*input.requested).release();
            output.requested_length = input.requested->size();
        }
        output.outcome = input.outcome;
        output.detail = copy(input.detail).release();
    }
    return report.release();
}

lunette_require_report* inspect(const std::string& source, Resolution* resolution, const char* memberName)
{
    // The compiler and VM share parser flags; observation must not change runtime behavior.
    auto contents = LunetteAnalyze::readSource(source);
    if (!contents)
        return failure("the source file could not be read: " + source);
    Luau::Allocator allocator;
    Luau::AstNameTable names(allocator);
    auto parsed = Luau::Parser::parse(contents->data(), contents->size(), names, allocator);
    if (!parsed.errors.empty())
    {
        std::unique_ptr<lunette_require_report, decltype(&lunette_require_report_free)> report(
            failure("the source file does not parse: " + source), &lunette_require_report_free);
        report->diagnostics = new lunette_luau_diagnostic[parsed.errors.size()]{};
        report->diagnostic_count = parsed.errors.size();
        for (size_t index = 0; index < parsed.errors.size(); ++index)
        {
            const auto& error = parsed.errors[index];
            const auto location = error.getLocation();
            auto& diagnostic = report->diagnostics[index];
            diagnostic.kind = LUNETTE_LUAU_SYNTAX_ERROR;
            diagnostic.module = copy(source).release();
            diagnostic.message = copy(error.getMessage()).release();
            diagnostic.line = static_cast<int>(location.begin.line) + 1;
            diagnostic.column = static_cast<int>(location.begin.column);
            diagnostic.end_line = static_cast<int>(location.end.line) + 1;
            diagnostic.end_column = static_cast<int>(location.end.column);
        }
        return report.release();
    }
    if (!parsed.root)
        return failure("the parser returned no syntax tree: " + source);
    std::vector<Observation> observations;
    if (resolution)
    {
        RequireObserver visitor(*resolution, observations);
        parsed.root->visit(&visitor);
    }
    else
    {
        MemberObserver visitor(memberName, observations);
        parsed.root->visit(&visitor);
    }
    return finish(observations);
}

// Even producing a failure report can fail to allocate; null is an explicit FFI failure.
template<typename Action>
lunette_require_report* guarded(Action action) noexcept
{
    try
    {
        return action();
    }
    catch (const std::exception& error)
    {
        try { return failure(error.what()); }
        catch (...) { return nullptr; }
    }
    catch (...)
    {
        try { return failure("the parser raised something that is not an exception"); }
        catch (...) { return nullptr; }
    }
}

} // namespace

extern "C"
{

lunette_require_report* lunette_luau_inspect_requires(const lunette_require_request* request) noexcept
{
    return guarded([&] {
        if (!request || !request->source)
            throw std::runtime_error("no source file was given");
        Resolution resolution(*request);
        return inspect(resolution.source, &resolution, nullptr);
    });
}

lunette_require_report* lunette_luau_inspect_member_calls(const char* source, const char* memberName) noexcept
{
    return guarded([&] {
        if (!source || !memberName || !*memberName)
            throw std::runtime_error("no source file or member name was given");
        return inspect(absolute(source), nullptr, memberName);
    });
}

void lunette_require_report_free(lunette_require_report* report)
{
    if (!report)
        return;
    for (size_t index = 0; index < report->observation_count; ++index)
    {
        delete[] report->observations[index].requested;
        delete[] report->observations[index].detail;
    }
    delete[] report->observations;
    for (size_t index = 0; index < report->diagnostic_count; ++index)
    {
        delete[] report->diagnostics[index].module;
        delete[] report->diagnostics[index].message;
    }
    delete[] report->diagnostics;
    delete[] report->failure;
    delete report;
}

} // extern "C"
