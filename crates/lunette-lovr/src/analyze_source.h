// Shared source reading, configuration, and language flags for analyzer passes.
#pragma once

#include "Luau/Config.h"
#include "Luau/ConfigResolver.h"
#include "Luau/ExperimentalFlags.h"

#include <cstring>
#include <fstream>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace LunetteAnalyze
{

inline std::optional<std::string> readSource(const std::string& path)
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

inline std::string directoryOf(const std::string& path)
{
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

// The navigator handles aliases; this resolver supplies inherited language and lint settings.
struct DirectoryConfigResolver : Luau::ConfigResolver
{
    Luau::Config defaults;
    mutable std::unordered_map<std::string, Luau::Config> cache;
    bool rejectInvalidConfig;

    explicit DirectoryConfigResolver(bool rejectInvalidConfig = false)
        : rejectInvalidConfig(rejectInvalidConfig)
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
        // Omitting the mode must not lower the caller's choice.
        config.mode = defaults.mode;
        if (std::optional<std::string> contents = readSource(directory + "/" + Luau::kConfigName))
        {
            Luau::ConfigOptions options;
            options.aliasOptions = Luau::ConfigOptions::AliasOptions{directory, true};
            auto error = Luau::parseConfig(*contents, config, options);
            if (error && rejectInvalidConfig)
                throw std::runtime_error(directory + "/" + Luau::kConfigName + ": " + *error);
        }
        return cache.emplace(directory, std::move(config)).first->second;
    }
};

// All passes share one initialization because Luau flags are process-global.
inline void enableDefaultFlags()
{
    static std::once_flag once;
    std::call_once(once, [] {
        for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next)
            if (strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name))
                flag->value = true;
    });
}

} // namespace LunetteAnalyze
