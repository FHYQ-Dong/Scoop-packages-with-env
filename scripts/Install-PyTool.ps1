<#
.SYNOPSIS
    Shared installer for distributing Python CLI tools as Scoop manifests via uv.

.DESCRIPTION
    Each Python tool manifest in this bucket `depends` on `python-tool-base` and calls
    this script from its `pre_install`. It delegates dependency resolution, environment
    isolation, and on-demand Python download to uv (https://docs.astral.sh/uv/).

    - Each tool gets its OWN isolated environment inside its Scoop app dir, so
      `scoop uninstall <tool>` removes it cleanly (Scoop deletes the app dir).
    - The uv cache and the Python interpreters are SHARED across all tools, so you get
      one Python per version (not one per package) and de-duplicated dependencies.

    All shared conventions (cache location, env layout) live HERE, so individual tool
    manifests carry no environment-variable boilerplate — they only pass package/version.
#>
param(
    [Parameter(Mandatory)][string] $Package,   # PyPI package name, e.g. 'posting'
    [Parameter(Mandatory)][string] $Version,   # exact version, e.g. '1.13.2'
    [string] $Python,                          # OPTIONAL override, e.g. '3.12'. Omit to let uv pick a
                                               # compatible managed Python from the package's requires-python.
    [Parameter(Mandatory)][string] $Dir        # the calling tool's Scoop app dir (pass Scoop's $dir)
)

$ErrorActionPreference = 'Stop'

# Shared uv cache on the Scoop drive so per-tool envs (also on the Scoop drive) hydrate
# via hardlinks. This OVERRIDES any global UV_CACHE_DIR you set for dev (e.g. D:\uv-cache)
# for this install only, keeping bucket tools same-drive as Scoop.
$base = "$(scoop prefix python-tool-base)".Trim()
$env:UV_CACHE_DIR = Join-Path $base 'uv-cache'

# Per-tool isolated environment + shims live inside THIS tool's app dir.
$env:UV_TOOL_DIR     = Join-Path $Dir 'env'
$env:UV_TOOL_BIN_DIR = Join-Path $Dir 'shims'

# Use ONLY uv-managed Python interpreters (downloaded on demand), never a random system
# Python. uv picks a version compatible with the package's requires-python automatically.
# Interpreters live at uv's default shared location — do NOT override UV_PYTHON_INSTALL_DIR,
# sharing is what avoids one Python per tool.
$env:UV_PYTHON_PREFERENCE = 'only-managed'

$uvArgs = @('tool', 'install')
if ($Python) { $uvArgs += @('--python', $Python) }   # only when a manifest pins/overrides
$uvArgs += "$Package==$Version"

Write-Host "python-tool-base: installing $Package==$Version$(if ($Python) { " (Python $Python)" }) via uv -> $Dir"
& uv @uvArgs
if ($LASTEXITCODE -ne 0) {
    throw "uv tool install failed for $Package==$Version (exit $LASTEXITCODE)"
}
