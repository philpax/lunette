// Filesystem navigation for the checker, including directory symlinks.
#pragma once

#include "Luau/Config.h"
#include "Luau/LuauConfig.h"
#include "Luau/RequireNavigator.h"

#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <unordered_map>

class CheckerNavigationContext : public Luau::Require::NavigationContext
{
public:
    using AliasOverrides = std::unordered_map<std::string, std::string>;

    explicit CheckerNavigationContext(std::string requirer, const AliasOverrides* aliases = nullptr)
        : requirer(std::move(requirer))
        , aliases(aliases)
    {
    }

    NavigateResult toAliasOverride(const std::string& name) override
    {
        if (aliases == nullptr)
            return NavigateResult::NotFound;
        const auto found = aliases->find(name);
        if (found == aliases->end())
            return NavigateResult::NotFound;
        const auto result = jumpToAlias(found->second);
        // NotFound means no override to Navigator; a supplied invalid target must not fall back.
        return result == NavigateResult::NotFound ? NavigateResult::Ambiguous : result;
    }

    NavigateResult resetToRequirer() override
    {
        return reset(requirer);
    }

    NavigateResult jumpToAlias(const std::string& path) override
    {
        if (!std::filesystem::path(path).is_absolute())
            return NavigateResult::NotFound;
        return reset(path);
    }

    NavigateResult toParent() override
    {
        const auto parent = modulePath.parent_path();
        if (parent == modulePath || parent == modulePath.root_path())
            return NavigateResult::NotFound;
        modulePath = parent;
        // A sibling file cannot make navigation to a containing directory ambiguous.
        return resolve(true);
    }

    NavigateResult toChild(const std::string& component) override
    {
        if (component == ".config")
            return NavigateResult::NotFound;
        modulePath = (modulePath / component).lexically_normal();
        return resolve(false);
    }

    bool isModulePresent() const
    {
        return isFile(filePath);
    }

    std::optional<std::string> getIdentifier() const
    {
        return filePath.generic_string();
    }

    ConfigStatus getConfigStatus() const override
    {
        const bool json = isFile(modulePath / Luau::kConfigName);
        const bool luau = isFile(modulePath / Luau::kLuauConfigName);
        if (json && luau)
            return ConfigStatus::Ambiguous;
        if (luau)
            return ConfigStatus::PresentLuau;
        if (!json)
            return ConfigStatus::Absent;

        // Alias components start at the actual config directory. Relative module imports stay lexical.
        std::error_code error;
        const auto actualDirectory = std::filesystem::canonical(modulePath, error);
        if (!error && actualDirectory != modulePath)
        {
            const auto selected = filePath.lexically_relative(modulePath);
            modulePath = actualDirectory;
            filePath = (modulePath / selected).lexically_normal();
        }
        return ConfigStatus::PresentJson;
    }

    ConfigBehavior getConfigBehavior() const override
    {
        return ConfigBehavior::GetConfig;
    }

    std::optional<std::string> getConfig() const override
    {
        const ConfigStatus status = getConfigStatus();
        const auto path = modulePath / (status == ConfigStatus::PresentLuau ? Luau::kLuauConfigName : Luau::kConfigName);
        std::ifstream stream(path, std::ios::binary);
        if (!stream)
            return std::nullopt;
        std::ostringstream buffer;
        buffer << stream.rdbuf();
        return buffer.str();
    }

private:
    using Path = std::filesystem::path;
    const std::string requirer;
    const AliasOverrides* aliases;
    mutable Path modulePath;
    mutable Path filePath;

    static bool isFile(const Path& path)
    {
        std::error_code error;
        return std::filesystem::is_regular_file(path, error);
    }

    static bool isDirectory(const Path& path)
    {
        std::error_code error;
        return std::filesystem::is_directory(path, error);
    }

    NavigateResult reset(const std::string& path)
    {
        std::string normalized = path;
        for (char& character : normalized)
            if (character == '\\')
                character = '/';
        std::error_code error;
        modulePath = std::filesystem::absolute(Path(normalized), error).lexically_normal();
        if (error)
            return NavigateResult::NotFound;
        if (modulePath.extension() == ".luau" || modulePath.extension() == ".lua")
        {
            modulePath.replace_extension();
            if (modulePath.filename() == "init")
                modulePath = modulePath.parent_path();
        }
        return resolve(false);
    }

    NavigateResult resolve(bool parent)
    {
        filePath.clear();
        const bool directory = isDirectory(modulePath);
        bool found = false;
        if (!parent && modulePath.filename() != "init")
        {
            for (const char* suffix : {".luau", ".lua"})
            {
                Path candidate = modulePath;
                candidate += suffix;
                if (isFile(candidate))
                {
                    if (found)
                        return NavigateResult::Ambiguous;
                    found = true;
                    filePath = candidate;
                }
            }
        }
        if (directory)
        {
            if (found)
                return NavigateResult::Ambiguous;
            for (const char* name : {"init.luau", "init.lua"})
            {
                const Path candidate = modulePath / name;
                if (isFile(candidate))
                {
                    if (found)
                    {
                        filePath = modulePath;
                        return parent ? NavigateResult::Success : NavigateResult::Ambiguous;
                    }
                    found = true;
                    filePath = candidate;
                }
            }
            if (!found)
                filePath = modulePath;
            found = true;
        }
        return found ? NavigateResult::Success : NavigateResult::NotFound;
    }
};
