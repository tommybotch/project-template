# Claude Code Tooling Refresh — Design

Date: 2026-08-18
Status: Approved for planning

## Goal

Replace the template's jCodemunch-based tooling with a four-tool roster, make
`setup_claude_tools.sh` run unmodified across four environments, and rebase the
project `CLAUDE.md` on Andrej Karpathy's coding guidelines.

## Tool roster

Installed:

| Tool | Role | Install path |
|------|------|--------------|
| graphify | Semantic knowledge graph over code and docs; scoped subgraph queries instead of grep | `uv tool install graphifyy`, CLI `graphify` |
| caveman | Output compression (~65% fewer output tokens) plus cavecrew subagents | `claude plugin install caveman@caveman` |
| RTK | Bash output compression via a `PreToolUse` hook | `install.sh` from `rtk-ai/rtk` |
| superpowers | Brainstorm → spec → plan → TDD workflow gates | `claude plugin install superpowers@superpowers-marketplace` |

Removed:

- **jCodemunch-MCP** — superseded by graphify.
- **codebase-memory-mcp** — overlaps graphify. Both build a per-repo code graph,
  both need re-indexing, both answer "where is X" and "what calls Y". graphify
  covers the semantic and document side; the AST call-path advantage of
  codebase-memory does not justify a second index to maintain.
- **context-mode** — collides with RTK. Both register `PreToolUse` on `Bash`:
  RTK rewrites `git status` into `rtk git status`; context-mode's
  `pretooluse.mjs` matches `Bash`, `Read`, `Grep`, `WebFetch`, `Agent`, and
  `mcp__*`, and denies `curl`/`wget` outright. Two hooks competing to mutate or
  deny the same tool call, both selling the same benefit. context-mode also
  forbids file writes through Bash, which conflicts with Bash-first editing.

Removal is **not** automated. The script detects the removed tools and prints a
warning plus the exact removal commands; it never uninstalls anything.

## Environments

One script must run on all four:

1. macOS local — darwin/arm64, non-root, Homebrew, real `~/.claude`, Claude Code
   and Node already present.
2. RunPod / headless Linux root — `/workspace` persistent volume, ephemeral
   `/root`, apt, OAuth token prompt, musl-portable binaries, `/usr/local/bin`
   symlinks.
3. Local Linux workstation, non-root — no sudo, `~/.local/bin`, no `/workspace`.
4. HPC login node — no root, no apt, tight home quota, tools may need to live in
   project or scratch space.

## Architecture: capability probes

The script detects **capabilities**, not environment names. There is no
`PROFILE=runpod` branch; each step asks what it is allowed to do.

Probed at the top of the script:

| Variable | Derivation | Used for |
|----------|-----------|----------|
| `OS_ARCH` | `uname -s` / `uname -m` → `darwin-arm64`, `linux-amd64`, `linux-arm64` | Selecting prebuilt binary URLs |
| `IS_ROOT` | `[ "$(id -u)" = 0 ]` | Whether apt and `/usr/local/bin` are available |
| `PKG` | `apt-get` \| `brew` \| `none` | Backs a single `install_pkg()` helper |
| `PERSIST_ROOT` | `$CLAUDE_TOOLS_PREFIX`, else writable `/workspace`, else `$HOME` | Root of all tool installs |
| `EPHEMERAL_HOME` | `true` when `$HOME` itself will not survive a restart (the writable-`/workspace` fallback), or the explicit `--ephemeral-home` override. **Not** implied by a custom `--prefix`/`CLAUDE_TOOLS_PREFIX` alone | Enables the `~/.claude` symlink and the auth prompt |
| `PERSIST_ROOT != $HOME` | Any custom install location, however reached | Enables the persisted-env file that `~/.bashrc` sources, so `$BIN_DIR` is on PATH in new shells |
| `CAN_LINK_USRLOCAL` | `[ -w /usr/local/bin ]` or `IS_ROOT` | Whether to create global `rtk` / `graphify` symlinks |

Derived: `BIN_DIR=$PERSIST_ROOT/.local/bin`, `CLAUDE_DIR=$PERSIST_ROOT/.claude`,
`UV_TOOL_DIR=$PERSIST_ROOT/.local/share/uv/tools`, `UV_TOOL_BIN_DIR=$BIN_DIR`,
`CARGO_HOME=$PERSIST_ROOT/.cargo`.

Consequences:

- RunPod resolves to `PERSIST_ROOT=/workspace`, `EPHEMERAL_HOME=true`,
  `IS_ROOT=true` — behavior identical to the current script, including the
  `~/.claude -> /workspace/.claude` symlink recreated on every run.
- macOS resolves to `PERSIST_ROOT=$HOME`, `EPHEMERAL_HOME=false` — no symlink
  dance, no apt, no token prompt.
- HPC is expressed as "no root, no apt, custom prefix". A user with a home quota
  sets `CLAUDE_TOOLS_PREFIX=/project/lab/tools` (or `--prefix`) and needs no code
  change. Because their `$HOME` persists, `EPHEMERAL_HOME` stays false: no
  `~/.claude` symlink and no token prompt. They still get the persisted-env file,
  since that is gated on `PERSIST_ROOT != $HOME` — the tools live somewhere no
  default PATH covers, which is true of any custom prefix regardless of whether
  the home directory survives.
- An unrecognized machine degrades: `PKG=none` warns and continues rather than
  failing the run.

`install_pkg NAME` wraps the three cases. When `PKG=none`, it prints what is
missing and returns non-zero; callers treat that as a skip with a warning, never
as a fatal error.

## Script steps

Persistence handling (create `$PERSIST_ROOT/.claude`, migrate a real
`~/.claude`, recreate the symlink) runs unconditionally before step 0, but only
when `EPHEMERAL_HOME` is true.

**0. Prerequisites** — `jq` and `curl` via `install_pkg`. When `jq` is
unavailable, steps that edit `settings.json` print the JSON to add by hand
instead of failing.

**1. Claude Code** — skip when `claude` is on PATH; otherwise the native
installer from `claude.ai/install.sh`.

**2. Auth** — skipped entirely unless `EPHEMERAL_HOME` is true, and skipped when
stdin is not a TTY. Prompts for `CLAUDE_CODE_OAUTH_TOKEN` and appends it to
`~/.bashrc`. Never prompts on a local machine that has already completed OAuth.

**3. Node.js** — required at runtime by caveman's hooks. NodeSource under apt,
`brew install node` under brew, warning under `none`.

**4. Plugins** — register marketplaces `JuliusBrussee/caveman` and
`obra/superpowers-marketplace`, then `claude plugin install` each with
`--scope user`. The standalone `caveman/hooks/install.sh` curl is **dropped**:
it duplicated the plugin install, produced two copies with two update paths, and
risked double hook registration. Failures warn and print the in-session
`/plugin install` command.

**5. RTK** — install with `RTK_INSTALL_DIR=$BIN_DIR`; verify it is Rust Token
Killer and not the name-colliding `reachingforthejack/rtk` by probing
`rtk gain --help`; run `rtk init -g --auto-patch`; then install the
absolute-path wrapper hook at `$CLAUDE_DIR/hooks/rtk-rewrite.sh`.

The wrapper is installed on **all** platforms, not just RunPod. RTK's native
hook emits a bare `rtk <cmd>`, which requires `rtk` on PATH; GUI-launched Claude
Code has an unreliable PATH on macOS as well as after a pod restart. The wrapper
pipes through the absolute binary path and rewrites the `^rtk ` prefix, failing
open on missing binary or malformed JSON. The existing self-test is retained:
feed a synthetic `git status` payload through the wrapper and assert
`hookSpecificOutput.updatedInput.command` starts with the absolute path.
Bash `PreToolUse` entries are deduplicated after patching.

**6. uv and graphify** — install uv into `$BIN_DIR`, then
`uv tool install --force graphifyy` with `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR`
pointed at `$PERSIST_ROOT`. Run `graphify install --platform claude` to register
the skill. Symlink into `/usr/local/bin` only when `CAN_LINK_USRLOCAL`; append
the `UV_TOOL_*` exports to `~/.bashrc` only when `EPHEMERAL_HOME`.

**7. Global routing block** — writes RTK and graphify guidance into
`$CLAUDE_DIR/CLAUDE.md` delimited by `<!-- claude-tools:start -->` and
`<!-- claude-tools:end -->`. On re-run the block between the markers is
replaced, not appended. The current `grep -q` plus `cat >>` pattern can never
update stale text; markers fix that.

**8. Permissions** — the interactive extra-directories loop is deleted. It built
`Read($HOME/**)` and `Read(<dir>/**)` entries that `Read(**)` already subsumes,
so it granted nothing. Replaced by a repeatable `--extra-dir PATH` flag whose
values are written to `permissions.additionalDirectories`, which does grant
access. `permissions.allow` is ensured to contain `Read(**)`. Only the
user-level `settings.json` is edited; the repository's committed
`.claude/settings.json` is never modified by the script.

**9. Roster check (warn-only)** — detects an installed `context-mode` plugin, a
`codebase-memory-mcp` binary or `mcpServers` entry, and any legacy `jcodemunch`
registration. Prints the collision rationale and the exact removal commands.
Makes no changes.

### Flags

| Flag | Effect |
|------|--------|
| `--check` | Print the probe table and detected tool status; make zero changes |
| `--prefix PATH` | Override `PERSIST_ROOT` (same as `CLAUDE_TOOLS_PREFIX`). Does not by itself imply an ephemeral home |
| `--ephemeral-home` | Force `EPHEMERAL_HOME=true` — declare that `$HOME` will not survive a restart, enabling the `~/.claude` symlink and the auth prompt |
| `--extra-dir PATH` | Repeatable; adds to `permissions.additionalDirectories` |
| `--non-interactive` | Never prompt; implies skipping the auth prompt |
| `--skip-claude`, `--skip-auth`, `--skip-node`, `--skip-plugins`, `--skip-rtk`, `--skip-uv`, `--skip-graphify`, `--skip-perms` | Per-step skips |
| `--skip-all` | All skips; performs only the persistence symlink (the post-restart path) |

Steps 0 (prerequisites) and 9 (roster check) have no individual skip flag.
`--skip-all` sets every per-step skip and additionally suppresses both, so the
run performs only the persistence symlink. `bash setup_claude_tools.sh
--skip-all` remains the RunPod post-restart command.

## Project `CLAUDE.md`

Rebased on <https://github.com/multica-ai/andrej-karpathy-skills>. The four
principles are copied verbatim into the template rather than installed as a
plugin, so a clone carries them with no setup step and no dependency on
user-scoped plugin state.

Order:

1. Karpathy guidelines — Think Before Coding, Simplicity First, Surgical
   Changes, Goal-Driven Execution, with the caution-over-speed tradeoff note and
   attribution to the source repository (MIT).
2. Project overview placeholder.
3. Environment — uv and `.venv` activation.
4. Project structure tree.
5. Path configuration via `code/utils/config.py`.
6. HPC / dSQ section, marked optional.

Removed: the `## RTK Usage` section, the full RTK command reference table, and
the jCodemunch code-exploration policy. These duplicated content already loaded
from `~/.claude/RTK.md` and `~/.claude/CLAUDE.md`, costing input tokens on every
turn. A single pointer line replaces them, stating that tooling conventions live
in `~/.claude/CLAUDE.md` and are written by `setup_claude_tools.sh`.

Size: roughly 4.1K before and after. The win is not byte count — the ~2K RTK
command table and the jCodemunch policy no longer load twice per turn (once from
the global file, once from this one); that space now carries the coding
principles instead.

Note on overlap: Karpathy's "Think Before Coding" and `superpowers:brainstorming`
express the same doctrine, as do "Goal-Driven Execution" and
`superpowers:test-driven-development`. This is intentional — prose states the
principle, the skill enforces it — and is why the guidelines live in the project
file while tool mechanics live globally.

## Global routing block content

Roughly twelve lines, written by step 7:

- graphify: build the graph, when to query the graph instead of grep, and the
  per-repo `graphify . && graphify install --project` step.
- RTK: one short paragraph noting the `PreToolUse` hook rewrites Bash commands
  automatically. No command table — `~/.claude/RTK.md` already carries it and is
  imported by the global `CLAUDE.md`.

## `README.md`

Quick start rewritten around the new script: what it installs, the flag table,
`--check` for a dry probe, `--prefix` for HPC quota cases, and the per-repo
graphify build. Adds a short "not installed by design" note naming
context-mode and codebase-memory-mcp with the reason, so a future reader does
not re-add them.

## Files changed

| File | Change |
|------|--------|
| `setup_claude_tools.sh` | Rewrite |
| `CLAUDE.md` | Rewrite |
| `README.md` | Rewrite |
| `docs/superpowers/specs/2026-08-18-claude-tooling-refresh-design.md` | New (this file) |

Unchanged: `.claude/settings.json`, `pyproject.toml`, `code/`, `.gitignore`,
`LICENSE`.

## Testing

1. `bash -n setup_claude_tools.sh` — syntax.
2. `bash setup_claude_tools.sh --check` on macOS — probe table reports
   `PERSIST_ROOT=$HOME`, `EPHEMERAL_HOME=false`, `PKG=brew`, `IS_ROOT=false`, and
   flags the installed context-mode plugin.
3. Full run on macOS — completes without error.
4. Second full run — idempotent: no duplicate marker block in
   `~/.claude/CLAUDE.md`, no duplicate Bash `PreToolUse` entry.
5. RTK hook self-test passes (absolute-path rewrite asserted).
6. `graphify --version` resolves; the graphify skill is registered.
7. `claude plugin list` shows caveman and superpowers.
8. `CLAUDE.md` renders and is under 3K.

The RunPod path cannot be exercised from a local machine. Mitigation: every
pod-specific action stays gated on the same conditions that gate it today
(`EPHEMERAL_HOME`, `IS_ROOT`, `CAN_LINK_USRLOCAL`), so the pod code path is the
current code path with a different guard expression.

## Out of scope

- Automated removal of context-mode or codebase-memory-mcp (warn only).
- Changes to `pyproject.toml`, `code/utils/config.py`, or the directory tree.
- Reconciling the three overlapping review paths (`cavecrew-reviewer`,
  `superpowers:requesting-code-review`, native `/code-review`) — noted during
  analysis, deliberately deferred.
