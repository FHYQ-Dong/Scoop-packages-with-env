# Scoop packages with env

Scoop bucket for distributing **npm** and **Python** command-line packages as Scoop manifests, with the runtime/environment managed for you:

- **npm packages** share a Scoop-managed Node.js runtime.
- **Python packages** get [uv](https://docs.astral.sh/uv/)-managed isolated environments, with on-demand Python and a shared, de-duplicated cache.

## npm packages — shared Node.js runtime

Each npm package is a Scoop app. Instead of bundling Node.js, manifests `depends` on a **private Node.js runtime maintained in this bucket** and generate a `.cmd` shim that points to `node.exe` through Scoop's `current` symlink.

```
scoop/apps/
├── nodejs22-runtime/            # private runtime — NOT on PATH, no shims
│   ├── 22.23.2/
│   ├── 22.23.3/                 # after update
│   └── current → 22.23.3
├── devcontainer/
│   └── 0.88.0/
│       ├── package/             # extract_dir: "package" (from npm tgz)
│       └── devcontainer.cmd     # generated shim → node.exe via current
└── ...
```

The shim uses the `current` symlink (not a hardcoded patch version), so it survives `scoop update` (Node repoints `current`) and `scoop cleanup` (old versions removed, `current` kept). Each npm package can point at a different Node major version — one `nodejs<major>-runtime` manifest per major, coexisting.

### Why a private runtime instead of the versions bucket

`versions/nodejs22` declares `"env_add_path": ["bin", "."]` and no `bin`, so installing it puts Node.js on your **PATH**, where it shadows whatever you actually manage Node with — fnm, nvm, volta, or a system install. That is a real cost to pay for a dependency you never invoke yourself.

The runtime manifests here are a plain unpack of the official `nodejs.org` archive with **no `bin`, no `env_add_path`, no `persist`**. Installing one changes nothing you can observe: `node` on your command line stays whatever it was. The packages reach it by absolute path, which is all they ever needed.

`checkver`/`autoupdate` track `nodejs.org/dist/latest-v<major>.x/`, so Excavator keeps the runtimes current without anyone touching them.

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

The three Playwright packages share one engine (`playwright-core`) and one browser cache
(`%LOCALAPPDATA%\ms-playwright`), and differ only in how they are driven: `playwright` is for
humans (write scripts, run tests), `playwright-cli` exposes a stateful session as shell commands
for coding agents, and `playwright-mcp` exposes the same capabilities over MCP.
- `zotero-mcp` — [zotero-mcp-server](https://github.com/54yyyu/zotero-mcp), Zotero MCP server for Claude and other AI assistants (Python)
- `python-tool-base` — shared installer library for Python tools (a dependency, not a user tool)
- `nodejs22-runtime` — private Node.js 22 runtime for the npm packages (a dependency, not a user tool; stays off PATH)

## Contributing

### Add an npm package

1. Create `bucket/<package>.json`
2. `depends` on `nodejs<major>-runtime` (this bucket's private runtime, per the package's `engines.node`)
3. `extract_dir: "package"`; `pre_install` generates a `.cmd` shim → `node.exe` via `current`
4. `checkver` + `autoupdate` track the npm registry
5. Run `.\scripts\Sync-NodeRuntimes.ps1` — creates the runtime manifest if that Node major is new to the bucket, and verifies the shim points at the runtime the manifest actually depends on

Reference: `bucket/devcontainer.json`.

### Add a Python package

1. Copy `bucket/zotero-mcp.json` as a template
2. Change `-Package <pypi-name>` in `pre_install`, `bin: shims\<command>.exe`, the `checkver` PyPI url, and `version`
3. Leave the placeholder `url`/`hash` and `depends: python-tool-base` **as-is**
4. `autoupdate: {}` — the version comes from `checkver`

Reference: `bucket/zotero-mcp.json` and `CLAUDE.md`.
