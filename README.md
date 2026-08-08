# Scoop packages with env

Scoop bucket for distributing **npm** and **Python** command-line packages as Scoop manifests, with the runtime/environment managed for you:

- **npm packages** share a Scoop-managed Node.js runtime.
- **Python packages** get [uv](https://docs.astral.sh/uv/)-managed isolated environments, with on-demand Python and a shared, de-duplicated cache.

## npm packages — shared Node.js runtime

Each npm package is a Scoop app. Instead of bundling Node.js, manifests `depends` on a Scoop-managed Node.js runtime (from the [versions](https://github.com/ScoopInstaller/Versions) bucket) and generate a `.cmd` shim that points to `node.exe` through Scoop's `current` symlink.

```
scoop/apps/
├── nodejs20/                    # Scoop-managed Node.js (via versions bucket)
│   ├── 20.20.2/
│   ├── 20.20.3/                 # after update
│   └── current → 20.20.3
├── devcontainer/
│   └── 0.87.0/
│       ├── package/             # extract_dir: "package" (from npm tgz)
│       └── devcontainer.cmd     # generated shim → node.exe via current
└── ...
```

The shim uses the `current` symlink (not a hardcoded patch version), so it survives `scoop update` (Node repoints `current`) and `scoop cleanup` (old versions removed, `current` kept). Each npm package can point at a different Node major version.

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
scoop bucket add versions   # for npm packages (nodejs18/20/22, ...)
scoop bucket add main       # for Python packages (provides uv, pulled via depends)
scoop bucket add packages-with-env https://github.com/FHYQ-Dong/Scoop-packages-with-env

scoop install packages-with-env/devcontainer   # npm example
scoop install packages-with-env/zotero-mcp      # Python example
```

## Available packages

- `devcontainer` — [@devcontainers/cli](https://github.com/devcontainers/cli) reference implementation (npm)
- `wavedrom-cli` — WaveDrom command-line renderer (npm)
- `skills` — (npm)
- `zotero-mcp` — [zotero-mcp-server](https://github.com/54yyyu/zotero-mcp), Zotero MCP server for Claude and other AI assistants (Python)
- `python-tool-base` — shared installer library for Python tools (a dependency, not a user tool)

## Contributing

### Add an npm package

1. Create `bucket/<package>.json`
2. `depends` on the Node.js version from the `versions` bucket
3. `extract_dir: "package"`; `pre_install` generates a `.cmd` shim → `node.exe` via `current`
4. `checkver` + `autoupdate` track the npm registry

Reference: `bucket/devcontainer.json`.

### Add a Python package

1. Copy `bucket/zotero-mcp.json` as a template
2. Change `-Package <pypi-name>` in `pre_install`, `bin: shims\<command>.exe`, the `checkver` PyPI url, and `version`
3. Leave the placeholder `url`/`hash` and `depends: python-tool-base` **as-is**
4. `autoupdate: {}` — the version comes from `checkver`

Reference: `bucket/zotero-mcp.json` and `CLAUDE.md`.
