#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BinaryDirectory,
    [Parameter(Mandatory)] [string]$LovrDirectory,
    [Parameter(Mandatory)] [string]$LlvmMingwDirectory,
    [Parameter(Mandatory)] [string]$OutputZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$binary = (Resolve-Path -LiteralPath $BinaryDirectory).Path
$lovr = (Resolve-Path -LiteralPath $LovrDirectory).Path
$llvm = (Resolve-Path -LiteralPath $LlvmMingwDirectory).Path
$zip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputZip)
$stagedZip = "$zip.partial-$([Guid]::NewGuid())"
$runtime = Join-Path $llvm 'bin'
$manifestGenerator = Join-Path $binary 'lunette-generate-definitions.exe'

$entries = [System.Collections.Generic.SortedDictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)

function Add-PackageFile([string]$Source, [string]$Destination) {
    $file = Get-Item -LiteralPath $Source
    if ($file.PSIsContainer) { throw "Expected a regular file at '$Source'." }
    $entry = $Destination.Replace('\', '/')
    if ($entry.StartsWith('/') -or $entry -match ':' -or ($entry.Split('/') -contains '..')) {
        throw "Invalid ZIP entry '$Destination'."
    }
    $entries.Add($entry, $file.FullName)
}

$nativeDlls = 'liblovr.dll', 'libmsdfgen.dll', 'glfw3.dll', 'openvr_api.dll'
$runtimeDlls = 'libc++.dll', 'libunwind.dll', 'libwinpthread-1.dll'
Add-PackageFile "$binary/lunette.exe" 'lunette.exe'
Add-PackageFile "$binary/lunctl.exe" 'lunctl.exe'
foreach ($dll in $nativeDlls) { Add-PackageFile "$lovr/$dll" $dll }
foreach ($dll in $runtimeDlls) { Add-PackageFile "$runtime/$dll" $dll }

$actions = "$lovr/lovr-openvr/actions.json"
$bindings = (Get-Content -LiteralPath $actions -Raw | ConvertFrom-Json).default_bindings
if (@($bindings).Count -eq 0) { throw 'The OpenVR action manifest has no default controller bindings.' }
Add-PackageFile $actions 'lovr-openvr/actions.json'
foreach ($binding in $bindings) {
    $name = $binding.binding_url
    if ($name -notmatch '^bindings_[A-Za-z0-9_]+\.json$') {
        throw "Invalid default OpenVR binding filename '$name'."
    }
    Add-PackageFile "$lovr/lovr-openvr/$name" "lovr-openvr/$name"
}

$originalPath = $env:PATH
try {
    $env:PATH = "$lovr;$runtime;$originalPath"
    $manifest = & $manifestGenerator --manifest
    if ($LASTEXITCODE -ne 0 -or !$manifest) { throw 'Could not generate the Lunette install manifest.' }
    $configAliases = & $manifestGenerator --portable-config-aliases
    if ($LASTEXITCODE -ne 0 -or !$configAliases) { throw 'Could not generate portable configuration aliases.' }
} finally {
    $env:PATH = $originalPath
}

foreach ($line in $manifest) {
    $source, $destination = $line.Split([char]9, 2)
    if (!$source -or !$destination) { throw "Invalid Lunette install manifest entry '$line'." }
    $path = Join-Path $repository $source
    if (Test-Path -LiteralPath $path -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $path -File -Recurse -Force) {
            $relative = [IO.Path]::GetRelativePath($path, $file.FullName)
            if ($relative -split '[/\\]' -contains 'tests') { continue }
            Add-PackageFile $file.FullName "$destination/$relative"
        }
    } else {
        Add-PackageFile $path $destination
    }
}

foreach ($file in 'main.luau', 'conf.luau') {
    Add-PackageFile "$repository/etc/xdg/lunette/$file" "config/$file"
}
Add-PackageFile "$PSScriptRoot/README.txt" 'README.txt'
Add-PackageFile "$repository/LICENSE" 'licenses/Lunette.txt'
Add-PackageFile "$repository/CREDITS.md" 'licenses/CREDITS.md'
Add-PackageFile "$repository/vendor/lovr/LICENSE" 'licenses/LOVR.txt'
Add-PackageFile "$repository/vendor/lovr/deps/luau/LICENSE.txt" 'licenses/Luau.txt'
Add-PackageFile "$repository/vendor/lovr/deps/glfw/LICENSE.md" 'licenses/GLFW.txt'
Add-PackageFile "$repository/vendor/lovr/deps/glslang/LICENSE.txt" 'licenses/glslang.txt'
Add-PackageFile "$repository/vendor/lovr/deps/msdfgen/LICENSE.txt" 'licenses/msdfgen.txt'
Add-PackageFile "$repository/vendor/lovr/deps/openxr/LICENSE" 'licenses/OpenXR.txt'
Add-PackageFile "$llvm/LICENSE.TXT" 'licenses/LLVM-MinGW.txt'
Add-PackageFile "$llvm/x86_64-w64-mingw32/share/mingw32/COPYING.winpthreads.txt" 'licenses/winpthreads.txt'
Add-PackageFile "$llvm/x86_64-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt" 'licenses/MinGW-w64-runtime.txt'

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($zip)) | Out-Null
if ([IO.File]::Exists($zip)) { throw "The output ZIP already exists at '$zip'." }
try {
    $output = [IO.File]::Open($stagedZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $archive = [IO.Compression.ZipArchive]::new($output, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $timestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            foreach ($item in $entries.GetEnumerator()) {
                $entry = $archive.CreateEntry($item.Key, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $timestamp
                $contents = [IO.File]::OpenRead($item.Value)
                try {
                    $stream = $entry.Open()
                    try { $contents.CopyTo($stream) } finally { $stream.Dispose() }
                } finally {
                    $contents.Dispose()
                }
            }
            $aliasesEntry = $archive.CreateEntry('config/.luaurc', [IO.Compression.CompressionLevel]::Optimal)
            $aliasesEntry.LastWriteTime = $timestamp
            $aliasesWriter = [IO.StreamWriter]::new($aliasesEntry.Open(), [Text.UTF8Encoding]::new($false))
            try { $aliasesWriter.Write(($configAliases -join "`n") + "`n") } finally { $aliasesWriter.Dispose() }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $output.Dispose()
    }
    [IO.File]::Move($stagedZip, $zip)
} finally {
    if ([IO.File]::Exists($stagedZip)) { [IO.File]::Delete($stagedZip) }
}

Get-FileHash -LiteralPath $zip -Algorithm SHA256
