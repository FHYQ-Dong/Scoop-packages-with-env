# Scoop packages with env

Scoop bucket for distributing **npm** and **Python** command-line packages as Scoop manifests, with the runtime/environment managed for you:

- **npm packages** share a Scoop-managed Node.js runtime.
- **Python packages** get [uv](https://docs.astral.sh/uv/)-managed isolated environments, with on-demand Python and a shared, de-duplicated cache.

## npm packages — shared Node.js runtime

Each npm package is a Scoop app. Instead of bundling Node.js, manifests `depends` on a **private Node.js runtime maintained in this bucket**, and their `bin` points at that runtime's `node.exe` through Scoop's `current` symlink, passing the package's entry script as an argument.

```
scoop/
├── apps/
│   ├── nodejs22-runtime/        # private runtime — NOT on PATH, no shims
│   │   ├── 22.23.3/
│   │   ├── 22.23.5/             # after update
│   │   └── current → 22.23.5
│   ├── nodejs20-runtime/        # another major, if some package needs one
│   │   └── current → 20.20.2
│   └── devcontainer/
│       └── 0.90.0/
│           └── package/         # extract_dir: "package" (from npm tgz)
└── shims/
    ├── devcontainer.exe         # Scoop's shim stub (the same 136 KB binary for every app)
    └── devcontainer.shim        # path = …\nodejs22-runtime\current\node.exe
                                 # args = …\devcontainer\current\devcontainer.js
```

The recorded path uses the `current` symlink (not a hardcoded patch version), so it survives `scoop update` (Node repoints `current`) and `scoop cleanup` (old versions removed, `current` kept).

### Why the shim is a real `.exe`

`bin` uses Scoop's three-element form, `[target, alias, args]`:

```json
"bin": [
    [
        "..\\..\\nodejs22-runtime\\current\\node.exe",
        "devcontainer",
        "$dir\\devcontainer.js"
    ]
]
```

Because the target ends in `.exe`, Scoop writes a **real executable** to `shims/` — its own stub, plus a `.shim` file holding the interpreter path and the arguments. Scoop substitutes `$dir` for you, and by that point it is the `current` path.

That matters for callers that are not a shell. A `.cmd` shim is only found when something resolves `PATHEXT`; a bare `CreateProcess` or a Node `spawn()` without `shell: true` does not, and gets `ENOENT`. VS Code tasks are the common case — the PlatformIO IDE extension execs `platformio.exe` directly — so a `.cmd` would simply be invisible to them.

Earlier versions of this bucket generated a `.cmd` wrapper in `pre_install` and shimmed that instead. It worked from a shell but produced no `.exe`; `pre_install` now only ever runs `npm install`.

### Several Node.js majors side by side

One manifest per major, each its own Scoop app, each unpacked into its own directory: `nodejs20-runtime` and `nodejs22-runtime` install and update independently and neither is visible anywhere. A package is bound to exactly one of them by the app name baked into both its `depends` and its `bin` target, so `devcontainer` can run on Node 20 while `playwright` runs on Node 22 with no interaction between them.

Nothing has to be reconciled by hand when a new major shows up — point a package's `depends` at `nodejs<major>-runtime` and run `scripts/Sync-NodeRuntimes.ps1` (below), which writes the manifest for you.

### Why a private runtime instead of the versions bucket

`versions/nodejs22` declares `"env_add_path": ["bin", "."]` and no `bin`, so installing it puts Node.js on your **PATH**, where it shadows whatever you actually manage Node with — fnm, nvm, volta, or a system install. That is a real cost to pay for a dependency you never invoke yourself.

The runtime manifests here are a plain unpack of the official `nodejs.org` archive with **no `bin`, no `env_add_path`, no `persist`**. Installing one changes nothing you can observe: `node` on your command line stays whatever it was. The packages reach it by absolute path, which is all they ever needed.

There is one place where an absolute path is not enough. `npm install` runs dependencies' own install scripts, and those routinely shell out to a bare `node` — `node-pty`, for one, runs `node scripts/prebuild.js`. With Node.js off PATH that fails. So `pre_install` prepends the runtime to `$env:PATH` **for the install process only**:

```powershell
$runtime = "$(Split-Path (Split-Path $dir -Parent) -Parent)\nodejs22-runtime\current"
$env:PATH = "$runtime;$env:PATH"
```

That variable dies with Scoop's process; nothing reaches your environment.

`checkver`/`autoupdate` track `nodejs.org/dist/latest-v<major>.x/`, so Excavator keeps the runtimes current without anyone touching them.

### `scripts/Sync-NodeRuntimes.ps1`

```powershell
.\scripts\Sync-NodeRuntimes.ps1          # create what's missing, report the rest
.\scripts\Sync-NodeRuntimes.ps1 -Check   # report only; exit 1 if out of sync (CI)
```

It reads every manifest in `bucket/` and

- writes `nodejs<major>-runtime.json` for any runtime named in a `depends` that has no manifest yet, resolving that major's latest release and its SHA-256 from `nodejs.org`;
- **checks that each package's `bin` target names the same runtime as its own `depends`** — the app name is hardcoded there, so a mismatch silently points at a directory nobody installs, and the package fails only at run time;
- warns about runtime manifests no package depends on any more.

It deliberately does *not* bump an existing runtime to a newer patch — the runtime manifests carry `checkver`/`autoupdate`, so Excavator owns that.

## Python packages — uv-backed isolated environments

Each Python package is a Scoop app that `depends` on **`python-tool-base`** (a library manifest carrying a shared installer script) and, in `pre_install`, delegates to uv:

- **Resolution + isolation**: `uv tool install` resolves the package's full dependency tree into its own environment inside the app dir — tools never conflict with each other.
- **On-demand Python**: uv downloads a compatible Python (per the package's `requires-python`) if needed. Interpreters are shared across tools (one per version), not one per package.
- **Shared cache**: a persisted uv cache (`persist/python-tool-base/uv-cache`) de-duplicates dependencies across tools via hardlinks.

```
scoop/apps/
├── python-tool-base/current/
│   ├── Install-PyTool.ps1       # shared installer (downloaded via url)
│   └── uv-cache/ → persist      # shared uv cache
└── zotero-mcp/0.9.1/
    ├── env/                     # uv isolated environment (tool + its deps)
    └── shims/zotero-mcp.exe     # uv entry point; Scoop shims this via `bin`
```

### Why the fixed placeholder `url`

Scoop requires every manifest to have a `url` for the current architecture (`Get-SupportedArchitecture`); a script-only manifest fails with *"doesn't support current architecture"*. Python tool manifests therefore carry a **fixed placeholder `url`/`hash`** (the `python-tool-base` installer script, pinned at a tag) purely to pass that check — uv does the real install in `pre_install`, and the downloaded file is unused. The placeholder is static **and** immutable, so its hash never drifts and `autoupdate` only bumps `version` (the version comes from `checkver` against PyPI, independent of the download url). A PyPI project page or `/json` url can't be used: their content changes over time → unstable hash → failed installs.

## Setup

```powershell
scoop bucket add main       # for Python packages (provides uv, pulled via depends)
scoop bucket add packages-with-env https://github.com/FHYQ-Dong/Scoop-packages-with-env

scoop install packages-with-env/devcontainer   # npm example
scoop install packages-with-env/zotero-mcp      # Python example
```

## Available packages

- `devcontainer` — [@devcontainers/cli](https://github.com/devcontainers/cli) reference implementation (npm)
- `wavedrom-cli` — WaveDrom command-line renderer (npm)
- `skills` — (npm)
- `paseo` — [@getpaseo/cli](https://paseo.sh), drive and monitor AI coding agents from the command line, backed by a local daemon (npm)
- `playwright` — [playwright](https://playwright.dev) CLI: browser automation and end-to-end testing, codegen, trace viewer (npm)
- `playwright-cli` — [@playwright/cli](https://github.com/microsoft/playwright-cli), stateful browser CLI for coding agents, ships an agent skill (npm)
- `playwright-mcp` — [@playwright/mcp](https://github.com/microsoft/playwright-mcp), Playwright MCP server for AI browser automation / UI review (npm)
- `cf` — [Cloudflare CLI](https://developers.cloudflare.com/cf/), Cloudflare official CLI for API and Workers projects (npm)
- `resend-mcp` — [resend-mcp](https://github.com/resend/resend-mcp), Resend MCP server: send email and manage domains, contacts, broadcasts and API keys over stdio or HTTP (npm)

The three Playwright packages share one engine (`playwright-core`) and one browser cache
(`%LOCALAPPDATA%\ms-playwright`), and differ only in how they are driven: `playwright` is for
humans (write scripts, run tests), `playwright-cli` exposes a stateful session as shell commands
for coding agents, and `playwright-mcp` exposes the same capabilities over MCP.
- `zotero-mcp` — [zotero-mcp-server](https://github.com/54yyyu/zotero-mcp), Zotero MCP server for Claude and other AI assistants (Python)
- `platformio` — [PlatformIO Core](https://platformio.org), build system, debugger and toolchain manager for embedded development; provides `pio`, `platformio`, `piodebuggdb` (Python)
- `python-tool-base` — shared installer library for Python tools (a dependency, not a user tool)
- `nodejs22-runtime` — private Node.js 22 runtime for the npm packages (a dependency, not a user tool; stays off PATH)

## Contributing

### Add an npm package

1. Create `bucket/<package>.json`
2. `depends` on `nodejs<major>-runtime` (this bucket's private runtime, per the package's `engines.node`)
3. `extract_dir: "package"`; `bin` is `[["..\\..\\nodejs<major>-runtime\\current\\node.exe", "<command>", "$dir\\<entry script>"]]`, one entry per command. `pre_install` is only needed to run `npm install`
4. `checkver` + `autoupdate` track the npm registry
5. Run `.\scripts\Sync-NodeRuntimes.ps1` — creates the runtime manifest if that Node major is new to the bucket, and verifies the shim points at the runtime the manifest actually depends on

Reference: `bucket/devcontainer.json`.

### Add a Python package

1. Copy `bucket/zotero-mcp.json` as a template
2. Change `-Package <pypi-name>` in `pre_install`, `bin: shims\<command>.exe`, the `checkver` PyPI url, and `version`
3. Leave the placeholder `url`/`hash` and `depends: python-tool-base` **as-is**
4. `autoupdate: {}` — the version comes from `checkver`

Reference: `bucket/zotero-mcp.json` and `CLAUDE.md`.
