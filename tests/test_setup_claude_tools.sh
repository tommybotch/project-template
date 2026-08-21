#!/usr/bin/env bash
# Test harness for setup_claude_tools.sh — plain bash, no framework.
# Run: bash tests/test_setup_claude_tools.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0

# Some assertions can only run when a real tool is installed. Counting them
# keeps the summary honest: without this, a skipped block just makes the pass
# total quietly smaller and nobody can tell an assertion never ran.
skip() {
    echo "  skip $1"
    SKIP=$((SKIP + 1))
}

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

# setup_claude_tools.sh sets `set -euo pipefail` at its own top, and sourcing
# it (rather than running it as a subprocess) leaves that in effect in THIS
# shell from here on. Turn errexit back off immediately: this harness calls
# library functions bare (not inside `if`/`||`) throughout to assert on their
# exit status, and under errexit a single bare non-zero return would abort
# the whole suite silently instead of registering as a FAIL.
set +e

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

echo "merge_settings (error handling)"
TMPROOT=$(mktemp -d)
SETTINGS="$TMPROOT/settings.json"

# Create a malformed JSON file
echo '{ "broken json"' > "$SETTINGS"
ORIGINAL=$(cat "$SETTINGS")

# Try to merge - should fail and return non-zero
if merge_settings '.model = "opus"' >/dev/null 2>&1; then
    echo "  FAIL merge_settings should fail on malformed JSON"; FAIL=$((FAIL + 1))
else
    echo "  ok   merge_settings fails on malformed JSON"; PASS=$((PASS + 1))
fi

# Check that the original file is unchanged
CURRENT=$(cat "$SETTINGS")
assert_eq "$ORIGINAL" "$CURRENT" "original file untouched after failed merge"

echo "write_marker_block (preamble and postamble preservation)"
MD="$TMPROOT/CLAUDE.md"
START='<!-- claude-tools:start -->'
END='<!-- claude-tools:end -->'

# Create a file with preamble, markers, and postamble already present
{
    echo "preamble line"
    echo "$START"
    echo "old body"
    echo "$END"
    echo "postamble line"
} > "$MD"

write_marker_block "$MD" "$START" "$END" "new body"

# Check that preamble is still the first line
FIRST_LINE=$(head -n 1 "$MD")
assert_eq "preamble line" "$FIRST_LINE" "preamble still before START"

# Check that postamble is still the last line
LAST_LINE=$(tail -n 1 "$MD")
assert_eq "postamble line" "$LAST_LINE" "postamble still after END"

# Verify the content was actually updated
assert_eq "1" "$(grep -c 'new body' "$MD")" "new body inserted"
assert_eq "0" "$(grep -c 'old body' "$MD")" "old body removed"

echo "write_marker_block (idempotency - three runs)"
MD2="$TMPROOT/CLAUDE2.md"
printf 'existing content\n' > "$MD2"

# First run
write_marker_block "$MD2" "$START" "$END" "stable content"
SNAP1=$(cat "$MD2")

# Second run with same content
write_marker_block "$MD2" "$START" "$END" "stable content"
SNAP2=$(cat "$MD2")

# Third run with same content
write_marker_block "$MD2" "$START" "$END" "stable content"
SNAP3=$(cat "$MD2")

assert_eq "$SNAP1" "$SNAP2" "second run byte-identical to first"
assert_eq "$SNAP2" "$SNAP3" "third run byte-identical to second"

echo "merge_settings (temp file cleanup on malformed JSON)"
TMPROOT=$(mktemp -d)
SETTINGS="$TMPROOT/settings.json"
TMPDIR="$TMPROOT/tmp"
export TMPDIR
mkdir -p "$TMPDIR"

# Create a malformed JSON file
echo '{ "broken json"' > "$SETTINGS"

# Call merge_settings - should fail
merge_settings '.model = "opus"' >/dev/null 2>&1 || true

# Check that TMPDIR has no leftover tmp files - count files directly
TMPFILES_COUNT=$(find "$TMPDIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$TMPFILES_COUNT" "merge_settings cleaned up temp file on JSON error"

# Restore TMPDIR
unset TMPDIR

echo "merge_settings / apply_permissions / step_rtk (jq unavailable prints a hand-mergeable fragment)"
# Build a PATH that genuinely has no jq on it, without losing any other tool
# the script needs (mkdir, mv, sed, grep, ...). Excluding whole directories
# is not safe here: on this machine /usr/bin carries both a system jq AND
# core utilities the script relies on, so dropping /usr/bin wholesale breaks
# things unrelated to jq. Instead, populate one directory with a symlink for
# just the specific tools these code paths use (resolved from the real PATH)
# and use only that directory as PATH in the subshells below — cheap, and
# jq is never among them.
NOJQ_BINDIR=$(mktemp -d)
for JQT in bash sh env mkdir mktemp mv rm cat chmod ln dirname basename \
    sed grep printf true false uname id tr cp readlink awk wc find xargs date; do
    JQF=$(command -v "$JQT" 2>/dev/null) || continue
    ln -sf "$JQF" "$NOJQ_BINDIR/$JQT" 2>/dev/null
done
NOJQ_PATH="$NOJQ_BINDIR"

# Own scratch dir — deliberately NOT reusing $TMPROOT, which the surrounding
# sections share and clean up on their own schedule.
NOJQ_TMPROOT=$(mktemp -d)
SETTINGS="$NOJQ_TMPROOT/settings.json"
NOJQ_OUT="$NOJQ_TMPROOT/merge_out.txt"
(
    PATH="$NOJQ_PATH"
    MERGE_SETTINGS_HINT='{"example": true}'
    merge_settings '.model = "opus"'
) >"$NOJQ_OUT" 2>&1
NOJQ_EXIT=$?

if [ "$NOJQ_EXIT" -ne 0 ] && grep -q 'add this to .*settings.json by hand' "$NOJQ_OUT" \
    && grep -q '"example": true' "$NOJQ_OUT"; then
    echo "  ok   merge_settings prints the caller's hint and fails non-zero when jq is unavailable"
    PASS=$((PASS + 1))
else
    echo "  FAIL merge_settings prints the caller's hint and fails non-zero when jq is unavailable (exit $NOJQ_EXIT)"
    sed 's/^/         /' "$NOJQ_OUT" 2>/dev/null
    FAIL=$((FAIL + 1))
fi
assert_eq "false" "$([ -f "$SETTINGS" ] && echo true || echo false)" \
    "merge_settings does not create settings.json when jq is unavailable"

APPLYPERMS_OUT="$NOJQ_TMPROOT/apply_perms_out.txt"
(
    PATH="$NOJQ_PATH"
    SETTINGS="$NOJQ_TMPROOT/settings2.json"
    EXTRA_DIRS=(/data/one)
    apply_permissions
) >"$APPLYPERMS_OUT" 2>&1
if grep -q 'additionalDirectories' "$APPLYPERMS_OUT" && grep -q '/data/one' "$APPLYPERMS_OUT"; then
    echo "  ok   apply_permissions' hint names additionalDirectories and the requested path"
    PASS=$((PASS + 1))
else
    echo "  FAIL apply_permissions' hint names additionalDirectories and the requested path"
    sed 's/^/         /' "$APPLYPERMS_OUT" 2>/dev/null
    FAIL=$((FAIL + 1))
fi

# step_rtk: with a settings.json already containing a Bash hook entry, the
# patch step must name what to add instead of skipping silently, and the
# self-test must blame the missing dependency rather than the wrapper.
NOJQ_RTK_TMPROOT="$NOJQ_TMPROOT/rtk"
mkdir -p "$NOJQ_RTK_TMPROOT"
NOJQ_RTK_FAKEBIN="$NOJQ_RTK_TMPROOT/fakebin"
mkdir -p "$NOJQ_RTK_FAKEBIN"
cat > "$NOJQ_RTK_FAKEBIN/rtk" << 'FAKE_RTK'
#!/usr/bin/env bash
case "${1:-}" in
    gain)      exit 0 ;;
    init)      exit 0 ;;
    hook)      cat >/dev/null
               printf '%s' '{"hookSpecificOutput":{"updatedInput":{"command":"rtk git status"}}}' ;;
    --version) printf 'rtk 0.0.0-fake\n' ;;
    *)         exit 0 ;;
esac
FAKE_RTK
chmod +x "$NOJQ_RTK_FAKEBIN/rtk"
NOJQ_RTK_BIN_DIR="$NOJQ_RTK_TMPROOT/bin"
NOJQ_RTK_CLAUDE_DIR="$NOJQ_RTK_TMPROOT/claude"
NOJQ_RTK_SETTINGS="$NOJQ_RTK_CLAUDE_DIR/settings.json"
mkdir -p "$NOJQ_RTK_BIN_DIR" "$NOJQ_RTK_CLAUDE_DIR"
cat > "$NOJQ_RTK_SETTINGS" << 'SEED_JSON'
{ "hooks": { "PreToolUse": [
  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
] } }
SEED_JSON
NOJQ_RTK_SETTINGS_BEFORE=$(cat "$NOJQ_RTK_SETTINGS")

NOJQ_RTK_OUT="$NOJQ_RTK_TMPROOT/out.txt"
(
    PATH="$NOJQ_RTK_FAKEBIN:$NOJQ_PATH"
    BIN_DIR="$NOJQ_RTK_BIN_DIR"
    CLAUDE_DIR="$NOJQ_RTK_CLAUDE_DIR"
    SETTINGS="$NOJQ_RTK_SETTINGS"
    CAN_LINK_USRLOCAL=false
    USRLOCAL_BIN="$NOJQ_RTK_TMPROOT/usrlocal"
    SKIP_RTK=false
    step_rtk
) >"$NOJQ_RTK_OUT" 2>&1
NOJQ_RTK_EXIT=$?
NOJQ_RTK_SETTINGS_AFTER=$(cat "$NOJQ_RTK_SETTINGS" 2>/dev/null)

# Assert the behavior, not the exact phrasing: jq must be named as the missing
# dependency, the user must get something actionable to paste, the self-test must
# not misattribute the failure to the wrapper, and settings must be left alone.
if [ "$NOJQ_RTK_EXIT" -eq 0 ] \
    && grep -q 'jq unavailable' "$NOJQ_RTK_OUT" \
    && grep -q '"matcher": "Bash"' "$NOJQ_RTK_OUT" \
    && grep -q 'jq unavailable — cannot verify the rtk hook rewrite' "$NOJQ_RTK_OUT" \
    && ! grep -q 'wrapper produced no rewrite' "$NOJQ_RTK_OUT" \
    && [ "$NOJQ_RTK_SETTINGS_AFTER" = "$NOJQ_RTK_SETTINGS_BEFORE" ]; then
    echo "  ok   step_rtk names the missing dependency instead of skipping silently or blaming the wrapper"
    PASS=$((PASS + 1))
else
    echo "  FAIL step_rtk names the missing dependency instead of skipping silently or blaming the wrapper (exit $NOJQ_RTK_EXIT)"
    sed 's/^/         /' "$NOJQ_RTK_OUT" 2>/dev/null
    FAIL=$((FAIL + 1))
fi

rm -rf "$NOJQ_TMPROOT" "$NOJQ_BINDIR"
unset NOJQ_PATH NOJQ_BINDIR NOJQ_TMPROOT JQT JQF SETTINGS NOJQ_OUT NOJQ_EXIT APPLYPERMS_OUT EXTRA_DIRS
unset NOJQ_RTK_TMPROOT NOJQ_RTK_FAKEBIN NOJQ_RTK_BIN_DIR NOJQ_RTK_CLAUDE_DIR NOJQ_RTK_SETTINGS
unset NOJQ_RTK_SETTINGS_BEFORE NOJQ_RTK_OUT NOJQ_RTK_EXIT NOJQ_RTK_SETTINGS_AFTER

echo "write_marker_block (orphan START marker without END)"
MD3="$TMPROOT/CLAUDE3.md"

# Create a file with START but no END - important user content should be preserved
{
    echo "line before"
    echo "$START"
    echo "important user content"
    echo "more user content"
} > "$MD3"

write_marker_block "$MD3" "$START" "$END" "new body"

# Verify the user content after START is still there (not deleted)
assert_eq "1" "$(grep -c 'important user content' "$MD3")" "user content after START preserved"
assert_eq "1" "$(grep -c 'more user content' "$MD3")" "all user content preserved"

# Verify the block is well-formed with exactly one START and one END
assert_eq "1" "$(grep -c -- "$START" "$MD3")" "exactly one START marker (orphan case)"
assert_eq "1" "$(grep -c -- "$END" "$MD3")" "exactly one END marker created (orphan case)"

# Verify the preamble is still there
assert_eq "1" "$(grep -c 'line before' "$MD3")" "preamble before START preserved (orphan case)"

rm -rf "$TMPROOT"

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
assert_eq "false" "$CUSTOM_PREFIX" \
    "PERSIST_ROOT == HOME means CUSTOM_PREFIX false (plain local)"

# RunPod shape: a writable persistent volume becomes PERSIST_ROOT.
WORKSPACE_CANDIDATE="$TMPROOT/workspace"; mkdir -p "$WORKSPACE_CANDIDATE"
run_probes
assert_eq "true" "$EPHEMERAL_HOME" "volume install root means EPHEMERAL_HOME true"
assert_eq "$TMPROOT/workspace/.local/bin" "$BIN_DIR" "BIN_DIR derives from PERSIST_ROOT"
assert_eq "true" "$CUSTOM_PREFIX" \
    "workspace fallback means PERSIST_ROOT != HOME, so CUSTOM_PREFIX true"

# HPC shape (finding 5): a custom install prefix must NOT imply EPHEMERAL_HOME
# — $HOME persists there, only the install location differs. Reset the
# workspace fallback so it cannot also be the reason EPHEMERAL_HOME goes true.
# It DOES imply CUSTOM_PREFIX (finding: PATH persistence must still fire).
WORKSPACE_CANDIDATE="$TMPROOT/nope"
PREFIX_ARG="$TMPROOT/hpc-prefix"
run_probes
assert_eq "false" "$EPHEMERAL_HOME" \
    "custom --prefix alone does not set EPHEMERAL_HOME (HPC quota case)"
assert_eq "$TMPROOT/hpc-prefix" "$PERSIST_ROOT" \
    "custom --prefix still relocates PERSIST_ROOT"
assert_eq "true" "$CUSTOM_PREFIX" \
    "custom --prefix sets CUSTOM_PREFIX true (PATH persistence must fire on HPC)"

# --ephemeral-home is an explicit override: forces the ephemeral-HOME
# behaviors even on a machine with a custom prefix and no workspace fallback.
EPHEMERAL_HOME_FLAG=true
run_probes
assert_eq "true" "$EPHEMERAL_HOME" \
    "--ephemeral-home forces EPHEMERAL_HOME true despite a custom prefix"
EPHEMERAL_HOME_FLAG=false

PREFIX_ARG=""
HOME="$HOME_SAVE"
rm -rf "$TMPROOT"

echo "ensure_persistence with CHECK_ONLY"
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/home"
mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/workspace"
mkdir -p "$WORKSPACE_CANDIDATE"
unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG=""
run_probes

# With CHECK_ONLY=true, ensure_persistence should be a no-op
CHECK_ONLY=true
ensure_persistence
assert_eq "false" "$([ -L "$HOME/.claude" ] && echo true || echo false)" \
    "CHECK_ONLY prevents symlink creation"
assert_eq "false" "$([ -d "$CLAUDE_DIR" ] && echo true || echo false)" \
    "CHECK_ONLY prevents CLAUDE_DIR creation"

rm -rf "$TMPROOT"
HOME="$HOME_SAVE"

echo "ensure_persistence migration success"
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/ephemeral_home"
mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/workspace"
mkdir -p "$WORKSPACE_CANDIDATE"

# Create a fake ~/.claude with content
mkdir -p "$HOME/.claude/settings"
echo "test content" > "$HOME/.claude/settings/test.txt"

unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG=""
CHECK_ONLY=false
run_probes

# Migration should succeed
if ensure_persistence 2>/dev/null; then
    echo "  ok   ensure_persistence returns 0 on success"; PASS=$((PASS + 1))
else
    echo "  FAIL ensure_persistence returns 0 on success"; FAIL=$((FAIL + 1))
fi

# Original should be renamed to .premigration.bak
assert_eq "true" "$([ -d "$HOME/.claude.premigration.bak" ] && echo true || echo false)" \
    "original directory renamed to .premigration.bak"

# Content should be in CLAUDE_DIR
assert_eq "true" "$([ -f "$CLAUDE_DIR/settings/test.txt" ] && echo true || echo false)" \
    "content copied to CLAUDE_DIR"

# ~/.claude should be a symlink to CLAUDE_DIR
assert_eq "true" "$([ -L "$HOME/.claude" ] && echo true || echo false)" \
    "~/.claude is a symlink"

SYMLINK_TARGET=$(readlink "$HOME/.claude")
assert_eq "$CLAUDE_DIR" "$SYMLINK_TARGET" \
    "~/.claude symlink points to CLAUDE_DIR"

rm -rf "$TMPROOT"
HOME="$HOME_SAVE"

echo "ensure_persistence migration failure path"
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/ephemeral_home"
mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/workspace"
mkdir -p "$WORKSPACE_CANDIDATE"

# Create a fake ~/.claude
mkdir -p "$HOME/.claude"
echo "content" > "$HOME/.claude/test.txt"

unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG=""
CHECK_ONLY=false
run_probes

# Make CLAUDE_DIR point to a non-writable location
CLAUDE_DIR="$TMPROOT/readonly/.claude"
mkdir -p "$TMPROOT/readonly"
chmod 000 "$TMPROOT/readonly"

# Migration should fail
if ! ensure_persistence 2>/dev/null; then
    echo "  ok   ensure_persistence returns non-zero on failure"; PASS=$((PASS + 1))
else
    echo "  FAIL ensure_persistence returns non-zero on failure"; FAIL=$((FAIL + 1))
fi

# Original should still exist (not deleted)
assert_eq "true" "$([ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ] && echo true || echo false)" \
    "original directory still exists after migration failure"

# No backup should have been created
assert_eq "false" "$([ -d "$HOME/.claude.premigration.bak" ] && echo true || echo false)" \
    "no backup created on migration failure"

# Clean up readonly directory
chmod 755 "$TMPROOT/readonly"
rm -rf "$TMPROOT"
HOME="$HOME_SAVE"

echo "ensure_persistence call site resilience"
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/ephemeral_home"
mkdir -p "$HOME"
# Make WORKSPACE_CANDIDATE non-writable so PERSIST_ROOT falls through
WORKSPACE_CANDIDATE="$TMPROOT/no_workspace"
mkdir -p "$TMPROOT/no_workspace"
chmod 000 "$TMPROOT/no_workspace"

# Point CLAUDE_TOOLS_PREFIX to a location where mkdir cannot succeed
CLAUDE_TOOLS_PREFIX="$TMPROOT/readonly/prefix"
mkdir -p "$TMPROOT/readonly"
chmod 000 "$TMPROOT/readonly"

# Export the env vars so the subprocess sees them
export TMPROOT HOME WORKSPACE_CANDIDATE CLAUDE_TOOLS_PREFIX

# Run the actual script as a subprocess with --skip-all, capturing output and exit status.
# --ephemeral-home is required here: a bare CLAUDE_TOOLS_PREFIX no longer
# implies EPHEMERAL_HOME (finding 5 — a custom prefix is the HPC quota case,
# where $HOME persists and ensure_persistence must NOT run). This test wants
# to force the ephemeral-HOME persistence path despite the hostile prefix, so
# it uses the explicit override the same way an HPC user with both a quota
# and a genuinely ephemeral home would.
OUTPUT_FILE="$TMPROOT/output.txt"
# Unset the library guard so the subprocess runs main, not just loads functions
( unset SETUP_CLAUDE_TOOLS_LIB; bash "$SCRIPT_DIR/setup_claude_tools.sh" --skip-all --ephemeral-home >"$OUTPUT_FILE" 2>&1 )
EXIT_STATUS=$?

# Script should exit 0 (not die from mkdir failure)
if [ "$EXIT_STATUS" -eq 0 ]; then
    echo "  ok   script survives persistence mkdir failure"; PASS=$((PASS + 1))
else
    echo "  FAIL script survives persistence mkdir failure (exit $EXIT_STATUS)"; FAIL=$((FAIL + 1))
fi

# Output should contain a warning about persistence setup
if [ -f "$OUTPUT_FILE" ] && grep -q "persistence setup failed" "$OUTPUT_FILE" 2>/dev/null; then
    echo "  ok   script warns about persistence setup failure"; PASS=$((PASS + 1))
else
    echo "  FAIL script warns about persistence setup failure"; FAIL=$((FAIL + 1))
fi

# Clean up readonly directories
chmod 755 "$TMPROOT/readonly" "$TMPROOT/no_workspace" 2>/dev/null || true
rm -rf "$TMPROOT"
HOME="$HOME_SAVE"
unset TMPROOT WORKSPACE_CANDIDATE CLAUDE_TOOLS_PREFIX

echo "ensure_persist_env"
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/home"; mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/workspace"; mkdir -p "$WORKSPACE_CANDIDATE"
unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG=""
EPHEMERAL_HOME_FLAG=false
CHECK_ONLY=false
run_probes

ensure_persist_env
assert_eq "true" "$([ -f "$PERSIST_ENV" ] && echo true || echo false)" \
    "PERSIST_ENV file created under CLAUDE_DIR"
assert_eq "1" "$(grep -Fc "export PATH=\"$BIN_DIR:\$PATH\"" "$PERSIST_ENV")" \
    "PATH pin present, with a literal (unexpanded) \$PATH"
assert_eq "1" "$(grep -Fc "export UV_TOOL_DIR=\"$UV_TOOL_DIR\"" "$PERSIST_ENV")" \
    "UV_TOOL_DIR pin present"
assert_eq "true" "$(grep -q '# claude-tools-source:start' "$HOME/.bashrc" 2>/dev/null && echo true || echo false)" \
    "~/.bashrc gets a guarded source line for PERSIST_ENV"
assert_eq "1" "$(grep -c '# claude-tools-source:start' "$HOME/.bashrc")" \
    "exactly one source marker in ~/.bashrc"

SNAP1=$(cat "$PERSIST_ENV"); BASHRC_SNAP1=$(cat "$HOME/.bashrc")
ensure_persist_env
SNAP2=$(cat "$PERSIST_ENV"); BASHRC_SNAP2=$(cat "$HOME/.bashrc")
assert_eq "$SNAP1" "$SNAP2" "PERSIST_ENV re-run is byte-identical (idempotent)"
assert_eq "$BASHRC_SNAP1" "$BASHRC_SNAP2" "~/.bashrc re-run is byte-identical (idempotent)"

rm -rf "$TMPROOT"
HOME="$HOME_SAVE"

echo "ensure_persist_env with custom --prefix, no --ephemeral-home (finding 1: HPC shape)"
# HPC: $HOME persists (no --ephemeral-home), but the install prefix is off
# PATH. PATH persistence must still fire even though EPHEMERAL_HOME is false
# — this is the gap finding 1 closes. The ~/.claude symlink must NOT appear
# (that stays gated on EPHEMERAL_HOME, which is false here).
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/home"; mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/nope"
unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG="$TMPROOT/hpc-prefix"
EPHEMERAL_HOME_FLAG=false
CHECK_ONLY=false
run_probes
assert_eq "false" "$EPHEMERAL_HOME" "HPC shape: EPHEMERAL_HOME stays false"
assert_eq "true" "$CUSTOM_PREFIX" "HPC shape: CUSTOM_PREFIX true"

ensure_persist_env
assert_eq "true" "$([ -f "$PERSIST_ENV" ] && echo true || echo false)" \
    "HPC shape: PERSIST_ENV file created under the custom prefix"
assert_eq "1" "$(grep -Fc "export PATH=\"$BIN_DIR:\$PATH\"" "$PERSIST_ENV" 2>/dev/null || echo 0)" \
    "HPC shape: PATH pin present with the custom-prefix bin dir"
assert_eq "true" "$(grep -q '# claude-tools-source:start' "$HOME/.bashrc" 2>/dev/null && echo true || echo false)" \
    "HPC shape: ~/.bashrc sources PERSIST_ENV"

ensure_persistence
assert_eq "false" "$([ -e "$HOME/.claude" ] && echo true || echo false)" \
    "HPC shape: ensure_persistence creates no ~/.claude symlink (EPHEMERAL_HOME false)"

rm -rf "$TMPROOT"
HOME="$HOME_SAVE"
PREFIX_ARG=""

echo "ensure_persist_env no-ops for plain local install (PERSIST_ROOT == HOME)"
# Local machine: nothing should write to ~/.bashrc at all — that would be a
# regression for a plain local user who never asked for tools relocated off
# their $HOME.
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)
HOME="$TMPROOT/home"; mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/nope"
unset CLAUDE_TOOLS_PREFIX
PREFIX_ARG=""
EPHEMERAL_HOME_FLAG=false
CHECK_ONLY=false
run_probes
assert_eq "false" "$EPHEMERAL_HOME" "plain local shape: EPHEMERAL_HOME false"
assert_eq "false" "$CUSTOM_PREFIX" "plain local shape: CUSTOM_PREFIX false"

ensure_persist_env
assert_eq "false" "$([ -f "$PERSIST_ENV" ] && echo true || echo false)" \
    "plain local shape: no PERSIST_ENV file written"
assert_eq "false" "$([ -f "$HOME/.bashrc" ] && echo true || echo false)" \
    "plain local shape: ~/.bashrc is never created/written"

rm -rf "$TMPROOT"
HOME="$HOME_SAVE"

echo "restore_symlinks"
TMPROOT=$(mktemp -d)
BIN_DIR="$TMPROOT/bin"; mkdir -p "$BIN_DIR"
UV_TOOL_BIN_DIR="$BIN_DIR"
printf '#!/bin/sh\necho rtk-stub\n' > "$BIN_DIR/rtk"; chmod +x "$BIN_DIR/rtk"
printf '#!/bin/sh\necho graphify-stub\n' > "$BIN_DIR/graphify"; chmod +x "$BIN_DIR/graphify"
USRLOCAL_BIN="$TMPROOT/usrlocal"; mkdir -p "$USRLOCAL_BIN"
CAN_LINK_USRLOCAL=true
CHECK_ONLY=false

restore_symlinks
assert_eq "true" "$([ -L "$USRLOCAL_BIN/rtk" ] && echo true || echo false)" \
    "restore_symlinks creates the rtk symlink"
assert_eq "true" "$([ -L "$USRLOCAL_BIN/graphify" ] && echo true || echo false)" \
    "restore_symlinks creates the graphify symlink"
assert_eq "$BIN_DIR/rtk" "$(readlink "$USRLOCAL_BIN/rtk")" \
    "rtk symlink points at BIN_DIR"

rm -f "$USRLOCAL_BIN/rtk" "$USRLOCAL_BIN/graphify"
CAN_LINK_USRLOCAL=false
restore_symlinks
assert_eq "false" "$([ -e "$USRLOCAL_BIN/rtk" ] && echo true || echo false)" \
    "restore_symlinks does nothing when CAN_LINK_USRLOCAL is false"

unset USRLOCAL_BIN
rm -rf "$TMPROOT"

echo "--skip-all restores PATH pin, bashrc source line, and symlinks after a simulated restart"
# The scenario findings 3+4 describe: RunPod wipes /root (HOME) and
# /usr/local/bin on every restart but keeps /workspace (PERSIST_ROOT). rtk and
# graphify were already installed under $PERSIST_ROOT/.local/bin before the
# restart; nothing there was lost. What WAS lost: ~/.bashrc (so nothing
# sources the PATH/token pins any more) and the /usr/local/bin symlinks (so
# bare `rtk`/`graphify` are gone from PATH). `--skip-all` is documented as the
# post-restart command — it must restore both without reinstalling anything.
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)

WORKSPACE_CANDIDATE="$TMPROOT/workspace"
mkdir -p "$WORKSPACE_CANDIDATE/.local/bin"
printf '#!/bin/sh\necho rtk-stub\n' > "$WORKSPACE_CANDIDATE/.local/bin/rtk"
chmod +x "$WORKSPACE_CANDIDATE/.local/bin/rtk"
printf '#!/bin/sh\necho graphify-stub\n' > "$WORKSPACE_CANDIDATE/.local/bin/graphify"
chmod +x "$WORKSPACE_CANDIDATE/.local/bin/graphify"

HOME="$TMPROOT/fresh_home"
mkdir -p "$HOME"
unset CLAUDE_TOOLS_PREFIX

USRLOCAL_BIN_SIM="$TMPROOT/usrlocal"
mkdir -p "$USRLOCAL_BIN_SIM"

export TMPROOT HOME WORKSPACE_CANDIDATE
export USRLOCAL_BIN="$USRLOCAL_BIN_SIM"

SKIPALL_OUT="$TMPROOT/skipall.txt"
( unset SETUP_CLAUDE_TOOLS_LIB; bash "$SCRIPT_DIR/setup_claude_tools.sh" --skip-all >"$SKIPALL_OUT" 2>&1 )
SKIPALL_EXIT=$?
assert_eq "0" "$SKIPALL_EXIT" "skip-all-restore: script exits 0"

assert_eq "true" "$([ -f "$WORKSPACE_CANDIDATE/.claude/env" ] && echo true || echo false)" \
    "skip-all-restore: PERSIST_ENV exists under the persistent volume"

if [ -f "$WORKSPACE_CANDIDATE/.claude/env" ]; then
    PATHLINE_COUNT=$(grep -Fc "export PATH=\"$WORKSPACE_CANDIDATE/.local/bin:\$PATH\"" "$WORKSPACE_CANDIDATE/.claude/env")
else
    PATHLINE_COUNT="FILE_MISSING"
fi
assert_eq "1" "$PATHLINE_COUNT" \
    "skip-all-restore: PATH pin present with the workspace bin dir"

assert_eq "true" "$([ -f "$HOME/.bashrc" ] && grep -q '# claude-tools-source:start' "$HOME/.bashrc" && echo true || echo false)" \
    "skip-all-restore: fresh ~/.bashrc sources PERSIST_ENV"

assert_eq "true" "$([ -L "$USRLOCAL_BIN_SIM/rtk" ] && echo true || echo false)" \
    "skip-all-restore: rtk symlink restored without reinstalling"
assert_eq "true" "$([ -L "$USRLOCAL_BIN_SIM/graphify" ] && echo true || echo false)" \
    "skip-all-restore: graphify symlink restored without reinstalling"

if [ "$SKIPALL_EXIT" -ne 0 ]; then
    sed 's/^/         /' "$SKIPALL_OUT" 2>/dev/null
fi

unset USRLOCAL_BIN
rm -rf "$TMPROOT"
HOME="$HOME_SAVE"
unset TMPROOT WORKSPACE_CANDIDATE

echo "--skip-all with --prefix (finding 1: HPC shape) writes PATH persistence, no symlink"
# The scenario finding 1 describes: an HPC login node with --prefix pointing
# at scratch/project storage. $HOME persists (unlike RunPod) so there is no
# --ephemeral-home and no restart-wipe to simulate — but $BIN_DIR under the
# custom prefix is on no default PATH, so PATH persistence must still fire.
# The ~/.claude symlink and auth prompt must NOT appear: $HOME/.claude was
# never relocated.
HOME_SAVE="$HOME"
TMPROOT=$(mktemp -d)

HOME="$TMPROOT/home"
mkdir -p "$HOME"
WORKSPACE_CANDIDATE="$TMPROOT/nope"
unset CLAUDE_TOOLS_PREFIX

HPC_PREFIX="$TMPROOT/hpc-prefix"

USRLOCAL_BIN_SIM="$TMPROOT/usrlocal"
mkdir -p "$USRLOCAL_BIN_SIM"

export TMPROOT HOME WORKSPACE_CANDIDATE
export USRLOCAL_BIN="$USRLOCAL_BIN_SIM"

HPC_OUT="$TMPROOT/hpc.txt"
( unset SETUP_CLAUDE_TOOLS_LIB; bash "$SCRIPT_DIR/setup_claude_tools.sh" --skip-all --prefix "$HPC_PREFIX" >"$HPC_OUT" 2>&1 )
HPC_EXIT=$?
assert_eq "0" "$HPC_EXIT" "hpc-prefix: script exits 0"

assert_eq "true" "$([ -f "$HPC_PREFIX/.claude/env" ] && echo true || echo false)" \
    "hpc-prefix: PERSIST_ENV exists under the custom prefix"

if [ -f "$HPC_PREFIX/.claude/env" ]; then
    HPC_PATHLINE_COUNT=$(grep -Fc "export PATH=\"$HPC_PREFIX/.local/bin:\$PATH\"" "$HPC_PREFIX/.claude/env")
else
    HPC_PATHLINE_COUNT="FILE_MISSING"
fi
assert_eq "1" "$HPC_PATHLINE_COUNT" \
    "hpc-prefix: PATH pin present with the custom-prefix bin dir"

assert_eq "true" "$([ -f "$HOME/.bashrc" ] && grep -q '# claude-tools-source:start' "$HOME/.bashrc" && echo true || echo false)" \
    "hpc-prefix: ~/.bashrc sources PERSIST_ENV"

assert_eq "false" "$([ -e "$HOME/.claude" ] && echo true || echo false)" \
    "hpc-prefix: no ~/.claude symlink created (HOME is not ephemeral)"

if [ "$HPC_EXIT" -ne 0 ]; then
    sed 's/^/         /' "$HPC_OUT" 2>/dev/null
fi

unset USRLOCAL_BIN
rm -rf "$TMPROOT"
HOME="$HOME_SAVE"
unset TMPROOT WORKSPACE_CANDIDATE HPC_PREFIX

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
    skip "rtk wrapper contract — rtk or the wrapper is not installed on this machine"
fi

echo "step_rtk settings-patch survives malformed JSON"
# The settings-patch jq call lives inline inside step_rtk, not in a standalone
# function, so reaching it means running step_rtk itself. To do that without
# depending on a real rtk install or touching the machine's real ~/.claude, a
# fake `rtk` shim goes first on PATH: it satisfies every call step_rtk makes
# (`gain --help`, `--version`, `init -g --auto-patch`, `hook claude`) so the
# "already installed" branch is taken and the curl installer never runs.
RTK_TMPROOT=$(mktemp -d)
RTK_FAKEBIN="$RTK_TMPROOT/fakebin"
mkdir -p "$RTK_FAKEBIN"
cat > "$RTK_FAKEBIN/rtk" << 'FAKE_RTK'
#!/usr/bin/env bash
case "${1:-}" in
    gain)      exit 0 ;;
    init)      exit 0 ;;
    hook)      cat >/dev/null
               printf '%s' '{"hookSpecificOutput":{"updatedInput":{"command":"rtk git status"}}}' ;;
    --version) printf 'rtk 0.0.0-fake\n' ;;
    *)         exit 0 ;;
esac
FAKE_RTK
chmod +x "$RTK_FAKEBIN/rtk"

RTK_BIN_DIR="$RTK_TMPROOT/bin"
RTK_CLAUDE_DIR="$RTK_TMPROOT/claude"
RTK_SETTINGS="$RTK_CLAUDE_DIR/settings.json"
mkdir -p "$RTK_BIN_DIR" "$RTK_CLAUDE_DIR"
printf '{"hooks": this is not valid json' > "$RTK_SETTINGS"
RTK_SETTINGS_BEFORE=$(cat "$RTK_SETTINGS")

RTK_OUT_FILE="$RTK_TMPROOT/out.txt"
# Subshell: `. setup_claude_tools.sh` re-triggers `set -euo pipefail` in this
# process only, so if the settings-patch guard regresses, the subshell aborts
# without taking the outer harness down with it — RTK_EXIT catches that.
(
    PATH="$RTK_FAKEBIN:$PATH"
    SETUP_CLAUDE_TOOLS_LIB=1
    export PATH SETUP_CLAUDE_TOOLS_LIB
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/setup_claude_tools.sh"
    BIN_DIR="$RTK_BIN_DIR"
    CLAUDE_DIR="$RTK_CLAUDE_DIR"
    SETTINGS="$RTK_SETTINGS"
    CAN_LINK_USRLOCAL=false
    USRLOCAL_BIN="$RTK_TMPROOT/usrlocal"
    SKIP_RTK=false
    step_rtk
) >"$RTK_OUT_FILE" 2>&1
RTK_EXIT=$?

RTK_SETTINGS_AFTER=$(cat "$RTK_SETTINGS" 2>/dev/null || echo "__MISSING__")

if [ "$RTK_EXIT" -eq 0 ] \
    && grep -q "failed to update" "$RTK_OUT_FILE" \
    && [ "$RTK_SETTINGS_AFTER" = "$RTK_SETTINGS_BEFORE" ]; then
    echo "  ok   settings-patch warns on malformed JSON, leaves it byte-identical, does not abort"
    PASS=$((PASS + 1))
else
    echo "  FAIL settings-patch warns on malformed JSON, leaves it byte-identical, does not abort (exit $RTK_EXIT)"
    sed 's/^/         /' "$RTK_OUT_FILE" 2>/dev/null
    FAIL=$((FAIL + 1))
fi

rm -rf "$RTK_TMPROOT"
unset RTK_TMPROOT RTK_FAKEBIN RTK_BIN_DIR RTK_CLAUDE_DIR RTK_SETTINGS RTK_SETTINGS_BEFORE RTK_SETTINGS_AFTER RTK_OUT_FILE RTK_EXIT

echo "step_rtk settings-patch dedupes Bash matcher entries"
# Reachability: same constraint as above — the dedupe walk()/unique_by lives
# inline in step_rtk, so exercising it means running step_rtk for real. Seed
# $SETTINGS with *valid* JSON containing two Bash-matcher PreToolUse entries
# (one shaped like RTK's legacy native "rtk hook claude" hook, one shaped like
# a stale wrapper path from an old install) plus one non-Bash matcher entry,
# then confirm the dedupe collapses the two Bash entries to one pointing at
# the wrapper, and leaves the non-Bash entry untouched. Run twice to prove
# idempotency reproducibly, not just by a one-off manual jq count.
RTKD_TMPROOT=$(mktemp -d)
RTKD_FAKEBIN="$RTKD_TMPROOT/fakebin"
mkdir -p "$RTKD_FAKEBIN"
cat > "$RTKD_FAKEBIN/rtk" << 'FAKE_RTK'
#!/usr/bin/env bash
case "${1:-}" in
    gain)      exit 0 ;;
    init)      exit 0 ;;
    hook)      cat >/dev/null
               printf '%s' '{"hookSpecificOutput":{"updatedInput":{"command":"rtk git status"}}}' ;;
    --version) printf 'rtk 0.0.0-fake\n' ;;
    *)         exit 0 ;;
esac
FAKE_RTK
chmod +x "$RTKD_FAKEBIN/rtk"

RTKD_BIN_DIR="$RTKD_TMPROOT/bin"
RTKD_CLAUDE_DIR="$RTKD_TMPROOT/claude"
RTKD_SETTINGS="$RTKD_CLAUDE_DIR/settings.json"
mkdir -p "$RTKD_BIN_DIR" "$RTKD_CLAUDE_DIR"
cat > "$RTKD_SETTINGS" << 'SEED_JSON'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash /old/stale/path/rtk-rewrite.sh" } ] },
      { "matcher": "Write", "hooks": [ { "type": "command", "command": "echo not-rtk" } ] }
    ]
  }
}
SEED_JSON

RTKD_EXPECTED_CMD="bash $RTKD_CLAUDE_DIR/hooks/rtk-rewrite.sh"

run_step_rtk_once() {
    local out_file="$1"
    (
        PATH="$RTKD_FAKEBIN:$PATH"
        SETUP_CLAUDE_TOOLS_LIB=1
        export PATH SETUP_CLAUDE_TOOLS_LIB
        # shellcheck source=/dev/null
        . "$SCRIPT_DIR/setup_claude_tools.sh"
        BIN_DIR="$RTKD_BIN_DIR"
        CLAUDE_DIR="$RTKD_CLAUDE_DIR"
        SETTINGS="$RTKD_SETTINGS"
        CAN_LINK_USRLOCAL=false
        USRLOCAL_BIN="$RTKD_TMPROOT/usrlocal"
        SKIP_RTK=false
        step_rtk
    ) >"$out_file" 2>&1
}

RTKD_OUT1="$RTKD_TMPROOT/out1.txt"
run_step_rtk_once "$RTKD_OUT1"
RTKD_EXIT1=$?

RTKD_BASH_COUNT_1=$(jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length' "$RTKD_SETTINGS" 2>/dev/null)
RTKD_BASH_CMD_1=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$RTKD_SETTINGS" 2>/dev/null)
RTKD_WRITE_CMD_1=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[0].command' "$RTKD_SETTINGS" 2>/dev/null)

if [ "$RTKD_EXIT1" -eq 0 ] \
    && [ "$RTKD_BASH_COUNT_1" = "1" ] \
    && [ "$RTKD_BASH_CMD_1" = "$RTKD_EXPECTED_CMD" ] \
    && [ "$RTKD_WRITE_CMD_1" = "echo not-rtk" ]; then
    echo "  ok   first run collapses two Bash entries to one pointing at the wrapper, keeps the Write entry"
    PASS=$((PASS + 1))
else
    echo "  FAIL first run dedupe (exit $RTKD_EXIT1, bash_count=$RTKD_BASH_COUNT_1, bash_cmd=[$RTKD_BASH_CMD_1], write_cmd=[$RTKD_WRITE_CMD_1])"
    sed 's/^/         /' "$RTKD_OUT1" 2>/dev/null
    FAIL=$((FAIL + 1))
fi

RTKD_OUT2="$RTKD_TMPROOT/out2.txt"
run_step_rtk_once "$RTKD_OUT2"
RTKD_EXIT2=$?

RTKD_BASH_COUNT_2=$(jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length' "$RTKD_SETTINGS" 2>/dev/null)
RTKD_BASH_CMD_2=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$RTKD_SETTINGS" 2>/dev/null)
RTKD_WRITE_CMD_2=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[0].command' "$RTKD_SETTINGS" 2>/dev/null)

if [ "$RTKD_EXIT2" -eq 0 ] \
    && [ "$RTKD_BASH_COUNT_2" = "1" ] \
    && [ "$RTKD_BASH_CMD_2" = "$RTKD_EXPECTED_CMD" ] \
    && [ "$RTKD_WRITE_CMD_2" = "echo not-rtk" ]; then
    echo "  ok   second run stays at one Bash entry (idempotent), keeps the Write entry"
    PASS=$((PASS + 1))
else
    echo "  FAIL second run dedupe not idempotent (exit $RTKD_EXIT2, bash_count=$RTKD_BASH_COUNT_2, bash_cmd=[$RTKD_BASH_CMD_2], write_cmd=[$RTKD_WRITE_CMD_2])"
    sed 's/^/         /' "$RTKD_OUT2" 2>/dev/null
    FAIL=$((FAIL + 1))
fi

rm -rf "$RTKD_TMPROOT"
unset RTKD_TMPROOT RTKD_FAKEBIN RTKD_BIN_DIR RTKD_CLAUDE_DIR RTKD_SETTINGS RTKD_EXPECTED_CMD
unset RTKD_OUT1 RTKD_EXIT1 RTKD_BASH_COUNT_1 RTKD_BASH_CMD_1 RTKD_WRITE_CMD_1
unset RTKD_OUT2 RTKD_EXIT2 RTKD_BASH_COUNT_2 RTKD_BASH_CMD_2 RTKD_WRITE_CMD_2
unset -f run_step_rtk_once

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

echo "write_marker_block (multi-line content — the real routing_block_content() payload)"
# The bug that shipped to production (macOS /usr/bin/awk erroring on a -v
# value containing a raw newline) was invisible to every other assertion in
# this file because they all pass single-line content ("first version",
# "new body", "stable content"). These assertions use the actual multi-line
# block this script writes to ~/.claude/CLAUDE.md — including its embedded
# blank line between the two ## sections — against both branches.
TMPROOT=$(mktemp -d)
START='<!-- claude-tools:start -->'
END='<!-- claude-tools:end -->'
BLOCK="$(routing_block_content)"

# --- append-when-absent branch ---
MD4="$TMPROOT/CLAUDE4.md"
printf 'preamble content\n' > "$MD4"

if write_marker_block "$MD4" "$START" "$END" "$BLOCK"; then
    WMB_EXIT1=0
else
    WMB_EXIT1=$?
fi
assert_eq "0" "$WMB_EXIT1" "append branch: write_marker_block returns success"

EXTRACTED1=$(awk -v s="$START" -v e="$END" '
    $0 == s { f = 1; next }
    $0 == e { f = 0; next }
    f { print }
' "$MD4")
assert_eq "$BLOCK" "$EXTRACTED1" "append branch: block body matches routing_block_content() exactly, including the embedded blank line"
assert_eq "1" "$(grep -Fc -- "$START" "$MD4")" "append branch: exactly one start marker"
assert_eq "1" "$(grep -Fc -- "$END" "$MD4")" "append branch: exactly one end marker"
assert_eq "1" "$(grep -Fc 'preamble content' "$MD4")" "append branch: preamble content kept"

# --- replace-in-place branch ---
MD5="$TMPROOT/CLAUDE5.md"
{
    echo "preamble before"
    echo "$START"
    echo "old single-line body"
    echo "$END"
    echo "postamble after"
} > "$MD5"

if write_marker_block "$MD5" "$START" "$END" "$BLOCK"; then
    WMB_EXIT2=0
else
    WMB_EXIT2=$?
fi
assert_eq "0" "$WMB_EXIT2" "replace branch: write_marker_block returns success"

EXTRACTED2=$(awk -v s="$START" -v e="$END" '
    $0 == s { f = 1; next }
    $0 == e { f = 0; next }
    f { print }
' "$MD5")
assert_eq "$BLOCK" "$EXTRACTED2" "replace branch: block body matches routing_block_content() exactly, including the embedded blank line"
assert_eq "1" "$(grep -Fc -- "$START" "$MD5")"        "replace branch: exactly one start marker"
assert_eq "1" "$(grep -Fc -- "$END" "$MD5")"          "replace branch: exactly one end marker"
assert_eq "1" "$(grep -Fc 'preamble before' "$MD5")"  "replace branch: preamble preserved"
assert_eq "1" "$(grep -Fc 'postamble after' "$MD5")"  "replace branch: postamble preserved"
assert_eq "0" "$(grep -Fc 'old single-line body' "$MD5")" "replace branch: old body removed"

# --- idempotency with multi-line content: run twice, byte-identical ---
SNAP_MULTI_1=$(cat "$MD5")
if write_marker_block "$MD5" "$START" "$END" "$BLOCK"; then
    WMB_EXIT3=0
else
    WMB_EXIT3=$?
fi
SNAP_MULTI_2=$(cat "$MD5")
assert_eq "0" "$WMB_EXIT3" "replace branch (multi-line): second run returns success"
assert_eq "$SNAP_MULTI_1" "$SNAP_MULTI_2" "replace branch (multi-line): second run byte-identical to first (idempotent)"

rm -rf "$TMPROOT"

echo "write_marker_block survives a failing mktemp / awk (finding 2)"
# This is the exact gap that let the truncation bug ship: every assertion
# above feeds write_marker_block a healthy filesystem. Reproduce the failure
# preconditions directly — a target file with hand-written pre-existing
# content and no markers yet (the append/markers-absent branch, where the
# pre-fix code truncated to just the new block) — and stub mktemp / awk to
# fail via a PATH shim, calling write_marker_block the way every real call
# site does: `if write_marker_block ...; then ok; else warn; fi`. A correct
# implementation must return non-zero AND leave the file byte-identical to
# before.
TMPROOT=$(mktemp -d)
WMB_FAIL_FILE="$TMPROOT/target.txt"
FAKE_BIN="$TMPROOT/fakebin"
mkdir -p "$FAKE_BIN"
REAL_PATH="$PATH"

# --- mktemp fails ---
printf 'hand-written line one\nhand-written line two\n' > "$WMB_FAIL_FILE"
WMB_FAIL_BEFORE=$(cat "$WMB_FAIL_FILE")
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/mktemp"
chmod +x "$FAKE_BIN/mktemp"
PATH="$FAKE_BIN:$REAL_PATH"
hash -r
if write_marker_block "$WMB_FAIL_FILE" "# wmb-fail:start" "# wmb-fail:end" "new block body"; then
    WMB_MKTEMP_RC=0
else
    WMB_MKTEMP_RC=$?
fi
WMB_MKTEMP_AFTER=$(cat "$WMB_FAIL_FILE" 2>/dev/null)
PATH="$REAL_PATH"
hash -r
rm -f "$FAKE_BIN/mktemp"

assert_eq "true" "$([ "$WMB_MKTEMP_RC" -ne 0 ] && echo true || echo false)" \
    "write_marker_block: non-zero return when mktemp fails"
assert_eq "$WMB_FAIL_BEFORE" "$WMB_MKTEMP_AFTER" \
    "write_marker_block: target file byte-identical to before when mktemp fails"

# --- awk fails ---
printf 'hand-written line one\nhand-written line two\n' > "$WMB_FAIL_FILE"
WMB_FAIL_BEFORE2=$(cat "$WMB_FAIL_FILE")
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/awk"
chmod +x "$FAKE_BIN/awk"
PATH="$FAKE_BIN:$REAL_PATH"
hash -r
if write_marker_block "$WMB_FAIL_FILE" "# wmb-fail:start" "# wmb-fail:end" "new block body"; then
    WMB_AWK_RC=0
else
    WMB_AWK_RC=$?
fi
WMB_AWK_AFTER=$(cat "$WMB_FAIL_FILE" 2>/dev/null)
# Restore PATH before the assertions/cleanup below so the stub never leaks
# into anything that runs after this block.
PATH="$REAL_PATH"
hash -r
rm -f "$FAKE_BIN/awk"

assert_eq "true" "$([ "$WMB_AWK_RC" -ne 0 ] && echo true || echo false)" \
    "write_marker_block: non-zero return when awk fails"
assert_eq "$WMB_FAIL_BEFORE2" "$WMB_AWK_AFTER" \
    "write_marker_block: target file byte-identical to before when awk fails"

rm -rf "$TMPROOT"
unset WMB_FAIL_FILE FAKE_BIN REAL_PATH WMB_FAIL_BEFORE WMB_FAIL_BEFORE2 \
    WMB_MKTEMP_RC WMB_MKTEMP_AFTER WMB_AWK_RC WMB_AWK_AFTER

echo ""
if [ "$SKIP" -gt 0 ]; then
    echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
else
    echo "passed: $PASS  failed: $FAIL"
fi
[ "$FAIL" -eq 0 ]
