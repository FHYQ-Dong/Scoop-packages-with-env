<#
.SYNOPSIS
    Keep the bucket's private Node.js runtime manifests in sync with the npm packages using them.

.DESCRIPTION
    npm packages in this bucket depend on a private 'nodejs<major>-runtime' manifest instead of
    the versions bucket, so the Node.js they run on never lands on PATH and cannot shadow fnm,
    nvm or a system Node. Run this after adding or editing an npm manifest.

    It verifies that

      - every 'nodejs<major>-runtime' named in a 'depends' has a manifest in bucket/
      - each package's generated shim points at the same runtime as its own 'depends'
      - no runtime manifest is left behind without a dependent

    and writes any missing runtime manifest using the latest release of that major from
    nodejs.org.

    Bumping an existing runtime to a newer patch is NOT this script's job: the runtime
    manifests carry checkver/autoupdate, so Excavator does that on its own.

.PARAMETER Check
    Report only, write nothing. Exits 1 when anything is out of sync, so CI can call it.

.EXAMPLE
    .\scripts\Sync-NodeRuntimes.ps1
    Create whatever is missing and report the rest.

.EXAMPLE
    .\scripts\Sync-NodeRuntimes.ps1 -Check
    Fail without touching the working tree.
#>
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$bucketDir = Resolve-Path (Join-Path $PSScriptRoot '..\bucket')
$runtimePattern = '^nodejs(\d+)-runtime$'
$problems = @()

# name -> parsed manifest, for every json in the bucket
$manifests = @{}
Get-ChildItem $bucketDir -Filter '*.json' | ForEach-Object {
    $manifests[$_.BaseName] = Get-Content $_.FullName -Raw | ConvertFrom-Json
}

function Get-Depends($manifest) {
    if ($null -eq $manifest.depends) { return @() }
    return @($manifest.depends)
}

# --- what the packages ask for ------------------------------------------------

$required = @{}   # runtime name -> list of packages depending on it

foreach ($name in $manifests.Keys | Sort-Object) {
    if ($name -match $runtimePattern) { continue }
    $manifest = $manifests[$name]

    foreach ($dep in Get-Depends $manifest) {
        if ($dep -notmatch $runtimePattern) { continue }

        if (-not $required.ContainsKey($dep)) { $required[$dep] = @() }
        $required[$dep] += $name

        # the shim generated in pre_install hardcodes the runtime's app name, so a
        # mismatch with 'depends' means a shim pointing at a directory nobody installs
        $preInstall = (@($manifest.pre_install) -join "`n")
        $referenced = [regex]::Matches($preInstall, 'nodejs\d+-runtime') |
            ForEach-Object { $_.Value } | Sort-Object -Unique
        foreach ($ref in $referenced) {
            if ($ref -ne $dep) {
                $problems += "$name : depends on '$dep' but pre_install points at '$ref'"
            }
        }
        if (-not $referenced) {
            $problems += "$name : depends on '$dep' but pre_install never references it"
        }
    }
}

# --- create whatever is missing -----------------------------------------------

$template = @'
{
    "version": "{{VERSION}}",
    "description": "Private Node.js {{MAJOR}} runtime for this bucket's npm packages. Adds nothing to PATH and creates no shims - packages invoke node.exe by absolute path through the 'current' symlink.",
    "homepage": "https://nodejs.org",
    "license": "MIT",
    "notes": "Internal dependency, not a user tool. It deliberately stays off PATH so it cannot shadow fnm/nvm or a system Node. For a Node.js you can call yourself, use fnm or install versions/nodejs{{MAJOR}}.",
    "architecture": {
        "64bit": {
            "url": "https://nodejs.org/dist/v{{VERSION}}/node-v{{VERSION}}-win-x64.7z",
            "hash": "{{HASH_X64}}",
            "extract_dir": "node-v{{VERSION}}-win-x64"
        },
        "arm64": {
            "url": "https://nodejs.org/dist/v{{VERSION}}/node-v{{VERSION}}-win-arm64.7z",
            "hash": "{{HASH_ARM64}}",
            "extract_dir": "node-v{{VERSION}}-win-arm64"
        }
    },
    "checkver": {
        "url": "https://nodejs.org/dist/latest-v{{MAJOR}}.x/",
        "regex": "node-v([\\d.]+)-win-x64\\.7z"
    },
    "autoupdate": {
        "architecture": {
            "64bit": {
                "url": "https://nodejs.org/dist/v$version/node-v$version-win-x64.7z",
                "extract_dir": "node-v$version-win-x64"
            },
            "arm64": {
                "url": "https://nodejs.org/dist/v$version/node-v$version-win-arm64.7z",
                "extract_dir": "node-v$version-win-arm64"
            }
        },
        "hash": {
            "url": "$baseurl/SHASUMS256.txt.asc"
        }
    }
}
'@

function New-RuntimeManifest($major, $path) {
    $index = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $release = $index | Where-Object { $_.version -like "v$major.*" } | Select-Object -First 1
    if (-not $release) { throw "nodejs.org has no release for Node.js $major" }
    $version = $release.version.TrimStart('v')

    $sums = (Invoke-WebRequest "https://nodejs.org/dist/v$version/SHASUMS256.txt").Content
    $hashes = @{}
    foreach ($arch in 'x64', 'arm64') {
        $file = "node-v$version-win-$arch.7z"
        $line = $sums -split "`n" | Where-Object { $_.TrimEnd() -like "*  $file" } | Select-Object -First 1
        if (-not $line) { throw "no SHASUMS256 entry for $file" }
        $hashes[$arch] = ($line -split '\s+')[0]
    }

    $json = $template.
        Replace('{{VERSION}}', $version).
        Replace('{{MAJOR}}', $major).
        Replace('{{HASH_X64}}', $hashes['x64']).
        Replace('{{HASH_ARM64}}', $hashes['arm64'])

    # .editorconfig: CRLF, final newline
    [IO.File]::WriteAllText($path, ($json -replace "`r`n", "`n" -replace "`n", "`r`n"))
    return $version
}

$created = @()
foreach ($runtime in $required.Keys | Sort-Object) {
    if ($manifests.ContainsKey($runtime)) { continue }

    $major = [regex]::Match($runtime, $runtimePattern).Groups[1].Value
    $path = Join-Path $bucketDir "$runtime.json"

    if ($Check) {
        $problems += "$runtime : missing, required by $($required[$runtime] -join ', ')"
        continue
    }

    Write-Host "Creating $runtime.json (Node.js $major)..." -ForegroundColor Cyan
    $version = New-RuntimeManifest $major $path
    $created += "$runtime -> $version"
}

# --- report -------------------------------------------------------------------

foreach ($name in $manifests.Keys | Where-Object { $_ -match $runtimePattern } | Sort-Object) {
    if (-not $required.ContainsKey($name)) {
        Write-Warning "$name is not used by any package - remove it, or point a package at it."
    }
}

Write-Host ''
Write-Host 'Node.js runtimes in use:' -ForegroundColor Green
foreach ($runtime in $required.Keys | Sort-Object) {
    $version = if ($manifests.ContainsKey($runtime)) { $manifests[$runtime].version }
               elseif ($created -match "^$runtime -> ") { ($created -match "^$runtime -> ") -replace '.* -> ' }
               else { '(missing)' }
    Write-Host ("  {0,-20} {1,-10} <- {2}" -f $runtime, $version, ($required[$runtime] -join ', '))
}

if ($created) {
    Write-Host ''
    Write-Host "Created: $($created -join '; ')" -ForegroundColor Green
}

if ($problems) {
    Write-Host ''
    foreach ($problem in $problems) { Write-Host "ERROR  $problem" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'In sync.' -ForegroundColor Green
exit 0
