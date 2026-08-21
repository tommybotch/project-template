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
#   CUSTOM_PREFIX    true when PERSIST_ROOT != $HOME: tools install somewhere
#                    no default PATH covers (RunPod's /workspace fallback, or
#                    an explicit --prefix/CLAUDE_TOOLS_PREFIX — the HPC quota
#                    case). Enables the persisted-env file and its .bashrc
#                    source line, so a future shell finds $BIN_DIR on PATH.
#   EPHEMERAL_HOME   true when $HOME itself will NOT survive a restart: the
#                    writable-/workspace fallback (RunPod), or an explicit
#                    --ephemeral-home override. NOT the same thing as a custom
#                    install prefix — CLAUDE_TOOLS_PREFIX/--prefix (the HPC
#                    quota case) sets CUSTOM_PREFIX but not this; $HOME still
#                    persists there. Enables the ~/.claude symlink and the
#                    auth prompt.
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
#   bash setup_claude_tools.sh --ephemeral-home   # force the ephemeral-HOME
#                                                  # behaviors even without a
#                                                  # workspace fallback
#
# Requires bash 3.2 or newer (macOS ships 3.2).
# =============================================================================

set -euo pipefail

# ── output helpers ────────────────────────────────────────────────────────────
step() { echo ""; echo "━━━ $* ━━━"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
info() { echo "  · $*"; }

# ── testability seams ─────────────────────────────────────────────────────────
# Overridable so the test harness never touches real system paths.
WORKSPACE_CANDIDATE="${WORKSPACE_CANDIDATE:-/workspace}"
USRLOCAL_BIN="${USRLOCAL_BIN:-/usr/local/bin}"

# ── probes ────────────────────────────────────────────────────────────────────

# Prints a platform slug. Diagnostic only — it appears in the --check report so
# a bug report says which platform ran. No install step branches on it: rtk and
# uv both detect their own platform inside their installers.
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

    # CUSTOM_PREFIX is true whenever tools install somewhere no default PATH
    # covers (PERSIST_ROOT != $HOME) — true for both the writable-/workspace
    # fallback (RunPod) and an explicit --prefix (HPC). It governs PATH
    # persistence (ensure_persist_env): whenever the install root differs
    # from $HOME, something has to put $BIN_DIR on PATH for future shells,
    # regardless of whether $HOME itself survives a restart.
    if [ "$PERSIST_ROOT" != "$HOME" ]; then
        CUSTOM_PREFIX=true
    else
        CUSTOM_PREFIX=false
    fi

    # EPHEMERAL_HOME governs the ~/.claude symlink migration and the auth
    # prompt — both of which only matter when $HOME ITSELF will be wiped on
    # restart. That is true for the writable-/workspace fallback (RunPod-
    # style root), and for nothing else, unless the user overrides with
    # --ephemeral-home. A custom install prefix (CLAUDE_TOOLS_PREFIX /
    # --prefix — the HPC quota case) deliberately does NOT set this: it only
    # relocates PERSIST_ROOT (see CUSTOM_PREFIX above), and $HOME persists
    # there, so migrating ~/.claude and prompting for an OAuth token would be
    # wrong.
    if [ "${EPHEMERAL_HOME_FLAG:-false}" = true ]; then
        EPHEMERAL_HOME=true
    elif [ -z "${PREFIX_ARG:-}" ] && [ -z "${CLAUDE_TOOLS_PREFIX:-}" ] \
        && [ -d "$WORKSPACE_CANDIDATE" ] && [ -w "$WORKSPACE_CANDIDATE" ]; then
        EPHEMERAL_HOME=true
    else
        EPHEMERAL_HOME=false
    fi

    if [ -w "$USRLOCAL_BIN" ] || [ "$IS_ROOT" = true ]; then
        CAN_LINK_USRLOCAL=true
    else
        CAN_LINK_USRLOCAL=false
    fi

    BIN_DIR="$PERSIST_ROOT/.local/bin"
    CLAUDE_DIR="$PERSIST_ROOT/.claude"
    UV_TOOL_DIR="$PERSIST_ROOT/.local/share/uv/tools"
    UV_TOOL_BIN_DIR="$BIN_DIR"
    SETTINGS="$CLAUDE_DIR/settings.json"
    PERSIST_ENV="$CLAUDE_DIR/env"

    # Exported for the installers themselves to read — uv places its tools by
    # these, so they must be set before step_uv / step_graphify run.
    export UV_TOOL_DIR UV_TOOL_BIN_DIR
    export PATH="$BIN_DIR:$PATH"
}

# ── argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    SKIP_CLAUDE=false;  SKIP_AUTH=false;     SKIP_NODE=false
    SKIP_PLUGINS=false; SKIP_RTK=false;      SKIP_UV=false
    SKIP_GRAPHIFY=false; SKIP_PERMS=false
    SKIP_EVERYTHING=false
    CHECK_ONLY=false
    NON_INTERACTIVE=false
    PREFIX_ARG=""
    EPHEMERAL_HOME_FLAG=false
    EXTRA_DIRS=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --check)           CHECK_ONLY=true ;;
            --non-interactive) NON_INTERACTIVE=true ;;
            --ephemeral-home)  EPHEMERAL_HOME_FLAG=true ;;
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
    echo "  CUSTOM_PREFIX      $CUSTOM_PREFIX"
    echo "  CAN_LINK_USRLOCAL  $CAN_LINK_USRLOCAL"
    echo "  BIN_DIR            $BIN_DIR"
    echo "  CLAUDE_DIR         $CLAUDE_DIR"
    echo "  SETTINGS           $SETTINGS"
}

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
            apt-get update -qq || true
            apt-get install -y "$pkg" || true
            ;;
        brew)
            brew install "$pkg" || true
            ;;
        none)
            warn "cannot install '$pkg': no usable package manager (need root+apt, or brew)"
            return 1
            ;;
    esac
    if ! command -v "$pkg" >/dev/null 2>&1; then
        warn "failed to install '$pkg'"
        return 1
    fi
}

# merge_settings [jq-args...] EXPR — apply a jq expression to $SETTINGS,
# creating the file when it does not exist yet.
#
# When jq is unavailable, per the design spec ("steps that edit settings.json
# print the JSON to add by hand instead of failing"), callers may set
# MERGE_SETTINGS_HINT to a human-readable JSON fragment before calling; it is
# printed so the user has something to paste by hand instead of a bare
# "skipping" warning.
merge_settings() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq unavailable — cannot update $SETTINGS automatically"
        if [ -n "${MERGE_SETTINGS_HINT:-}" ]; then
            info "add this to $SETTINGS by hand:"
            printf '%s\n' "$MERGE_SETTINGS_HINT" | sed 's/^/      /'
        fi
        return 1
    fi
    mkdir -p "$(dirname "$SETTINGS")"
    local tmp
    tmp=$(mktemp) || { warn "failed to create a temp file — leaving $SETTINGS unchanged"; return 1; }
    if [ -s "$SETTINGS" ]; then
        if jq "$@" "$SETTINGS" > "$tmp"; then
            mv "$tmp" "$SETTINGS"
        else
            warn "failed to update $SETTINGS"
            rm -f "$tmp"
            return 1
        fi
    else
        if jq -n "$@" > "$tmp"; then
            mv "$tmp" "$SETTINGS"
        else
            warn "failed to create $SETTINGS"
            rm -f "$tmp"
            return 1
        fi
    fi
}

# write_marker_block FILE START END CONTENT
# Replaces whatever sits between START and END (inclusive) with CONTENT.
# Appends the block when the markers are absent. Idempotent: running twice with
# the same CONTENT leaves the file byte-identical.
#
# Must always be called under a conditional (`if write_marker_block ...; then`
# / `... || warn ...`), never bare. Its no-abort/no-leak behavior — returning
# non-zero and cleaning up its own temp file on failure instead of aborting
# the script — is only useful if the caller actually checks the exit status.
write_marker_block() {
    local file="$1" start="$2" end="$3" content="$4"
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || : > "$file"

    local tmp
    tmp=$(mktemp) || return 1

    # One pass handles every case. Lines before START are preamble, lines after
    # END are postamble, and the block between them is replaced. When the file
    # has no markers at all, every line is preamble and the block is appended —
    # which is why there is no separate "append" branch. When START appears with
    # no matching END, the lines after it are re-emitted below the new block so
    # nothing the user wrote is lost.
    #
    # CONTENT is multi-line. Passing it via `awk -v c="$content"` breaks on
    # macOS's /usr/bin/awk (the "one true awk"), which errors with "newline in
    # string" on any -v value containing a raw newline. A temp-file + getline
    # workaround was tried and rejected: an unchecked write to that temp file can
    # silently fail (permission denied, ENOSPC mid-write) and getline cannot tell
    # "empty on purpose" from "write failed" — the block would be replaced with
    # empty content while the script still reported success. ENVIRON is POSIX and
    # handles embedded newlines identically on BSD and GNU awk. s/e stay -v since
    # they are always single-line marker strings.
    #
    # $file is never truncated until the replacement is known-good: awk writes to
    # $tmp and only a successful run reaches the mv.
    if CONTENT="$content" awk -v s="$start" -v e="$end" '
        BEGIN {
            state = "before"
            plen = 0
            alen = 0
            ilen = 0
            c = ENVIRON["CONTENT"]
        }
        $0 == s { state = "inside"; next }
        $0 == e { state = "after"; ilen = 0; next }
        state == "before" { preamble[plen++] = $0; next }
        state == "inside" { inside[ilen++]   = $0; next }
        state == "after"  { postamble[alen++] = $0; next }
        END {
            while (plen > 0 && preamble[plen-1] == "") plen--
            for (i = 0; i < plen; i++) print preamble[i]

            print ""
            print s
            print c
            print e

            # ilen > 0 only when START had no matching END. Those lines belong
            # to the user, so re-emit them below the block rather than drop them.
            for (i = 0; i < ilen; i++) print inside[i]
            for (i = 0; i < alen; i++) print postamble[i]
        }
    ' "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ── persistence ───────────────────────────────────────────────────────────────
# Only meaningful when HOME is ephemeral (RunPod: /root is wiped on restart).
# Creates $CLAUDE_DIR on the persistent volume and points ~/.claude at it.
ensure_persistence() {
    [ "$EPHEMERAL_HOME" = true ] || return 0
    [ "$CHECK_ONLY" = true ] && return 0

    step "Persistence"
    if ! mkdir -p "$CLAUDE_DIR" 2>/dev/null; then
        warn "failed to create $CLAUDE_DIR"
        return 1
    fi

    # First run: migrate a real ~/.claude onto the volume.
    if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; then
        if cp -rn "$HOME/.claude/." "$CLAUDE_DIR/" 2>/dev/null; then
            mv "$HOME/.claude" "$HOME/.claude.premigration.bak"
            ok "migrated ~/.claude to $CLAUDE_DIR"
        else
            warn "failed to migrate ~/.claude — leaving it in place"
            return 1
        fi
    fi

    [ -e "$HOME/.claude" ] || ln -s "$CLAUDE_DIR" "$HOME/.claude"
    export CLAUDE_CONFIG_DIR="$CLAUDE_DIR"
    ok "~/.claude -> $CLAUDE_DIR"
}

# Writes PATH / UV_TOOL_* pins to $PERSIST_ENV — a file under $CLAUDE_DIR,
# which lives on $PERSIST_ROOT and therefore survives a restart even though
# $HOME may not. Then makes sure $HOME/.bashrc sources it.
#
# Gated on CUSTOM_PREFIX (PERSIST_ROOT != $HOME), NOT on EPHEMERAL_HOME:
# whenever tools install outside $HOME, $BIN_DIR is on no default PATH and
# something has to fix that for future shells, regardless of whether $HOME
# itself survives a restart. That covers two distinct shapes:
#   - RunPod (EPHEMERAL_HOME=true): $HOME is wiped on restart, so ~/.bashrc
#     resets too and this sourcing line does NOT survive — that is expected.
#     `--skip-all` (the documented post-restart command) re-adds this same
#     line to the fresh .bashrc via the same guarded write_marker_block call
#     below, so one command makes the persisted exports (and the auth token,
#     written here by step_auth) live again.
#   - HPC (EPHEMERAL_HOME=false, --prefix set): $HOME persists across
#     restarts, so ~/.bashrc persists too — the sourcing line written here
#     survives on its own; no ~/.claude symlink or auth prompt is needed
#     because $HOME/.claude was never relocated.
# Runs unconditionally in main, before any --skip-* flag is consulted, so
# `--skip-all` still restores it.
ensure_persist_env() {
    [ "$CUSTOM_PREFIX" = true ] || return 0
    [ "$CHECK_ONLY" = true ] && return 0

    local env_content
    env_content=$(cat <<ENVBLOCK
export PATH="$BIN_DIR:\$PATH"
export UV_TOOL_DIR="$UV_TOOL_DIR"
export UV_TOOL_BIN_DIR="$UV_TOOL_BIN_DIR"
ENVBLOCK
)
    if write_marker_block "$PERSIST_ENV" \
        "# claude-tools-env:start" "# claude-tools-env:end" "$env_content"; then
        ok "PATH / UV_TOOL_* pinned in $PERSIST_ENV"
    else
        warn "failed to write $PERSIST_ENV"
        return 1
    fi

    local source_line
    source_line="[ -f \"$PERSIST_ENV\" ] && . \"$PERSIST_ENV\""
    if write_marker_block "$HOME/.bashrc" \
        "# claude-tools-source:start" "# claude-tools-source:end" "$source_line"; then
        ok "~/.bashrc sources $PERSIST_ENV"
    else
        warn "failed to update ~/.bashrc to source $PERSIST_ENV"
        return 1
    fi
}

# link_into_usrlocal SRC NAME — put NAME on every shell's PATH by symlinking
# SRC into $USRLOCAL_BIN. No-ops silently when we may not write there or when
# SRC is not installed, so callers do not each repeat those two checks.
link_into_usrlocal() {
    local src="$1" name="$2"
    [ "$CAN_LINK_USRLOCAL" = true ] || return 0
    [ -x "$src" ] || return 0
    ln -sf "$src" "$USRLOCAL_BIN/$name" 2>/dev/null \
        && ok "$name symlinked into $USRLOCAL_BIN" \
        || warn "could not symlink $name into $USRLOCAL_BIN"
    return 0
}

# Re-creates the /usr/local/bin symlinks for tools that are already installed.
# Idempotent and network-free — safe to run on every invocation, including
# `--skip-all`, where it is what restores `rtk` / `graphify` onto PATH after a
# restart wipes /usr/local/bin (RunPod) without re-installing anything.
#
# The install steps also link their own tool, because on a first run the binary
# does not exist yet when this runs.
restore_symlinks() {
    [ "$CHECK_ONLY" = true ] && return 0
    link_into_usrlocal "$BIN_DIR/rtk" rtk
    link_into_usrlocal "$UV_TOOL_BIN_DIR/graphify" graphify
    return 0
}

# ── 0. prerequisites ──────────────────────────────────────────────────────────
step_prereqs() {
    [ "$SKIP_EVERYTHING" = true ] && return 0
    step "0/9  Prerequisites"
    if ! mkdir -p "$BIN_DIR" "$CLAUDE_DIR" 2>/dev/null; then
        warn "failed to create directories"
        return 1
    fi
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
    step "1/9  Claude Code"
    if command -v claude >/dev/null 2>&1; then
        ok "already installed: $(claude --version 2>/dev/null)"
        return 0
    fi
    info "installing via the native installer..."
    if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
        export PATH="$BIN_DIR:$HOME/.local/bin:$HOME/.claude/bin:$PATH"
        if command -v claude >/dev/null 2>&1; then
            ok "installed: $(claude --version 2>/dev/null)"
        else
            warn "not in PATH yet — restart your shell"
        fi
    else
        warn "failed to install Claude Code"
    fi
}

# ── 2. auth ───────────────────────────────────────────────────────────────────
# Only prompts where a token is actually needed: an ephemeral home whose OAuth
# state does not survive. A local machine has already completed OAuth.
step_auth() {
    [ "$SKIP_AUTH" = true ] && return 0
    [ "$EPHEMERAL_HOME" = true ] || return 0

    step "2/9  Auth"
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
    if read -rs token 2>/dev/null; then
        echo ""
        if [ -n "$token" ]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$token"
            # Persisted to $PERSIST_ENV, not directly to ~/.bashrc: .bashrc
            # lives in the same ephemeral $HOME that is about to be wiped, so
            # a direct write there would be lost on the very next restart.
            # $PERSIST_ENV lives on $PERSIST_ROOT and survives; ensure_persist_env
            # (run unconditionally in main, including under --skip-all) is what
            # makes ~/.bashrc source it again after a restart.
            if write_marker_block "$PERSIST_ENV" \
                "# claude-tools-token:start" "# claude-tools-token:end" \
                "export CLAUDE_CODE_OAUTH_TOKEN=$(printf '%q' "$token")"; then
                ok "saved to $PERSIST_ENV"
            else
                warn "token not persisted — add it to your shell profile by hand"
            fi
        else
            warn "skipped"
        fi
    else
        echo ""
        warn "skipped"
    fi
}

# ── 3. Node.js ────────────────────────────────────────────────────────────────
# Required at runtime by caveman's hooks.
step_node() {
    [ "$SKIP_NODE" = true ] && return 0
    step "3/9  Node.js"
    if command -v node >/dev/null 2>&1; then
        ok "already installed: $(node --version)"
        return 0
    fi
    # Installers run unguarded-but-tolerated (`|| true`) and the single
    # `command -v` below decides success. Checking each installer's own exit
    # status as well would add nesting without adding information: if the
    # install failed, node is missing, and that is what the user needs told.
    case "$PKG" in
        apt)
            info "installing Node.js 22 LTS via NodeSource..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || true
            apt-get install -y nodejs -qq >/dev/null 2>&1 || true
            ;;
        brew)
            brew install node >/dev/null 2>&1 || true
            ;;
        none)
            warn "node missing and no package manager — caveman hooks will not run"
            return 0
            ;;
    esac

    if command -v node >/dev/null 2>&1; then
        ok "installed: $(node --version)"
    else
        warn "failed to install node"
    fi
}

# ── 4. plugins ────────────────────────────────────────────────────────────────
# caveman      output compression + cavecrew subagents
# superpowers  brainstorm -> spec -> plan -> TDD workflow gates
#
# Installed through `claude plugin install` only. The standalone caveman
# installer is intentionally not used: it duplicates the plugin, creates a
# second update path, and can double-register hooks.
step_plugins() {
    [ "$SKIP_PLUGINS" = true ] && return 0
    step "4/9  Plugins"

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
# ── 5. RTK (Rust Token Killer) ────────────────────────────────────────────────
step_rtk() {
    [ "$SKIP_RTK" = true ] && return 0
    step "5/9  RTK"

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
        if ! mkdir -p "$RTK_INSTALL_DIR" 2>/dev/null; then
            warn "failed to create $RTK_INSTALL_DIR"
            return 0
        fi
        if curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh >/dev/null 2>&1; then
            export PATH="$BIN_DIR:$PATH"
            if command -v rtk >/dev/null 2>&1; then
                ok "installed: $(rtk --version 2>/dev/null)"
            else
                warn "not in PATH — restart your shell"
                return 0
            fi
        else
            warn "failed to install RTK"
            return 0
        fi
    fi

    # Make bare `rtk` resolve in every shell where we are allowed to.
    link_into_usrlocal "$BIN_DIR/rtk" rtk

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
    # a wrapper that substitutes the absolute binary path. Fails open. If any
    # step below fails, no half-written wrapper is left behind and the
    # settings patch further down never runs against a hook that doesn't exist.
    if ! mkdir -p "$hooks_dir" 2>/dev/null; then
        warn "failed to create $hooks_dir — RTK hook not installed"
        return 0
    fi
    if ! cat > "$rtk_hook" << HOOK
#!/usr/bin/env bash
# RTK PreToolUse hook — runs Bash commands through rtk via an ABSOLUTE path.
# PATH-independent: never depends on \`rtk\` being on PATH.
RTK="${rtk_bin}"
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
    then
        warn "failed to write $rtk_hook — RTK hook not installed"
        rm -f "$rtk_hook"
        return 0
    fi
    chmod +x "$rtk_hook" 2>/dev/null \
        || warn "could not make $rtk_hook executable — invoked via 'bash', so this is non-fatal"

    # Point the Bash PreToolUse hook at the wrapper, then dedupe Bash entries so
    # re-runs cannot stack duplicates. unique_by(.hooks[0].command) assumes each
    # matcher group has at least one hook; a group with an empty .hooks array
    # would make that key null and collapse into a single group too — inert
    # here since every Bash entry this script writes always carries exactly
    # one hook, but worth knowing if that ever changes.
    # Only patch an existing settings file. If rtk init never produced one there
    # is no hook config to dedupe, and creating one from this expression alone
    # would write a settings file containing nothing else.
    if [ -s "$SETTINGS" ]; then
        MERGE_SETTINGS_HINT="{ \"matcher\": \"Bash\", \"hooks\": [ { \"type\": \"command\", \"command\": \"bash $rtk_hook\" } ] }
(and remove any other Bash-matcher entries so only one remains)"
        merge_settings --arg script "bash $rtk_hook" '
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
        ' || true
        unset MERGE_SETTINGS_HINT
    fi

    # Self-test: the wrapper must emit an absolute-path rewrite. Requires jq
    # to parse the wrapper's own JSON output — check for it explicitly so a
    # missing jq is reported as a missing dependency, not misattributed to
    # the wrapper failing to rewrite.
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq unavailable — cannot verify the rtk hook rewrite (hook is installed; it fails open if broken)"
    else
        local test_out
        test_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
            | bash "$rtk_hook" 2>/dev/null)
        if printf '%s' "$test_out" \
            | jq -e ".hookSpecificOutput.updatedInput.command | startswith(\"$rtk_bin \")" >/dev/null 2>&1; then
            ok "hook verified: $rtk_hook"
        else
            warn "wrapper produced no rewrite — Bash runs un-proxied (fail-open)"
        fi
    fi
}
# ── 6. uv ─────────────────────────────────────────────────────────────────────
step_uv() {
    [ "$SKIP_UV" = true ] && return 0
    step "6/9  uv"
    if command -v uv >/dev/null 2>&1; then
        ok "already installed: $(uv --version)"
        return 0
    fi
    if ! curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="$BIN_DIR" sh >/dev/null 2>&1; then
        warn "failed to install uv"
        return 0
    fi
    export PATH="$BIN_DIR:$PATH"
    if command -v uv >/dev/null 2>&1; then
        ok "installed: $(uv --version)"
    else
        warn "not in PATH — restart your shell"
    fi
    return 0
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
    step "7/9  graphify"

    if ! command -v uv >/dev/null 2>&1; then
        warn "uv not in PATH — skipping (run without --skip-uv first)"
        return 0
    fi

    if ! mkdir -p "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR" 2>/dev/null; then
        warn "failed to create $UV_TOOL_DIR — skipping"
        return 0
    fi

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

    link_into_usrlocal "$UV_TOOL_BIN_DIR/graphify" graphify

    # UV_TOOL_DIR / UV_TOOL_BIN_DIR are pinned by ensure_persist_env (run
    # unconditionally in main whenever CUSTOM_PREFIX is true, i.e. tools
    # install outside $HOME), which writes them to $PERSIST_ENV rather than
    # directly to ~/.bashrc — see that function's comment for why a direct
    # .bashrc write does not survive a restart on the ephemeral-$HOME shape.

    if command -v graphify >/dev/null 2>&1; then
        graphify install --platform claude >/dev/null 2>&1 \
            && ok "Claude Code skill registered" \
            || warn "skill registration failed — run: graphify install --platform claude"
    fi

    info "per repo: cd <repo> && graphify . && graphify install --project"
    return 0
}
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
    step "8/9  Global routing block"
    if write_marker_block "$CLAUDE_DIR/CLAUDE.md" \
        "$ROUTING_START" "$ROUTING_END" "$(routing_block_content)"; then
        ok "written to $CLAUDE_DIR/CLAUDE.md"
    else
        warn "failed to update $CLAUDE_DIR/CLAUDE.md"
    fi
    return 0
}

# ── 9. permissions ────────────────────────────────────────────────────────────
# Edits the USER-level settings only. The repository's committed
# .claude/settings.json is never touched.
#
# Extra directories go to permissions.additionalDirectories, which actually
# grants access (unlike the old Read($dir/**) entries, which Read(**) already
# subsumed and so granted nothing). Empty strings — reachable when a trailing
# --extra-dir is given with no value — are filtered out before writing.
apply_permissions() {
    local extra_json="[]"
    if [ "${#EXTRA_DIRS[@]}" -gt 0 ]; then
        if command -v jq >/dev/null 2>&1; then
            if ! extra_json=$(printf '%s\n' "${EXTRA_DIRS[@]}" \
                | jq -R -s '[splits("\n") | select(length > 0)]' 2>/dev/null); then
                warn "failed to build extra directories list — additionalDirectories left unchanged"
                extra_json="[]"
            fi
        else
            # Without jq nothing here can safely quote a path for JSON, and
            # hand-rolled escaping would hand the user invalid JSON to paste for
            # any path containing a quote or backslash. Still name the paths —
            # they are what the user needs — but flag that quoting is on them.
            extra_json="[ $(printf '%s, ' "${EXTRA_DIRS[@]}" | sed 's/, $//') ]   <-- JSON-quote each path"
        fi
    fi
    MERGE_SETTINGS_HINT=$(cat <<HINT
{
  "permissions": {
    "allow": ["Read(**)", "... (keep existing entries)"],
    "additionalDirectories": $extra_json
  }
}
HINT
) merge_settings --argjson extra "$extra_json" '
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
        if [ "${#EXTRA_DIRS[@]}" -gt 0 ]; then
            info "extra directories: ${EXTRA_DIRS[*]}"
        fi
    else
        warn "could not update $SETTINGS"
    fi
    return 0
}

# ── summary ───────────────────────────────────────────────────────────────────
print_summary() {
    [ "$SKIP_EVERYTHING" = true ] && return 0
    echo ""
    echo "  ══════════════════════════"
    echo "  Done"
    echo "  ══════════════════════════"
    echo ""
    local tool
    for tool in claude node rtk uv graphify; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '  ✓ %-9s%s\n' "$tool" "$("$tool" --version 2>/dev/null | head -1)"
        else
            printf '  ✗ %s\n' "$tool"
        fi
    done
    echo ""
    echo "  Next:"
    echo "  1. restart your shell"
    echo "  2. cd your-project && claude"
    echo "  3. /plugins  → verify caveman and superpowers"
    echo "  4. graphify . && graphify cluster-only . && graphify install --project"
    echo ""
    return 0
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    run_probes
    print_probe_report

    if [ "$CHECK_ONLY" = true ]; then
        echo ""
        info "--check: no changes made"
        return 0
    fi

    ensure_persistence || warn "persistence setup failed — continuing without it"
    ensure_persist_env || warn "persistent env setup failed — continuing without it"
    restore_symlinks || warn "symlink restore failed — continuing without it"

    step_prereqs || warn "prerequisites setup failed — continuing without it"
    step_claude
    step_auth
    step_node
    step_plugins
    step_rtk
    step_uv
    step_graphify
    step_routing
    step_perms
    print_summary
}

# Sourcing with SETUP_CLAUDE_TOOLS_LIB=1 defines the functions above without
# running anything — this is what makes the pure logic unit-testable.
if [ "${SETUP_CLAUDE_TOOLS_LIB:-0}" != "1" ]; then
    main "$@"
fi
