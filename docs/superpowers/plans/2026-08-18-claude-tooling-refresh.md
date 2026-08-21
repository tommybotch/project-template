# Claude Tooling Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `setup_claude_tools.sh` around capability probes so one script installs the four-tool roster (graphify, caveman, RTK, superpowers) on macOS, RunPod root, non-root Linux, and HPC login nodes, and rebase the project `CLAUDE.md` on the Karpathy coding guidelines.

**Architecture:** The script becomes a library of shell functions plus a `main` dispatcher. Sourcing it with `SETUP_CLAUDE_TOOLS_LIB=1` defines the functions without running anything, which is what makes the pure logic (environment probes, JSON merging, marker-block rewriting, argument parsing) unit-testable from a plain bash test harness. Every install step branches on a probed capability (`IS_ROOT`, `PKG`, `PERSIST_ROOT`, `EPHEMERAL_HOME`, `CAN_LINK_USRLOCAL`) rather than on a named environment, so the current RunPod behavior is preserved as one particular combination of probe results.

**Tech Stack:** Bash 3.2, `jq`, `awk`, `curl`, `uv`, the `claude` CLI.

**Spec:** `docs/superpowers/specs/2026-08-18-claude-tooling-refresh-design.md`

## Global Constraints

- **Bash 3.2 compatible.** macOS ships bash 3.2.57. No associative arrays (`declare -A`), no `${var,,}`, no `mapfile`/`readarray`, no `|&`. Indexed arrays and `&>` are fine.
- **`set -euo pipefail`** stays at the top of the script.
- **Idempotent.** Running the script twice must produce a byte-identical `~/.claude/CLAUDE.md` and no duplicate hook entries.
- **Never modify the repository's committed `.claude/settings.json`.** The script edits `$CLAUDE_DIR/settings.json` (user level) only.
- **Never uninstall anything.** Removed tools are detected and reported, never removed.
- **Hooks fail open.** A hook that cannot do its job exits 0 and leaves the command unchanged.
- **Roster:** graphify (`uv tool install graphifyy`, CLI `graphify`), caveman (`caveman@caveman`), RTK (`rtk-ai/rtk`), superpowers (`superpowers@superpowers-marketplace`).
- **Marker strings, exact:** `<!-- claude-tools:start -->` and `<!-- claude-tools:end -->`.
- **Testability seams:** `WORKSPACE_CANDIDATE` (default `/workspace`) and `USRLOCAL_BIN` (default `/usr/local/bin`) are overridable so tests never touch real system paths.
- **Test command:** `bash tests/test_setup_claude_tools.sh` — exits 0 on success, prints one line per assertion.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `setup_claude_tools.sh` | Rewrite. Probe functions, shared helpers, nine install steps, `main` dispatcher, lib-mode guard. |
| `tests/test_setup_claude_tools.sh` | New. Plain-bash harness covering probes, argument parsing, `merge_settings`, `write_marker_block`. No framework dependency. |
| `CLAUDE.md` | Rewrite. Karpathy guidelines first, project specifics after, all tool documentation removed. |
| `README.md` | Rewrite. Quick start around the new script, flag table, per-repo graphify step, "not installed by design" note. |

Untouched: `.claude/settings.json`, `pyproject.toml`, `code/`, `.gitignore`, `LICENSE`.

---

### Task 1: Test harness, lib-mode guard, and environment probes

**Files:**
- Create: `tests/test_setup_claude_tools.sh`
- Modify: `setup_claude_tools.sh` (full rewrite starts here; replace the entire file with the content in Step 3)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `detect_os_arch()` → prints one of `darwin-arm64`, `darwin-amd64`, `linux-amd64`, `linux-arm64`, `unknown-unknown`
  - `detect_pkg()` → prints `apt` | `brew` | `none`
  - `resolve_persist_root [explicit_prefix]` → prints an absolute path
  - `run_probes()` → sets globals `OS_ARCH`, `IS_ROOT`, `PKG`, `PERSIST_ROOT`, `EPHEMERAL_HOME`, `CAN_LINK_USRLOCAL`, `BIN_DIR`, `CLAUDE_DIR`, `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `CARGO_HOME`, `SETTINGS`
  - Sourcing guard: `SETUP_CLAUDE_TOOLS_LIB=1` defines functions without executing `main`

- [ ] **Step 1: Write the failing test**

Create `tests/test_setup_claude_tools.sh`:

```bash
#!/usr/bin/env bash
# Test harness for setup_claude_tools.sh — plain bash, no framework.
# Run: bash tests/test_setup_claude_tools.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL $name"
        echo "         expected: [$expected]"
        echo "         actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# Sourcing with the lib guard must define functions without running main.
SETUP_CLAUDE_TOOLS_LIB=1
export SETUP_CLAUDE_TOOLS_LIB
# shellcheck source=/dev/null
. "$SCRIPT_DIR/setup_claude_tools.sh"

echo "detect_os_arch"
case "$(detect_os_arch)" in
    darwin-arm64|darwin-amd64|linux-amd64|linux-arm64)
        echo "  ok   returns a known platform slug"; PASS=$((PASS + 1)) ;;
    *)
        echo "  FAIL returns a known platform slug: got $(detect_os_arch)"; FAIL=$((FAIL + 1)) ;;
esac

echo "detect_pkg"
case "$(detect_pkg)" in
    apt|brew|none)
        echo "  ok   returns apt, brew, or none"; PASS=$((PASS + 1)) ;;
    *)
        echo "  FAIL returns apt, brew, or none: got $(detect_pkg)"; FAIL=$((FAIL + 1)) ;;
esac

echo "resolve_persist_root"
TMPROOT=$(mktemp -d)
HOME_SAVE="$HOME"

# 1. explicit argument wins over everything
HOME="$TMPROOT/home"
CLAUDE_TOOLS_PREFIX="$TMPROOT/envvar"
WORKSPACE_CANDIDATE="$TMPROOT/workspace"
mkdir -p "$HOME" "$WORKSPACE_CANDIDATE"
assert_eq "$TMPROOT/explicit" "$(resolve_persist_root "$TMPROOT/explicit")" \
    "explicit argument wins"

# 2. CLAUDE_TOOLS_PREFIX wins over a writable workspace
assert_eq "$TMPROOT/envvar" "$(resolve_persist_root)" \
    "CLAUDE_TOOLS_PREFIX beats workspace"

# 3. writable workspace wins over HOME
unset CLAUDE_TOOLS_PREFIX
assert_eq "$TMPROOT/workspace" "$(resolve_persist_root)" \
    "writable workspace beats HOME"

# 4. missing workspace falls back to HOME
WORKSPACE_CANDIDATE="$TMPROOT/does-not-exist"
assert_eq "$TMPROOT/home" "$(resolve_persist_root)" \
    "missing workspace falls back to HOME"

HOME="$HOME_SAVE"
rm -rf "$TMPROOT"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: FAIL — the current `setup_claude_tools.sh` has no lib guard, so sourcing it executes the installer. The run will either hang on the interactive prompt or abort. Either way the test does not reach the assertions.

- [ ] **Step 3: Write the minimal implementation**

Replace the entire contents of `setup_claude_tools.sh` with the skeleton below. Later tasks fill in the step functions; the `step_*` stubs here exist only so `main` is syntactically complete.

```bash
#!/usr/bin/env bash
# =============================================================================
# setup_claude_tools.sh — Claude Code tool setup
#
# One script, four environments. It probes capabilities rather than detecting
# named environments, so an unfamiliar machine degrades gracefully instead of
# failing.
#
#   PERSIST_ROOT     where tools are installed
#                    $CLAUDE_TOOLS_PREFIX -> writable /workspace -> $HOME
#   EPHEMERAL_HOME   true when PERSIST_ROOT is not $HOME (RunPod). Enables the
#                    ~/.claude symlink, .bashrc PATH pinning, and the auth prompt.
#   IS_ROOT / PKG    whether apt or brew can install system packages
#
# TOOLS
#   graphify     semantic knowledge graph over code and docs
#   caveman      output compression + cavecrew subagents
#   RTK          Bash output compression via a PreToolUse hook
#   superpowers  brainstorm -> spec -> plan -> TDD workflow gates
#
# Safe to re-run: every step is idempotent.
#
# Usage:
#   bash setup_claude_tools.sh                    # full install
#   bash setup_claude_tools.sh --check            # probe report, no changes
#   bash setup_claude_tools.sh --skip-all         # symlink only (post-restart)
#   bash setup_claude_tools.sh --prefix /opt/x    # custom install root
#   bash setup_claude_tools.sh --extra-dir /data  # grant Claude another directory
#
# Requires bash 3.2 or newer (macOS ships 3.2).
# =============================================================================

set -euo pipefail

# ── output helpers ────────────────────────────────────────────────────────────
step() { echo ""; echo "━━━ $* ━━━"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
info() { echo "  · $*"; }
fail() { echo "  ✗ $*"; }

# ── testability seams ─────────────────────────────────────────────────────────
# Overridable so the test harness never touches real system paths.
WORKSPACE_CANDIDATE="${WORKSPACE_CANDIDATE:-/workspace}"
USRLOCAL_BIN="${USRLOCAL_BIN:-/usr/local/bin}"

# ── probes ────────────────────────────────────────────────────────────────────

# Prints a platform slug used to select prebuilt binary URLs.
detect_os_arch() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Darwin) os=darwin ;;
        Linux)  os=linux ;;
        *)      os=unknown ;;
    esac
    case "$arch" in
        x86_64|amd64)  arch=amd64 ;;
        arm64|aarch64) arch=arm64 ;;
        *)             arch=unknown ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

# apt is only useful as root; a non-root Linux box reports none, which is
# correct — it means "cannot install system packages".
detect_pkg() {
    if [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v brew >/dev/null 2>&1; then
        echo brew
    else
        echo none
    fi
}

# Install root, in priority order: explicit argument, CLAUDE_TOOLS_PREFIX,
# a writable persistent volume, then HOME.
resolve_persist_root() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    if [ -n "${CLAUDE_TOOLS_PREFIX:-}" ]; then
        printf '%s\n' "$CLAUDE_TOOLS_PREFIX"
        return 0
    fi
    if [ -d "$WORKSPACE_CANDIDATE" ] && [ -w "$WORKSPACE_CANDIDATE" ]; then
        printf '%s\n' "$WORKSPACE_CANDIDATE"
        return 0
    fi
    printf '%s\n' "$HOME"
}

# Sets every global the install steps depend on.
run_probes() {
    OS_ARCH=$(detect_os_arch)
    PKG=$(detect_pkg)
    if [ "$(id -u)" = "0" ]; then IS_ROOT=true; else IS_ROOT=false; fi

    PERSIST_ROOT=$(resolve_persist_root "${PREFIX_ARG:-}")

    if [ "$PERSIST_ROOT" = "$HOME" ]; then EPHEMERAL_HOME=false; else EPHEMERAL_HOME=true; fi

    if [ -w "$USRLOCAL_BIN" ] || [ "$IS_ROOT" = true ]; then
        CAN_LINK_USRLOCAL=true
    else
        CAN_LINK_USRLOCAL=false
    fi

    BIN_DIR="$PERSIST_ROOT/.local/bin"
    CLAUDE_DIR="$PERSIST_ROOT/.claude"
    UV_TOOL_DIR="$PERSIST_ROOT/.local/share/uv/tools"
    UV_TOOL_BIN_DIR="$BIN_DIR"
    CARGO_HOME="$PERSIST_ROOT/.cargo"
    SETTINGS="$CLAUDE_DIR/settings.json"

    export UV_TOOL_DIR UV_TOOL_BIN_DIR CARGO_HOME
    export PATH="$BIN_DIR:$PATH"
}

# ── steps (filled in by later tasks) ──────────────────────────────────────────
step_prereqs()     { :; }
step_claude()      { :; }
step_auth()        { :; }
step_node()        { :; }
step_plugins()     { :; }
step_rtk()         { :; }
step_uv()          { :; }
step_graphify()    { :; }
step_routing()     { :; }
step_perms()       { :; }
step_roster_check(){ :; }
print_summary()    { :; }

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    run_probes
    step_prereqs
    step_claude
    step_auth
    step_node
    step_plugins
    step_rtk
    step_uv
    step_graphify
    step_routing
    step_perms
    step_roster_check
    print_summary
}

# Sourcing with SETUP_CLAUDE_TOOLS_LIB=1 defines the functions above without
# running anything — this is what makes the pure logic unit-testable.
if [ "${SETUP_CLAUDE_TOOLS_LIB:-0}" != "1" ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: PASS — every assertion reports `ok` and the run ends with `failed: 0`.

Also run `bash -n setup_claude_tools.sh`. Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/test_setup_claude_tools.sh setup_claude_tools.sh
git commit -m "refactor: rebuild setup script around capability probes"
```

---

### Task 2: Argument parsing and `--check`

**Files:**
- Modify: `setup_claude_tools.sh`
- Test: `tests/test_setup_claude_tools.sh`

**Interfaces:**
- Consumes: `run_probes()` from Task 1.
- Produces:
  - `parse_args "$@"` → sets `SKIP_CLAUDE`, `SKIP_AUTH`, `SKIP_NODE`, `SKIP_PLUGINS`, `SKIP_RTK`, `SKIP_UV`, `SKIP_GRAPHIFY`, `SKIP_PERMS`, `SKIP_EVERYTHING`, `CHECK_ONLY`, `NON_INTERACTIVE`, `PREFIX_ARG`, and the indexed array `EXTRA_DIRS`
  - `print_probe_report()` → prints the probe table; makes no changes

- [ ] **Step 1: Write the failing test**

Append to `tests/test_setup_claude_tools.sh`, immediately before the final `echo ""` summary block:

```bash
echo "parse_args"

parse_args
assert_eq "false" "$CHECK_ONLY"        "default: CHECK_ONLY false"
assert_eq "false" "$SKIP_RTK"          "default: SKIP_RTK false"
assert_eq "0"     "${#EXTRA_DIRS[@]}"  "default: no extra dirs"

parse_args --check
assert_eq "true" "$CHECK_ONLY" "--check sets CHECK_ONLY"

parse_args --skip-rtk --skip-node
assert_eq "true"  "$SKIP_RTK"  "--skip-rtk sets SKIP_RTK"
assert_eq "true"  "$SKIP_NODE" "--skip-node sets SKIP_NODE"
assert_eq "false" "$SKIP_UV"   "--skip-rtk leaves SKIP_UV alone"

parse_args --skip-all
assert_eq "true" "$SKIP_RTK"        "--skip-all sets every per-step skip"
assert_eq "true" "$SKIP_PERMS"      "--skip-all sets SKIP_PERMS"
assert_eq "true" "$SKIP_EVERYTHING" "--skip-all sets SKIP_EVERYTHING"

parse_args --prefix /opt/claude-tools
assert_eq "/opt/claude-tools" "$PREFIX_ARG" "--prefix captures the path"

parse_args --extra-dir /data/one --extra-dir /data/two
assert_eq "2"          "${#EXTRA_DIRS[@]}" "--extra-dir accumulates"
assert_eq "/data/one"  "${EXTRA_DIRS[0]}"  "--extra-dir keeps order (first)"
assert_eq "/data/two"  "${EXTRA_DIRS[1]}"  "--extra-dir keeps order (second)"

parse_args --non-interactive
assert_eq "true" "$NON_INTERACTIVE" "--non-interactive sets the flag"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: FAIL with `command not found: parse_args`.

- [ ] **Step 3: Write the minimal implementation**

Insert into `setup_claude_tools.sh` directly after the `run_probes()` function:

```bash
# ── argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    SKIP_CLAUDE=false;  SKIP_AUTH=false;     SKIP_NODE=false
    SKIP_PLUGINS=false; SKIP_RTK=false;      SKIP_UV=false
    SKIP_GRAPHIFY=false; SKIP_PERMS=false
    SKIP_EVERYTHING=false
    CHECK_ONLY=false
    NON_INTERACTIVE=false
    PREFIX_ARG=""
    EXTRA_DIRS=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --check)           CHECK_ONLY=true ;;
            --non-interactive) NON_INTERACTIVE=true ;;
            --prefix)          shift; PREFIX_ARG="${1:-}" ;;
            --prefix=*)        PREFIX_ARG="${1#--prefix=}" ;;
            --extra-dir)       shift; EXTRA_DIRS[${#EXTRA_DIRS[@]}]="${1:-}" ;;
            --extra-dir=*)     EXTRA_DIRS[${#EXTRA_DIRS[@]}]="${1#--extra-dir=}" ;;
            --skip-all)
                SKIP_CLAUDE=true; SKIP_AUTH=true; SKIP_NODE=true
                SKIP_PLUGINS=true; SKIP_RTK=true; SKIP_UV=true
                SKIP_GRAPHIFY=true; SKIP_PERMS=true
                SKIP_EVERYTHING=true ;;
            --skip-claude)     SKIP_CLAUDE=true ;;
            --skip-auth)       SKIP_AUTH=true ;;
            --skip-node)       SKIP_NODE=true ;;
            --skip-plugins)    SKIP_PLUGINS=true ;;
            --skip-rtk)        SKIP_RTK=true ;;
            --skip-uv)         SKIP_UV=true ;;
            --skip-graphify)   SKIP_GRAPHIFY=true ;;
            --skip-perms)      SKIP_PERMS=true ;;
            -h|--help)         print_usage; exit 0 ;;
            *)                 warn "unknown flag: $1" ;;
        esac
        shift || true
    done
}

print_usage() {
    sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
}

print_probe_report() {
    step "Environment"
    echo "  OS_ARCH            $OS_ARCH"
    echo "  IS_ROOT            $IS_ROOT"
    echo "  PKG                $PKG"
    echo "  PERSIST_ROOT       $PERSIST_ROOT"
    echo "  EPHEMERAL_HOME     $EPHEMERAL_HOME"
    echo "  CAN_LINK_USRLOCAL  $CAN_LINK_USRLOCAL"
    echo "  BIN_DIR            $BIN_DIR"
    echo "  CLAUDE_DIR         $CLAUDE_DIR"
    echo "  SETTINGS           $SETTINGS"
}
```

Then replace `main()` so it parses first, probes second, and honours `--check`:

```bash
main() {
    parse_args "$@"
    run_probes
    print_probe_report

    if [ "$CHECK_ONLY" = true ]; then
        step_roster_check
        echo ""
        info "--check: no changes made"
        return 0
    fi

    step_prereqs
    step_claude
    step_auth
    step_node
    step_plugins
    step_rtk
    step_uv
    step_graphify
    step_routing
    step_perms
    step_roster_check
    print_summary
}
```

Note the ordering dependency: `run_probes` reads `PREFIX_ARG`, so `parse_args` must run first. Task 1's `run_probes` already reads `${PREFIX_ARG:-}` defensively, so sourcing for tests still works.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: PASS — `failed: 0`.

Run: `bash setup_claude_tools.sh --check`

Expected: the probe table prints and the script exits 0 having changed nothing. On this Mac: `IS_ROOT false`, `PKG brew`, `PERSIST_ROOT` equal to `$HOME`, `EPHEMERAL_HOME false`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_setup_claude_tools.sh setup_claude_tools.sh
git commit -m "feat: add flag parsing and --check probe report"
```

---

### Task 3: Shared helpers — `install_pkg`, `merge_settings`, `write_marker_block`

**Files:**
- Modify: `setup_claude_tools.sh`
- Test: `tests/test_setup_claude_tools.sh`

**Interfaces:**
- Consumes: `PKG`, `SETTINGS` from Task 1.
- Produces:
  - `install_pkg NAME` → returns 0 when installed or already present; returns 1 and warns when `PKG=none`
  - `merge_settings JQ_ARGS... EXPR` → applies a jq expression to `$SETTINGS`, creating the file when absent
  - `write_marker_block FILE START END CONTENT` → replaces the block between markers, appending it when absent; idempotent

- [ ] **Step 1: Write the failing test**

Append to `tests/test_setup_claude_tools.sh` before the summary block:

```bash
echo "merge_settings"
TMPROOT=$(mktemp -d)
SETTINGS="$TMPROOT/settings.json"

merge_settings '.permissions.allow = ["Read(**)"]'
assert_eq "Read(**)" "$(jq -r '.permissions.allow[0]' "$SETTINGS")" \
    "creates settings.json when absent"

merge_settings '.model = "opus"'
assert_eq "Read(**)" "$(jq -r '.permissions.allow[0]' "$SETTINGS")" \
    "preserves existing keys on merge"
assert_eq "opus" "$(jq -r '.model' "$SETTINGS")" \
    "adds the new key"

echo "write_marker_block"
MD="$TMPROOT/CLAUDE.md"
printf 'existing content\n' > "$MD"
START='<!-- claude-tools:start -->'
END='<!-- claude-tools:end -->'

write_marker_block "$MD" "$START" "$END" "first version"
assert_eq "1" "$(grep -c 'existing content' "$MD")" "keeps pre-existing content"
assert_eq "1" "$(grep -c 'first version' "$MD")"    "writes the block body"
assert_eq "1" "$(grep -c -- "$START" "$MD")"        "writes exactly one start marker"

SNAPSHOT=$(cat "$MD")
write_marker_block "$MD" "$START" "$END" "first version"
assert_eq "$SNAPSHOT" "$(cat "$MD")" "re-running with identical content is a no-op"

write_marker_block "$MD" "$START" "$END" "second version"
assert_eq "1" "$(grep -c -- "$START" "$MD")"     "still exactly one start marker"
assert_eq "0" "$(grep -c 'first version' "$MD")" "replaces the old body"
assert_eq "1" "$(grep -c 'second version' "$MD")" "installs the new body"
assert_eq "1" "$(grep -c 'existing content' "$MD")" "still keeps pre-existing content"

rm -rf "$TMPROOT"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: FAIL with `command not found: merge_settings`.

- [ ] **Step 3: Write the minimal implementation**

Insert into `setup_claude_tools.sh` after `print_probe_report()`:

```bash
# ── shared helpers ────────────────────────────────────────────────────────────

# install_pkg NAME — install a system package if a package manager is usable.
# Returns 1 (and warns) when nothing can install; callers treat that as a skip,
# never as a fatal error.
install_pkg() {
    local pkg="$1"
    if command -v "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    case "$PKG" in
        apt)
            apt-get update -qq
            apt-get install -y "$pkg"
            ;;
        brew)
            brew install "$pkg"
            ;;
        none)
            warn "cannot install '$pkg': no usable package manager (need root+apt, or brew)"
            return 1
            ;;
    esac
    command -v "$pkg" >/dev/null 2>&1
}

# merge_settings [jq-args...] EXPR — apply a jq expression to $SETTINGS,
# creating the file when it does not exist yet.
merge_settings() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq unavailable — skipping settings.json update"
        return 1
    fi
    mkdir -p "$(dirname "$SETTINGS")"
    local tmp
    tmp=$(mktemp)
    if [ -s "$SETTINGS" ]; then
        jq "$@" "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    else
        jq -n "$@" > "$tmp" && mv "$tmp" "$SETTINGS"
    fi
}

# write_marker_block FILE START END CONTENT
# Replaces whatever sits between START and END (inclusive) with CONTENT.
# Appends the block when the markers are absent. Idempotent: running twice with
# the same CONTENT leaves the file byte-identical.
write_marker_block() {
    local file="$1" start="$2" end="$3" content="$4"
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || : > "$file"

    local tmp
    tmp=$(mktemp)

    # Drop any existing block, then trim trailing blank lines so repeated runs
    # cannot accumulate whitespace.
    awk -v s="$start" -v e="$end" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$file" | awk '
        { lines[n++] = $0 }
        END {
            while (n > 0 && lines[n-1] == "") n--
            for (i = 0; i < n; i++) print lines[i]
        }
    ' > "$tmp"

    {
        cat "$tmp"
        printf '\n%s\n%s\n%s\n' "$start" "$content" "$end"
    } > "$file"

    rm -f "$tmp"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: PASS — `failed: 0`. The `re-running with identical content is a no-op` assertion is the idempotency guarantee from the Global Constraints.

- [ ] **Step 5: Commit**

```bash
git add tests/test_setup_claude_tools.sh setup_claude_tools.sh
git commit -m "feat: add install_pkg, merge_settings, and write_marker_block helpers"
```

---

### Task 4: Persistence, prerequisites, Claude Code, auth, and Node

**Files:**
- Modify: `setup_claude_tools.sh`

**Interfaces:**
- Consumes: `run_probes()` globals, `install_pkg()`.
- Produces: `ensure_persistence()`, `step_prereqs()`, `step_claude()`, `step_auth()`, `step_node()` — all replacing the Task 1 stubs.

- [ ] **Step 1: Write the failing test**

There is no pure logic here — every function shells out to installers. Verification is behavioral, so the test for this task is a guard assertion that the local machine takes the non-ephemeral path. Append to `tests/test_setup_claude_tools.sh` before the summary block:

```bash
echo "persistence gating"
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)

# Local machine shape: PERSIST_ROOT == HOME, so no symlink dance.
HOME="$TMPROOT/home"; mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/nope"
unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG=""
run_probes
assert_eq "false" "$EPHEMERAL_HOME" "HOME install root means EPHEMERAL_HOME false"
assert_eq "$TMPROOT/home/.claude" "$CLAUDE_DIR" "CLAUDE_DIR derives from PERSIST_ROOT"

# RunPod shape: a writable persistent volume becomes PERSIST_ROOT.
WORKSPACE_CANDIDATE="$TMPROOT/workspace"; mkdir -p "$WORKSPACE_CANDIDATE"
run_probes
assert_eq "true" "$EPHEMERAL_HOME" "volume install root means EPHEMERAL_HOME true"
assert_eq "$TMPROOT/workspace/.local/bin" "$BIN_DIR" "BIN_DIR derives from PERSIST_ROOT"

HOME="$HOME_SAVE"
rm -rf "$TMPROOT"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: FAIL — `run_probes` is called without `PREFIX_ARG` being set by `parse_args` in one of the two blocks, or the assertions disagree, depending on ordering. If it unexpectedly passes, the probe wiring from Tasks 1–2 already covers it; record that and continue to Step 3.

- [ ] **Step 3: Write the minimal implementation**

Add `ensure_persistence` (new — Task 1 did not stub it) and replace the `step_prereqs`, `step_claude`, `step_auth`, and `step_node` stubs:

```bash
# ── persistence ───────────────────────────────────────────────────────────────
# Only meaningful when HOME is ephemeral (RunPod: /root is wiped on restart).
# Creates $CLAUDE_DIR on the persistent volume and points ~/.claude at it.
ensure_persistence() {
    [ "$EPHEMERAL_HOME" = true ] || return 0

    step "Persistence"
    mkdir -p "$CLAUDE_DIR"

    # First run: migrate a real ~/.claude onto the volume.
    if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; then
        cp -rn "$HOME/.claude/." "$CLAUDE_DIR/" 2>/dev/null || true
        rm -rf "$HOME/.claude"
        ok "migrated ~/.claude to $CLAUDE_DIR"
    fi

    [ -e "$HOME/.claude" ] || ln -s "$CLAUDE_DIR" "$HOME/.claude"
    export CLAUDE_CONFIG_DIR="$CLAUDE_DIR"
    ok "~/.claude -> $CLAUDE_DIR"
}

# ── 0. prerequisites ──────────────────────────────────────────────────────────
step_prereqs() {
    [ "$SKIP_EVERYTHING" = true ] && return 0
    step "0/8  Prerequisites"
    mkdir -p "$BIN_DIR" "$CLAUDE_DIR"
    for tool in curl jq; do
        if install_pkg "$tool"; then
            ok "$tool"
        else
            warn "$tool missing — steps that need it will be skipped"
        fi
    done
}

# ── 1. Claude Code ────────────────────────────────────────────────────────────
step_claude() {
    [ "$SKIP_CLAUDE" = true ] && return 0
    step "1/8  Claude Code"
    if command -v claude >/dev/null 2>&1; then
        ok "already installed: $(claude --version 2>/dev/null)"
        return 0
    fi
    info "installing via the native installer..."
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$BIN_DIR:$HOME/.local/bin:$HOME/.claude/bin:$PATH"
    if command -v claude >/dev/null 2>&1; then
        ok "installed: $(claude --version 2>/dev/null)"
    else
        warn "not in PATH yet — restart your shell"
    fi
}

# ── 2. auth ───────────────────────────────────────────────────────────────────
# Only prompts where a token is actually needed: an ephemeral home whose OAuth
# state does not survive. A local machine has already completed OAuth.
step_auth() {
    [ "$SKIP_AUTH" = true ] && return 0
    [ "$EPHEMERAL_HOME" = true ] || return 0

    step "2/8  Auth"
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        ok "CLAUDE_CODE_OAUTH_TOKEN already set"
        return 0
    fi
    if [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
        warn "no token and not interactive — set CLAUDE_CODE_OAUTH_TOKEN before running Claude Code"
        return 0
    fi
    info "paste the token from 'claude setup-token' (Enter to skip):"
    local token
    read -rs token
    echo ""
    if [ -n "$token" ]; then
        echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$token\"" >> "$HOME/.bashrc"
        export CLAUDE_CODE_OAUTH_TOKEN="$token"
        ok "saved to ~/.bashrc"
    else
        warn "skipped"
    fi
}

# ── 3. Node.js ────────────────────────────────────────────────────────────────
# Required at runtime by caveman's hooks.
step_node() {
    [ "$SKIP_NODE" = true ] && return 0
    step "3/8  Node.js"
    if command -v node >/dev/null 2>&1; then
        ok "already installed: $(node --version)"
        return 0
    fi
    case "$PKG" in
        apt)
            info "installing Node.js 22 LTS via NodeSource..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
            apt-get install -y nodejs -qq
            ok "installed: $(node --version)"
            ;;
        brew)
            brew install node && ok "installed: $(node --version)"
            ;;
        none)
            warn "node missing and no package manager — caveman hooks will not run"
            ;;
    esac
}
```

Then add the persistence call at the top of `main`, immediately after `run_probes`:

```bash
    run_probes
    ensure_persistence
    print_probe_report
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: PASS — `failed: 0`.

Run: `bash -n setup_claude_tools.sh` → exit 0.

Run: `bash setup_claude_tools.sh --check` → the probe table prints; on this Mac `EPHEMERAL_HOME false`, so no persistence section appears and no auth prompt is reachable.

- [ ] **Step 5: Commit**

```bash
git add tests/test_setup_claude_tools.sh setup_claude_tools.sh
git commit -m "feat: add persistence, prereq, Claude Code, auth, and Node steps"
```

---

### Task 5: Plugins — caveman and superpowers

**Files:**
- Modify: `setup_claude_tools.sh`

**Interfaces:**
- Consumes: probe globals.
- Produces: `step_plugins()`.

The standalone `caveman/hooks/install.sh` curl from the previous script is deliberately **not** carried over. It duplicated the plugin install, produced two copies with separate update paths, and could double-register hooks.

- [ ] **Step 1: Write the failing test**

Behavioral only — this step drives the `claude` CLI. Verification is Step 4's `claude plugin list`. Skip writing a unit test here; the assertion lives in Task 11's end-to-end checks. Proceed to Step 2 to confirm the current state.

- [ ] **Step 2: Run the check to verify it is unimplemented**

Run: `bash -c 'SETUP_CLAUDE_TOOLS_LIB=1 . ./setup_claude_tools.sh; type step_plugins | head -3'`

Expected: the stub body `{ :; }` — the step does nothing yet.

- [ ] **Step 3: Write the minimal implementation**

Replace the `step_plugins` stub:

```bash
# ── 4. plugins ────────────────────────────────────────────────────────────────
# caveman      output compression + cavecrew subagents
# superpowers  brainstorm -> spec -> plan -> TDD workflow gates
#
# Installed through `claude plugin install` only. The standalone caveman
# installer is intentionally not used: it duplicates the plugin, creates a
# second update path, and can double-register hooks.
step_plugins() {
    [ "$SKIP_PLUGINS" = true ] && return 0
    step "4/8  Plugins"

    if ! command -v claude >/dev/null 2>&1; then
        warn "claude not in PATH — skipping (install Claude Code first)"
        return 0
    fi

    info "registering marketplaces..."
    claude plugin marketplace add JuliusBrussee/caveman        >/dev/null 2>&1 || true
    claude plugin marketplace add obra/superpowers-marketplace >/dev/null 2>&1 || true

    local plugin_id name
    for plugin_id in "caveman@caveman" "superpowers@superpowers-marketplace"; do
        name="${plugin_id%%@*}"
        if claude plugin install "$plugin_id" --scope user >/dev/null 2>&1; then
            ok "$name"
        else
            warn "$name install failed — inside Claude Code run: /plugin install $plugin_id"
        fi
    done

    info "restart Claude Code, then verify with /plugins"
}
```

- [ ] **Step 4: Run the check to verify it works**

Run: `bash setup_claude_tools.sh --skip-claude --skip-auth --skip-node --skip-rtk --skip-uv --skip-graphify --skip-perms`

Expected: the Plugins section reports `✓ caveman` and `✓ superpowers`.

Run: `claude plugin list`

Expected: both appear. Both are already installed on this machine, so this run exercises the idempotent path — it must not error.

- [ ] **Step 5: Commit**

```bash
git add setup_claude_tools.sh
git commit -m "feat: install caveman and superpowers via the plugin CLI"
```

---

### Task 6: RTK and the absolute-path hook wrapper

**Files:**
- Modify: `setup_claude_tools.sh`

**Interfaces:**
- Consumes: `BIN_DIR`, `CLAUDE_DIR`, `SETTINGS`, `CAN_LINK_USRLOCAL`, `USRLOCAL_BIN`.
- Produces: `step_rtk()`, which writes `$CLAUDE_DIR/hooks/rtk-rewrite.sh` and points the Bash `PreToolUse` hook at it.

The wrapper is installed on **all** platforms. RTK's native hook emits a bare `rtk <cmd>`, which needs `rtk` on PATH; GUI-launched Claude Code has an unreliable PATH on macOS just as `/root/.local/bin` vanishes after a pod restart.

- [ ] **Step 1: Write the failing test**

The wrapper's contract is testable directly: feed it a synthetic payload and assert the rewrite. Append to `tests/test_setup_claude_tools.sh` before the summary block:

```bash
echo "rtk wrapper contract"
if command -v rtk >/dev/null 2>&1 && [ -f "$HOME/.claude/hooks/rtk-rewrite.sh" ]; then
    RTK_TEST_OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | bash "$HOME/.claude/hooks/rtk-rewrite.sh" 2>/dev/null)
    RTK_CMD=$(printf '%s' "$RTK_TEST_OUT" \
        | jq -r '.hookSpecificOutput.updatedInput.command // ""' 2>/dev/null)
    case "$RTK_CMD" in
        /*rtk\ git\ status)
            echo "  ok   wrapper rewrites to an absolute rtk path"; PASS=$((PASS + 1)) ;;
        *)
            echo "  FAIL wrapper rewrite: got [$RTK_CMD]"; FAIL=$((FAIL + 1)) ;;
    esac
else
    echo "  skip rtk or wrapper not installed yet"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: the RTK block reports `FAIL` or `skip`. On this machine a wrapper from the old setup already exists at `~/.claude/hooks/rtk-rewrite.sh`, so it may already report `ok` — that is fine, it confirms the contract this task must preserve.

- [ ] **Step 3: Write the minimal implementation**

Replace the `step_rtk` stub:

```bash
# ── 5. RTK (Rust Token Killer) ────────────────────────────────────────────────
step_rtk() {
    [ "$SKIP_RTK" = true ] && return 0
    step "5/8  RTK"

    # `rtk gain` exists only on Rust Token Killer — this distinguishes it from
    # the unrelated project that also ships an `rtk` binary.
    if command -v rtk >/dev/null 2>&1 && rtk gain --help >/dev/null 2>&1; then
        ok "already installed: $(rtk --version 2>/dev/null)"
    else
        if command -v rtk >/dev/null 2>&1; then
            warn "a different 'rtk' is on PATH ($(command -v rtk)) — installing Token Killer to $BIN_DIR"
        fi
        RTK_INSTALL_DIR="$BIN_DIR"
        export RTK_INSTALL_DIR
        mkdir -p "$RTK_INSTALL_DIR"
        curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
        export PATH="$BIN_DIR:$PATH"
        if command -v rtk >/dev/null 2>&1; then
            ok "installed: $(rtk --version 2>/dev/null)"
        else
            warn "not in PATH — restart your shell"
            return 0
        fi
    fi

    # Make bare `rtk` resolve in every shell where we are allowed to.
    if [ "$CAN_LINK_USRLOCAL" = true ] && [ -x "$BIN_DIR/rtk" ]; then
        ln -sf "$BIN_DIR/rtk" "$USRLOCAL_BIN/rtk" 2>/dev/null \
            && ok "symlinked into $USRLOCAL_BIN" \
            || warn "could not symlink into $USRLOCAL_BIN"
    fi

    command -v rtk >/dev/null 2>&1 || return 0
    local rtk_bin hooks_dir rtk_hook
    rtk_bin=$(command -v rtk)
    hooks_dir="$CLAUDE_DIR/hooks"
    rtk_hook="$hooks_dir/rtk-rewrite.sh"

    # Writes the hook entry, RTK.md, and settings.json without prompting.
    rtk init -g --auto-patch >/dev/null 2>&1 \
        && ok "rtk init (hook + RTK.md + settings.json)" \
        || info "rtk already configured"

    # RTK's native hook emits a bare `rtk <cmd>`, which requires rtk on PATH.
    # GUI-launched Claude Code has an unreliable PATH, so always route through
    # a wrapper that substitutes the absolute binary path. Fails open.
    mkdir -p "$hooks_dir"
    cat > "$rtk_hook" << HOOK
#!/usr/bin/env bash
# RTK PreToolUse hook — runs Bash commands through rtk via an ABSOLUTE path.
# PATH-independent: never depends on \`rtk\` being on PATH.
RTK=${rtk_bin}
[[ -x "\$RTK" ]] || exit 0                       # fail open if rtk is absent
input=\$(cat)
out=\$(printf '%s' "\$input" | "\$RTK" hook claude 2>/dev/null) || exit 0
printf '%s' "\$out" | jq -ce '
  if .hookSpecificOutput.updatedInput.command
  then .hookSpecificOutput.updatedInput.command |=
       sub("^rtk "; "${rtk_bin} ")
  else . end
' 2>/dev/null || exit 0                          # fail open on bad/empty JSON
HOOK
    chmod +x "$rtk_hook"

    # Point the Bash PreToolUse hook at the wrapper, then dedupe Bash entries so
    # re-runs cannot stack duplicates.
    if command -v jq >/dev/null 2>&1 && [ -s "$SETTINGS" ]; then
        local tmp
        tmp=$(mktemp)
        jq --arg script "bash $rtk_hook" '
            walk(
              if type == "object"
                 and (.command? // "" | test("rtk hook claude|rtk-rewrite\\.sh"))
              then .command = $script
              else . end
            )
            | .hooks.PreToolUse |= (
                (map(select(.matcher == "Bash")) | unique_by(.hooks[0].command))
                + map(select(.matcher != "Bash"))
              )
        ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    fi

    # Self-test: the wrapper must emit an absolute-path rewrite.
    local test_out
    test_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | bash "$rtk_hook" 2>/dev/null)
    if printf '%s' "$test_out" \
        | jq -e ".hookSpecificOutput.updatedInput.command | startswith(\"$rtk_bin \")" >/dev/null 2>&1; then
        ok "hook verified: $rtk_hook"
    else
        warn "wrapper produced no rewrite — Bash runs un-proxied (fail-open)"
    fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash setup_claude_tools.sh --skip-claude --skip-auth --skip-node --skip-plugins --skip-uv --skip-graphify --skip-perms`

Expected: `✓ hook verified: /Users/<you>/.claude/hooks/rtk-rewrite.sh`.

Run: `bash tests/test_setup_claude_tools.sh`

Expected: PASS including `ok wrapper rewrites to an absolute rtk path`.

Verify no duplicate Bash hook entries:

```bash
jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length' ~/.claude/settings.json
```

Expected: `1`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_setup_claude_tools.sh setup_claude_tools.sh
git commit -m "feat: install RTK with a PATH-independent hook wrapper"
```

---

### Task 7: uv and graphify

**Files:**
- Modify: `setup_claude_tools.sh`

**Interfaces:**
- Consumes: `BIN_DIR`, `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `EPHEMERAL_HOME`, `CAN_LINK_USRLOCAL`.
- Produces: `step_uv()`, `step_graphify()`.

The PyPI package is `graphifyy` (double y); the CLI it installs is `graphify`.

- [ ] **Step 1: Write the failing test**

Behavioral. Confirm the current state instead:

Run: `command -v graphify || echo "not installed"`

Expected: `not installed` on this machine.

- [ ] **Step 2: Run the check to verify it is unimplemented**

Run: `bash -c 'SETUP_CLAUDE_TOOLS_LIB=1 . ./setup_claude_tools.sh; type step_graphify | head -3'`

Expected: the stub body `{ :; }`.

- [ ] **Step 3: Write the minimal implementation**

Replace the `step_uv` and `step_graphify` stubs:

```bash
# ── 6. uv ─────────────────────────────────────────────────────────────────────
step_uv() {
    [ "$SKIP_UV" = true ] && return 0
    step "6/8  uv"
    if command -v uv >/dev/null 2>&1; then
        ok "already installed: $(uv --version)"
        return 0
    fi
    UV_INSTALL_DIR="$BIN_DIR" curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$BIN_DIR:$PATH"
    if command -v uv >/dev/null 2>&1; then
        ok "installed: $(uv --version)"
    else
        warn "not in PATH — restart your shell"
    fi
}

# ── 7. graphify ───────────────────────────────────────────────────────────────
# https://github.com/Graphify-Labs/graphify
# Builds a knowledge graph (god nodes, communities, cross-file edges) from a
# repo or doc folder, then answers questions against that scoped subgraph
# instead of raw grep.
#
# The PyPI package is `graphifyy` (double y); the CLI is `graphify`.
step_graphify() {
    [ "$SKIP_GRAPHIFY" = true ] && return 0
    step "7/8  graphify"

    if ! command -v uv >/dev/null 2>&1; then
        warn "uv not in PATH — skipping (run without --skip-uv first)"
        return 0
    fi

    mkdir -p "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR"

    if [ -x "$UV_TOOL_BIN_DIR/graphify" ]; then
        ok "already installed: $("$UV_TOOL_BIN_DIR/graphify" --version 2>/dev/null)"
    else
        if command -v graphify >/dev/null 2>&1; then
            warn "graphify found at $(command -v graphify) — outside $PERSIST_ROOT, reinstalling"
        fi
        info "installing graphifyy via uv (pulls tree-sitter grammars, ~1 min)..."
        if uv tool install --force graphifyy; then
            ok "installed: $("$UV_TOOL_BIN_DIR/graphify" --version 2>/dev/null)"
        else
            warn "install failed — retry: uv tool install graphifyy"
            return 0
        fi
    fi

    export PATH="$UV_TOOL_BIN_DIR:$PATH"

    if [ "$CAN_LINK_USRLOCAL" = true ] && [ -x "$UV_TOOL_BIN_DIR/graphify" ]; then
        ln -sf "$UV_TOOL_BIN_DIR/graphify" "$USRLOCAL_BIN/graphify" 2>/dev/null \
            && ok "symlinked into $USRLOCAL_BIN" \
            || warn "could not symlink into $USRLOCAL_BIN"
    fi

    # Only pin uv's tool dirs in .bashrc where HOME is ephemeral; on a local
    # machine the defaults already persist and editing .bashrc is intrusive.
    if [ "$EPHEMERAL_HOME" = true ] && ! grep -q 'UV_TOOL_DIR' "$HOME/.bashrc" 2>/dev/null; then
        {
            echo "export UV_TOOL_DIR=$UV_TOOL_DIR"
            echo "export UV_TOOL_BIN_DIR=$UV_TOOL_BIN_DIR"
        } >> "$HOME/.bashrc"
        ok "UV_TOOL_DIR pinned in ~/.bashrc"
    fi

    if command -v graphify >/dev/null 2>&1; then
        graphify install --platform claude >/dev/null 2>&1 \
            && ok "Claude Code skill registered" \
            || warn "skill registration failed — run: graphify install --platform claude"
    fi

    info "per repo: cd <repo> && graphify . && graphify install --project"
}
```

- [ ] **Step 4: Run the check to verify it works**

Run: `bash setup_claude_tools.sh --skip-claude --skip-auth --skip-node --skip-plugins --skip-rtk --skip-perms`

Expected: uv reports already installed; graphify installs and reports a version.

Run: `graphify --version`

Expected: a version string.

Run the same command a second time. Expected: `✓ already installed` — no reinstall.

- [ ] **Step 5: Commit**

```bash
git add setup_claude_tools.sh
git commit -m "feat: install uv and graphify with persistent tool dirs"
```

---

### Task 8: Global routing block, permissions, roster check, summary

**Files:**
- Modify: `setup_claude_tools.sh`

**Interfaces:**
- Consumes: `write_marker_block()`, `merge_settings()`, `EXTRA_DIRS`, probe globals.
- Produces: `step_routing()`, `step_perms()`, `step_roster_check()`, `print_summary()`.

The permissions step drops the previous interactive extra-directories loop: it built `Read($HOME/**)` and `Read(<dir>/**)` entries that `Read(**)` already subsumes, so it granted nothing. Extra directories now go to `permissions.additionalDirectories`, which does grant access.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_setup_claude_tools.sh` before the summary block:

```bash
echo "permissions merge"
TMPROOT=$(mktemp -d)
SETTINGS="$TMPROOT/settings.json"
printf '{"model":"opus"}\n' > "$SETTINGS"

EXTRA_DIRS=(/data/one /data/two)
apply_permissions

assert_eq "opus" "$(jq -r '.model' "$SETTINGS")" \
    "permissions merge preserves unrelated keys"
assert_eq "1" "$(jq '[.permissions.allow[] | select(. == "Read(**)")] | length' "$SETTINGS")" \
    "allow contains exactly one Read(**)"
assert_eq "2" "$(jq '.permissions.additionalDirectories | length' "$SETTINGS")" \
    "extra dirs land in additionalDirectories"

apply_permissions
assert_eq "1" "$(jq '[.permissions.allow[] | select(. == "Read(**)")] | length' "$SETTINGS")" \
    "re-running does not duplicate Read(**)"
assert_eq "2" "$(jq '.permissions.additionalDirectories | length' "$SETTINGS")" \
    "re-running does not duplicate extra dirs"

rm -rf "$TMPROOT"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: FAIL with `command not found: apply_permissions`.

- [ ] **Step 3: Write the minimal implementation**

Replace the `step_routing`, `step_perms`, `step_roster_check`, and `print_summary` stubs, and add `apply_permissions` (the pure part `step_perms` delegates to, which is what the test drives):

```bash
# ── 8. global routing block ───────────────────────────────────────────────────
# Written between markers so a re-run REPLACES the block instead of appending.
# Project CLAUDE.md files carry no tool documentation — it lives here once.
ROUTING_START='<!-- claude-tools:start -->'
ROUTING_END='<!-- claude-tools:end -->'

routing_block_content() {
    cat << 'ROUTING'
## Code exploration — graphify

Query the knowledge graph before grepping. The graph knows structure and
concepts; grep knows text.

- Per repo, once: `graphify . && graphify install --project`
- Then ask questions against the graph via the `graphify` skill.
- Use Grep/Glob for literal text search — that is what they are good at.

## Shell commands — RTK

A `PreToolUse` hook rewrites Bash commands through `rtk` automatically. Write
commands normally; the hook handles compression. Full command reference lives in
`~/.claude/RTK.md`.
ROUTING
}

step_routing() {
    [ "$SKIP_EVERYTHING" = true ] && return 0
    step "8/8  Global routing block"
    write_marker_block "$CLAUDE_DIR/CLAUDE.md" \
        "$ROUTING_START" "$ROUTING_END" "$(routing_block_content)"
    ok "written to $CLAUDE_DIR/CLAUDE.md"
}

# ── 9. permissions ────────────────────────────────────────────────────────────
# Edits the USER-level settings only. The repository's committed
# .claude/settings.json is never touched.
apply_permissions() {
    local extra_json
    if [ "${#EXTRA_DIRS[@]}" -gt 0 ]; then
        extra_json=$(printf '%s\n' "${EXTRA_DIRS[@]}" | jq -R . | jq -s .)
    else
        extra_json='[]'
    fi
    merge_settings --argjson extra "$extra_json" '
        .permissions.allow =
            (((.permissions.allow // []) + ["Read(**)"]) | unique)
        | .permissions.additionalDirectories =
            (((.permissions.additionalDirectories // []) + $extra) | unique)
    '
}

step_perms() {
    [ "$SKIP_PERMS" = true ] && return 0
    step "9/9  Permissions"
    if apply_permissions; then
        ok "written to $SETTINGS"
        [ "${#EXTRA_DIRS[@]}" -gt 0 ] && info "extra directories: ${EXTRA_DIRS[*]}"
    else
        warn "could not update $SETTINGS"
    fi
}

# ── roster check (warn only, never removes) ───────────────────────────────────
# The roster is graphify, caveman, RTK, superpowers. These three overlap or
# collide with it and are intentionally absent.
step_roster_check() {
    [ "$SKIP_EVERYTHING" = true ] && return 0
    local found=false

    if [ -d "$CLAUDE_DIR/plugins/cache/context-mode" ]; then
        found=true
        warn "context-mode is installed"
        info "  It registers PreToolUse on Bash, as RTK does. Two hooks compete to"
        info "  rewrite or deny the same call; context-mode denies curl/wget outright."
        info "  Remove with: claude plugin uninstall context-mode@context-mode"
    fi

    if [ -x "$BIN_DIR/codebase-memory-mcp" ] \
        || { command -v jq >/dev/null 2>&1 && [ -s "$SETTINGS" ] \
             && jq -e '.mcpServers["codebase-memory-mcp"]' "$SETTINGS" >/dev/null 2>&1; }; then
        found=true
        warn "codebase-memory-mcp is installed"
        info "  It overlaps graphify: a second code graph to keep indexed."
        info "  Remove with: rm -f $BIN_DIR/codebase-memory-mcp"
        info "  and delete the .mcpServers[\"codebase-memory-mcp\"] entry from $SETTINGS"
    fi

    if command -v jq >/dev/null 2>&1 && [ -s "$HOME/.claude.json" ] \
        && jq -e '.mcpServers["jcodemunch"]' "$HOME/.claude.json" >/dev/null 2>&1; then
        found=true
        warn "jcodemunch is registered (superseded by graphify)"
        info "  Remove with: claude mcp remove jcodemunch"
    fi

    if [ "$found" = true ]; then
        step "Roster check"
        info "nothing was removed — these are reported only"
    fi
}

# ── summary ───────────────────────────────────────────────────────────────────
print_summary() {
    [ "$SKIP_EVERYTHING" = true ] && return 0
    echo ""
    echo "  ══════════════════════════"
    echo "  Done"
    echo "  ══════════════════════════"
    echo ""
    command -v claude   >/dev/null 2>&1 && echo "  ✓ claude   $(claude --version 2>/dev/null)"   || echo "  ✗ claude"
    command -v node     >/dev/null 2>&1 && echo "  ✓ node     $(node --version)"                 || echo "  ✗ node"
    command -v rtk      >/dev/null 2>&1 && echo "  ✓ rtk      $(rtk --version 2>/dev/null)"      || echo "  ✗ rtk"
    command -v uv       >/dev/null 2>&1 && echo "  ✓ uv       $(uv --version)"                   || echo "  ✗ uv"
    command -v graphify >/dev/null 2>&1 && echo "  ✓ graphify $(graphify --version 2>/dev/null)" || echo "  ✗ graphify"
    echo ""
    echo "  Next:"
    echo "  1. restart your shell"
    echo "  2. cd your-project && claude"
    echo "  3. /plugins  → verify caveman and superpowers"
    echo "  4. graphify . && graphify install --project"
    echo ""
}
```

The `step_routing` and `step_perms` calls already sit in `main` from Task 1.

Two consistency fixes to apply while here:

1. **Renumber the step banners.** Tasks 4–7 wrote `step "N/8 ..."`. Change every
   one to `/9` so the sequence reads: `0/9 Prerequisites`, `1/9 Claude Code`,
   `2/9 Auth`, `3/9 Node.js`, `4/9 Plugins`, `5/9 RTK`, `6/9 uv`,
   `7/9 graphify`, `8/9 Global routing block`, `9/9 Permissions`. The roster
   check prints no number — it is a report, not an install step.
2. **`--skip-all` really means all.** `step_prereqs`, `step_routing`,
   `step_roster_check`, and `print_summary` each guard on `SKIP_EVERYTHING`, so
   `--skip-all` performs only the persistence symlink, as the spec requires.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_setup_claude_tools.sh`

Expected: PASS — `failed: 0`.

Run: `bash setup_claude_tools.sh --check`

Expected: the roster check warns about the installed `context-mode` plugin and prints its uninstall command, changing nothing.

- [ ] **Step 5: Commit**

```bash
git add tests/test_setup_claude_tools.sh setup_claude_tools.sh
git commit -m "feat: add routing block, permissions, roster check, and summary"
```

---

### Task 9: Rebase `CLAUDE.md` on the Karpathy guidelines

**Files:**
- Modify: `CLAUDE.md` (full replacement)

**Interfaces:**
- Consumes: nothing.
- Produces: a template `CLAUDE.md` with no tool documentation. The routing block written by `step_routing` is the only place RTK and graphify are documented.

- [ ] **Step 1: Write the failing test**

Run:

```bash
grep -c -E 'RTK|jCodemunch|jcodemunch' CLAUDE.md
```

Expected: a non-zero count — the current file carries the duplicated tool documentation this task removes.

- [ ] **Step 2: Record the baseline**

Run: `wc -c CLAUDE.md`

Expected: roughly 4100 bytes. The target after rewrite is under 3000.

- [ ] **Step 3: Write the implementation**

Replace the entire contents of `CLAUDE.md`:

```markdown
# [PROJECT_NAME]

## Coding Guidelines

Behavioral guidelines that reduce common LLM coding mistakes. Adapted from
[andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT), derived from Andrej Karpathy's observations on LLM coding pitfalls.

**Tradeoff:** These bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports, variables, and functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it
work") require constant clarification.

## Tooling

Tool conventions — graphify for code exploration, RTK for shell commands — live
in `~/.claude/CLAUDE.md`, written by `setup_claude_tools.sh`. They are not
repeated here.

## Project Overview

[Brief description of the project's scientific goals and methods.]

## Environment

Activate the project environment before running any script:

```bash
source .venv/bin/activate
# or: uv run python script.py
```

## Project Structure

```
[PROJECT_NAME]/
├── code/
│   ├── analysis/          # Core analysis scripts
│   ├── notebooks/         # Jupyter notebooks for exploration/visualization
│   ├── plot/              # Plotting utilities
│   ├── stats/             # Statistical analysis (Python/R)
│   ├── submit_scripts/    # HPC job submission (optional — SLURM/dSQ)
│   │   ├── dsq/           # dSQ shell scripts
│   │   └── joblists/      # Job list text files
│   └── utils/             # Shared utilities
│       └── config.py      # Centralized path configuration
├── datasets/              # Symlinks or metadata for raw data
├── derivatives/
│   ├── results/           # Analysis outputs
│   └── logs/              # Job logs
└── README.md
```

## Path Configuration

All paths are centralized in `code/utils/config.py`:

- `BASE_DIR` — project root, auto-detected from the file's location
- `DATASETS_DIR` — raw data; override with the `DATASETS_DIR` environment variable
- `SCRATCH_DIR` — intermediate files; uses `$SCRATCH`, then `$TMPDIR`, then `.scratch/`

## HPC Usage (optional)

For SLURM clusters with dSQ. Skip when running locally or under another scheduler.

```bash
sbatch code/submit_scripts/dsq/dsq_[analysis].sh   # submit a dSQ job array
dsqa -j [JOB_ID]                                   # check status
```
```

- [ ] **Step 4: Verify**

Run: `grep -c -i 'jcodemunch' CLAUDE.md`

Expected: `0`.

Run: `grep -c 'rtk git\|rtk ls\|rtk grep\|## RTK Usage' CLAUDE.md`

Expected: `0`. Note: the Tooling pointer names RTK and graphify by design — the
check targets the duplicated `## RTK Usage` section and command table, not a
single naming reference.

Run: `wc -c CLAUDE.md`

Expected: roughly 4100 bytes. The original "under 3000" target was a bad
estimate: the four Karpathy principles are ~2270 bytes on their own and the
project sections ~1865. The file does not shrink — its content changes from a
duplicated RTK table to the coding principles.

Run: `grep -c 'Surgical Changes' CLAUDE.md`

Expected: `1` — all four Karpathy principles are present.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: rebase CLAUDE.md on Karpathy guidelines, drop tool duplication"
```

---

### Task 10: Rewrite `README.md`

**Files:**
- Modify: `README.md` (full replacement)

**Interfaces:**
- Consumes: the flag set from Task 2, the tool roster from Tasks 5–7.
- Produces: user-facing documentation. Nothing depends on it.

- [ ] **Step 1: Write the failing test**

Run: `grep -c -i 'jcodemunch' README.md`

Expected: a non-zero count — the current quick start is built around jCodemunch.

- [ ] **Step 2: Confirm the flag set to document**

Run: `bash setup_claude_tools.sh --help | head -20`

Expected: the usage block from the script header, listing `--check`, `--skip-all`, `--prefix`, and `--extra-dir`. The README table must match it.

- [ ] **Step 3: Write the implementation**

Replace the entire contents of `README.md`:

```markdown
# [PROJECT_NAME]

[Brief description of the project.]

## Quick Start

### 1. Clone and enter the project

```bash
git clone <repo-url>
cd [PROJECT_NAME]
```

### 2. Set up Claude Code tools

Run once per machine; safe to re-run.

```bash
bash setup_claude_tools.sh
```

Installs:

| Tool | Role |
|------|------|
| **graphify** | Semantic knowledge graph over code and docs — query structure instead of grepping |
| **caveman** | Output compression, roughly 65% fewer output tokens, plus the cavecrew subagents |
| **RTK** | Shell output compression through a `PreToolUse` hook |
| **superpowers** | Brainstorm → spec → plan → TDD workflow gates |

Also installs Claude Code, Node.js (required by caveman's hooks), and uv, when
they are missing.

The script probes what the machine can do rather than detecting a named
environment, so the same file works on macOS, a RunPod container, a non-root
Linux workstation, and an HPC login node.

| Flag | Effect |
|------|--------|
| `--check` | Print the environment probe table and tool status; change nothing |
| `--prefix PATH` | Install root (default: `$CLAUDE_TOOLS_PREFIX`, then a writable `/workspace`, then `$HOME`) |
| `--extra-dir PATH` | Repeatable; grants Claude access to another directory |
| `--non-interactive` | Never prompt |
| `--skip-all` | Skip every install step; performs only the persistence symlink |
| `--skip-claude`, `--skip-auth`, `--skip-node`, `--skip-plugins`, `--skip-rtk`, `--skip-uv`, `--skip-graphify`, `--skip-perms` | Skip one step |

Start with `bash setup_claude_tools.sh --check` to see what it would target.

On a container with an ephemeral home directory, the script keeps Claude's
config on the persistent volume and symlinks `~/.claude` to it. After a restart,
`bash setup_claude_tools.sh --skip-all` restores the link in under a second.

### 3. Create the Python environment

```bash
uv sync                    # creates .venv from pyproject.toml
source .venv/bin/activate  # or: uv run python script.py
```

### 4. Configure paths

`code/utils/config.py` detects `BASE_DIR` automatically. Override the rest with
environment variables when your data lives elsewhere:

- `DATASETS_DIR` — raw data
- `SCRATCH` or `TMPDIR` — intermediate files

### 5. Build the knowledge graph

```bash
graphify .
graphify install --project
```

Claude then answers structural questions from the graph instead of reading files.

## Not installed, by design

- **codebase-memory-mcp** — overlaps graphify. Both build a per-repo code graph
  needing its own re-index; graphify also covers documents and concepts.
- **context-mode** — collides with RTK. Both register `PreToolUse` on `Bash`,
  competing to rewrite or deny the same call, and context-mode denies
  `curl`/`wget` outright.
- **jCodemunch-MCP** — superseded by graphify.

`setup_claude_tools.sh` reports these when it finds them but never removes
anything.
```

- [ ] **Step 4: Verify**

Run: `grep -c -i 'jcodemunch' README.md`

Expected: `1` — the single mention in the "Not installed, by design" section.

Run: `grep -c -- '--check' README.md`

Expected: at least `2`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README around the four-tool roster"
```

---

### Task 11: End-to-end verification

**Files:**
- Modify: none unless a defect is found.

**Interfaces:**
- Consumes: everything.
- Produces: evidence that the spec's acceptance criteria hold.

- [ ] **Step 1: Syntax and unit tests**

```bash
bash -n setup_claude_tools.sh
bash tests/test_setup_claude_tools.sh
```

Expected: `bash -n` silent, exit 0. The harness prints `failed: 0`.

- [ ] **Step 2: Probe report**

```bash
bash setup_claude_tools.sh --check
```

Expected on macOS: `OS_ARCH darwin-arm64`, `IS_ROOT false`, `PKG brew`,
`PERSIST_ROOT` equal to `$HOME`, `EPHEMERAL_HOME false`. The roster check warns
about `context-mode`. Nothing is written.

- [ ] **Step 3: Full run**

```bash
bash setup_claude_tools.sh --non-interactive
```

Expected: every step reports `✓` or an explained `⚠`; exit 0.

- [ ] **Step 4: Idempotency**

```bash
cp ~/.claude/CLAUDE.md /tmp/claude-md-run1
bash setup_claude_tools.sh --non-interactive
diff /tmp/claude-md-run1 ~/.claude/CLAUDE.md && echo "IDENTICAL"
jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length' ~/.claude/settings.json
grep -c 'claude-tools:start' ~/.claude/CLAUDE.md
```

Expected: `IDENTICAL`; the hook count is `1`; the marker count is `1`.

- [ ] **Step 5: Tool availability**

```bash
rtk --version
graphify --version
claude plugin list | grep -E 'caveman|superpowers'
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
  | bash ~/.claude/hooks/rtk-rewrite.sh \
  | jq -r '.hookSpecificOutput.updatedInput.command'
```

Expected: versions print; both plugins are listed; the final command prints an
absolute path followed by `git status`.

- [ ] **Step 6: Documentation checks**

```bash
wc -c CLAUDE.md
grep -c -E 'RTK|jCodemunch' CLAUDE.md
```

Expected: under 3000 bytes; `0` matches.

- [ ] **Step 7: Commit any fixes and finish**

```bash
git add -A
git commit -m "test: verify tooling refresh end to end"
```

If Steps 1–6 all pass with no changes needed, there is nothing to commit — say
so rather than creating an empty commit.

---

## Notes for the executor

- The RunPod path cannot be exercised from a local machine. Every
  container-specific action is gated on `EPHEMERAL_HOME`, `IS_ROOT`, or
  `CAN_LINK_USRLOCAL` — the same conditions that gate it in the script being
  replaced. Do not attempt to test it by faking `/workspace` at the real path.
- Tasks 5, 7, and 9 mutate global state on the developer's machine (plugins,
  `~/.claude`, uv tools). That is intended: this script's whole job is to
  configure the machine it runs on.
- If a step's installer fails because of a network problem, that is not a plan
  defect. Re-run the single step with the other `--skip-*` flags.
- Bash 3.2 quirk: under `set -u`, expanding an *empty* array with
  `"${ARR[@]}"` raises `unbound variable`. Every such expansion in this plan is
  already guarded behind a `[ ${#ARR[@]} -gt 0 ]` check. If the test harness
  itself trips on this, wrap the offending assertion in `set +u` / `set -u`
  rather than removing the guard from the script.
