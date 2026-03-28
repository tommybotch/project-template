#!/usr/bin/env bash
# =============================================================================
# setup_claude_tools.sh
# Sets up RTK and jCodemunch-MCP for efficient Claude Code usage.
# Safe to re-run: all steps are idempotent.
#
# Usage:
#   bash setup_claude_tools.sh [--skip-rtk] [--skip-mcp] [--skip-uv] [--skip-perms]
#
# Options:
#   --skip-rtk      Skip RTK installation
#   --skip-mcp      Skip jCodemunch-MCP setup
#   --skip-uv       Skip uv installation
#   --skip-perms    Skip .claude/settings.json generation
# =============================================================================

set -euo pipefail

# --- Parse flags ---
SKIP_RTK=false
SKIP_MCP=false
SKIP_UV=false
SKIP_PERMS=false
for arg in "$@"; do
    case $arg in
        --skip-rtk)   SKIP_RTK=true ;;
        --skip-mcp)   SKIP_MCP=true ;;
        --skip-uv)    SKIP_UV=true ;;
        --skip-perms) SKIP_PERMS=true ;;
    esac
done

echo ""
echo "============================================"
echo "  Claude Code Tool Setup"
echo "============================================"
echo ""

# =============================================================================
# 1. uv (Python package manager)
# =============================================================================
if [ "$SKIP_UV" = false ]; then
    echo "--- [1/3] uv ---"
    if command -v uv &>/dev/null; then
        echo "  uv already installed: $(uv --version)"
    else
        echo "  Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # Source the cargo/uv env if just installed
        export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
        if command -v uv &>/dev/null; then
            echo "  uv installed: $(uv --version)"
        else
            echo "  WARNING: uv installed but not in PATH. Add ~/.local/bin or ~/.cargo/bin to your PATH."
        fi
    fi

    # Verify uvx is available (comes with uv)
    if command -v uvx &>/dev/null; then
        echo "  uvx available: $(uvx --version 2>/dev/null || echo 'ok')"
    else
        echo "  NOTE: uvx not in PATH yet. Restart shell or run: source ~/.bashrc"
    fi
    echo ""
fi

# =============================================================================
# 2. RTK (Rust Token Killer)
# =============================================================================
if [ "$SKIP_RTK" = false ]; then
    echo "--- [2/3] RTK (Rust Token Killer) ---"
    if command -v rtk &>/dev/null; then
        echo "  RTK already installed: $(rtk --version 2>/dev/null || echo 'ok')"
    else
        echo "  Installing RTK..."
        curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
        export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
        if command -v rtk &>/dev/null; then
            echo "  RTK installed: $(rtk --version 2>/dev/null || echo 'ok')"
        else
            echo "  WARNING: RTK installed but not in PATH. Restart shell."
        fi
    fi

    # Add RTK instructions to global CLAUDE.md
    if command -v rtk &>/dev/null; then
        echo "  Adding RTK instructions to ~/.claude/CLAUDE.md..."
        rtk init --global 2>/dev/null && echo "  Done." || echo "  Already configured or rtk init failed."
    fi
    echo ""
fi

# =============================================================================
# 3. jCodemunch-MCP
# =============================================================================
if [ "$SKIP_MCP" = false ]; then
    echo "--- [3/3] jCodemunch-MCP ---"

    BIN_DIR="$HOME/bin"
    WRAPPER="$BIN_DIR/run_uvx.sh"
    CLAUDE_JSON="$HOME/.claude.json"
    MCP_SERVER_NAME="jcodemunch"

    # Install jcodemunch-mcp via uv if uvx is available
    if command -v uvx &>/dev/null; then
        echo "  Installing jcodemunch-mcp via uv..."
        uv pip install jcodemunch-mcp 2>/dev/null || echo "  (pip install skipped — use uvx for on-demand resolution)"
    else
        echo "  uvx not available, skipping package install. Install uv first."
    fi

    # Create ~/bin wrapper that finds uvx flexibly (works in GUI + terminal + conda)
    mkdir -p "$BIN_DIR"
    cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Flexible uvx launcher — works in any terminal, VS Code GUI, or conda environment.

# 1. Use uvx from current PATH
if command -v uvx &>/dev/null; then
    exec uvx "$@"
fi

# 2. Check conda environments
if command -v conda &>/dev/null; then
    for env in $(conda env list | awk '{print $1}' | grep -v '#'); do
        if conda run -n "$env" which uvx &>/dev/null 2>&1; then
            exec conda run -n "$env" uvx "$@"
        fi
    done
fi

# 3. Common install locations
for candidate in "$HOME/.cargo/bin/uvx" "$HOME/.local/bin/uvx" "/usr/local/bin/uvx" "/usr/bin/uvx"; do
    if [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done

echo "uvx not found. Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
exit 1
WRAPPER_EOF
    chmod +x "$WRAPPER"
    echo "  Created uvx wrapper at $WRAPPER"

    # Register MCP server in ~/.claude.json
    if command -v jq &>/dev/null; then
        if [ -f "$CLAUDE_JSON" ]; then
            jq --arg server "$MCP_SERVER_NAME" \
               --arg cmd "$WRAPPER" \
               --argjson args '["jcodemunch-mcp"]' \
               '.mcpServers[$server] = {command: $cmd, args: $args}' \
               "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        else
            jq -n --arg server "$MCP_SERVER_NAME" \
                  --arg cmd "$WRAPPER" \
                  --argjson args '["jcodemunch-mcp"]' \
                  '{mcpServers: {($server): {command: $cmd, args: $args}}}' \
                  > "$CLAUDE_JSON"
        fi
        echo "  Registered jcodemunch in $CLAUDE_JSON"
    else
        echo "  WARNING: jq not found. Manually add to ~/.claude.json:"
        echo '  { "mcpServers": { "jcodemunch": { "command": "'"$WRAPPER"'", "args": ["jcodemunch-mcp"] } } }'
    fi

    # Register via claude CLI if available
    if command -v claude &>/dev/null; then
        echo "  Registering MCP server with Claude CLI..."
        claude mcp add "$MCP_SERVER_NAME" "$WRAPPER" jcodemunch-mcp 2>/dev/null \
            && echo "  Registered via claude mcp add." \
            || echo "  (claude mcp add failed or already registered)"
    fi

    echo ""
    echo "  To verify: open Claude Code and run /mcp — jcodemunch should appear as connected."
    echo "  First use in a project: ask Claude 'Index this project'"
    echo ""
fi

# =============================================================================
# 4. Configure .claude/settings.json with user's actual paths
# =============================================================================
if [ "$SKIP_PERMS" = false ]; then
echo "--- [4/4] Claude Code project permissions ---"

CLAUDE_SETTINGS="$(cd "$(dirname "$0")" && pwd)/.claude/settings.json"
CLAUDE_SETTINGS_DIR="$(dirname "$CLAUDE_SETTINGS")"
mkdir -p "$CLAUDE_SETTINGS_DIR"

# Prompt for optional extra directories (e.g. shared lab data)
echo "  Current user home: $HOME"
echo ""
echo "  Enter any additional directories Claude should be able to read"
echo "  (e.g. shared lab data, utils repos). One per line. Empty line to finish."
EXTRA_DIRS=()
while IFS= read -r -p "  Extra dir (or Enter to skip): " extra_dir; do
    [[ -z "$extra_dir" ]] && break
    EXTRA_DIRS+=("$extra_dir")
done

# Build the allow array using jq
ALLOW_ENTRIES=$(jq -n \
    --arg home "$HOME" \
    --argjson extra "$(printf '%s\n' "${EXTRA_DIRS[@]:-}" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    '["Read(**)", ("Read(\($home)/**)")] + ($extra | map("Read(\(.)/**)"))')

jq -n --argjson allow "$ALLOW_ENTRIES" \
    '{permissions: {allow: $allow, additionalDirectories: []}}' \
    > "$CLAUDE_SETTINGS"

echo "  Written: $CLAUDE_SETTINGS"
if [ ${#EXTRA_DIRS[@]} -gt 0 ]; then
    echo "  Included extra dirs: ${EXTRA_DIRS[*]}"
fi
echo ""

fi  # end SKIP_PERMS

# =============================================================================
# Summary
# =============================================================================
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Tools status:"
command -v uv  &>/dev/null && echo "  ✓ uv  $(uv --version)"       || echo "  ✗ uv  (not in PATH)"
command -v uvx &>/dev/null && echo "  ✓ uvx available"              || echo "  ✗ uvx (not in PATH — restart shell)"
command -v rtk &>/dev/null && echo "  ✓ rtk $(rtk --version 2>/dev/null || echo '')" || echo "  ✗ rtk (not in PATH — restart shell)"
echo ""
echo "  Next steps:"
echo "  1. Restart your shell (or: source ~/.bashrc / source ~/.bash_profile)"
echo "  2. Open Claude Code in a project and run /mcp to confirm jcodemunch"
echo "  3. Run 'rtk gain' to verify RTK is working"
echo ""
