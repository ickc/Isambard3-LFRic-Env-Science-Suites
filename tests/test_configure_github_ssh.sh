#!/usr/bin/env bash
# Unit tests for configure_github_ssh() in env_lfric_gcc/install.sh
#
# Usage: bash tests/test_configure_github_ssh.sh
#
# Tests run entirely in subshells with mock binaries — no real SSH connections
# are made and no real ssh-agent processes are spawned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../env_lfric_gcc/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

ok() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail_test() { echo -e "${RED}FAIL${NC}: $1 — $2"; FAIL=$((FAIL + 1)); }
section() { echo -e "\n${YELLOW}--- $1 ---${NC}"; }

# ---------------------------------------------------------------------------
# Extract the configure_github_ssh function text from install.sh so we can
# inject it into test subshells without sourcing the full script (which would
# call main()).
# ---------------------------------------------------------------------------
FUNC_DEF="$(awk '
  /^configure_github_ssh\(\)/ { found=1 }
  found { print }
  found && /^\}$/ { exit }
' "$INSTALL_SH")"

if [ -z "$FUNC_DEF" ]; then
  echo "ERROR: Could not extract configure_github_ssh from $INSTALL_SH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# run_case LABEL ENV_BLOCK [ssh_add_list_exit] [ssh_add_add_exit] [key_exists]
#
# Runs configure_github_ssh in a subshell with:
#   ENV_BLOCK         — shell code evaluated before the function runs
#   ssh_add_list_exit — exit code mock ssh-add returns for 'ssh-add -l'
#                       (default 1 = no keys; use "missing" for no ssh-add)
#   ssh_add_add_exit  — exit code mock ssh-add returns when adding a key (default 0)
#   key_exists        — 1 to create a placeholder key file (default 0)
#
# Prints one line per notable event:
#   EXIT:<n>
#   GIT_SSH_COMMAND:<value or UNSET>
#   WARN:<message>
#   FAIL_MSG:<message>
# ---------------------------------------------------------------------------
run_case() {
  local label="$1"
  local env_block="$2"
  local ssh_add_list_exit="${3:-1}"
  local ssh_add_add_exit="${4:-0}"
  local key_exists="${5:-0}"

  (
    set +eu   # don't let configure_github_ssh returning 1 kill the subshell
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT

    MOCK_BIN="$TMPD/bin"
    mkdir -p "$MOCK_BIN"

    # Mock ssh-add
    if [ "$ssh_add_list_exit" != "missing" ]; then
      LIST_EXIT="$ssh_add_list_exit"
      ADD_EXIT="$ssh_add_add_exit"
      cat > "$MOCK_BIN/ssh-add" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then exit $LIST_EXIT; fi
exit $ADD_EXIT
EOF
      chmod +x "$MOCK_BIN/ssh-add"
    fi

    # Mock ssh-agent — prints the eval-able lines that export SSH_AUTH_SOCK etc.
    cat > "$MOCK_BIN/ssh-agent" <<'EOF'
#!/usr/bin/env bash
PID=$$
echo "SSH_AUTH_SOCK=/tmp/mock_agent_${PID}.sock; export SSH_AUTH_SOCK;"
echo "SSH_AGENT_PID=${PID}; export SSH_AGENT_PID;"
echo "echo Agent pid ${PID};"
EOF
    chmod +x "$MOCK_BIN/ssh-agent"

    # Mock setsid — just exec the command so ssh-add still runs
    cat > "$MOCK_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$MOCK_BIN/setsid"

    export PATH="$MOCK_BIN:$PATH"

    # Create a placeholder key file if requested
    TEST_KEY="$TMPD/id_test"
    if [ "$key_exists" -eq 1 ]; then
      echo "fake_key_data" > "$TEST_KEY"
      export GITHUB_SSH_KEY="$TEST_KEY"
    else
      export GITHUB_SSH_KEY="/nonexistent/key_$$"
    fi

    # Stub fail/warn/info so we can capture output
    WARNED=()
    FAILED=()
    fail() { FAILED+=("$*"); return 1; }
    warn() { WARNED+=("$*"); }
    info() { :; }

    # Clear vars that tests must set explicitly
    unset GIT_SSH_COMMAND SSH_AUTH_SOCK SSH_AGENT_PID GITHUB_SSH_PASSPHRASE 2>/dev/null || true

    # Apply test-specific environment
    eval "$env_block"

    # Inject the function
    eval "$FUNC_DEF"

    configure_github_ssh; rc=$?

    echo "EXIT:$rc"
    echo "GIT_SSH_COMMAND:${GIT_SSH_COMMAND:-UNSET}"
    for w in "${WARNED[@]+"${WARNED[@]}"}"; do echo "WARN:$w"; done
    for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "FAIL_MSG:$f"; done
  ) 2>/dev/null
}

check() {
  local label="$1" needle="$2" output="$3"
  if grep -qF "$needle" <<< "$output"; then
    ok "$label"
  else
    fail_test "$label" "expected '$needle' in output:\n$output"
  fi
}

check_absent() {
  local label="$1" needle="$2" output="$3"
  if ! grep -qF "$needle" <<< "$output"; then
    ok "$label"
  else
    fail_test "$label" "unexpected '$needle' found in output:\n$output"
  fi
}

# ===========================================================================
# SECTION 1: Agent forwarding — SSH_AUTH_SOCK valid, keys loaded
# ===========================================================================
section "Agent forwarding"

# T1: agent forwarding, no local key file, no pre-set GIT_SSH_COMMAND
# Expected: return 0, set a minimal GIT_SSH_COMMAND with StrictHostKeyChecking
out=$(run_case "T1" 'SSH_AUTH_SOCK=/tmp/forwarded.sock' 0 0 0) || true
check    "T1 exit 0"                    "EXIT:0"                     "$out"
check    "T1 GIT_SSH_COMMAND is set"    "StrictHostKeyChecking"      "$out"
check_absent "T1 no failure"           "FAIL_MSG"                   "$out"

# T2: agent forwarding, key file also present (common when SSHing between nodes with same home)
# Expected: return 0 using agent, GIT_SSH_COMMAND without -i (agent path, not key-file path)
out=$(run_case "T2" 'SSH_AUTH_SOCK=/tmp/forwarded.sock' 0 0 1) || true
check    "T2 exit 0"                    "EXIT:0"                     "$out"
check_absent "T2 no failure"           "FAIL_MSG"                   "$out"

# T3: agent forwarding, but GIT_SSH_COMMAND already pre-set by caller
# Expected: return 0, GIT_SSH_COMMAND unchanged
out=$(run_case "T3" 'SSH_AUTH_SOCK=/tmp/forwarded.sock; GIT_SSH_COMMAND="ssh -o PreexistingOption=yes"' 0 0 0) || true
check    "T3 exit 0"                    "EXIT:0"                               "$out"
check    "T3 GIT_SSH_COMMAND unchanged" "GIT_SSH_COMMAND:ssh -o PreexistingOption=yes" "$out"

# ===========================================================================
# SECTION 2: SSH_AUTH_SOCK set but unusable (stale socket)
# ===========================================================================
section "Stale SSH_AUTH_SOCK"

# T4: stale socket (ssh-add -l fails), no key file, no passphrase → should fail
# (no agent, no key file, no GIT_SSH_COMMAND → nothing works)
out=$(run_case "T4" 'SSH_AUTH_SOCK=/tmp/stale.sock' 1 0 0) || true
check "T4 stale agent, no key → fail"  "FAIL_MSG" "$out"

# T5: stale socket, key file present, no passphrase → unencrypted key path
out=$(run_case "T5" 'SSH_AUTH_SOCK=/tmp/stale.sock' 1 0 1) || true
check    "T5 exit 0"                        "EXIT:0"         "$out"
check    "T5 GIT_SSH_COMMAND with key"      "IdentitiesOnly" "$out"
check    "T5 BatchMode set (unencrypted)"   "BatchMode=yes"  "$out"

# ===========================================================================
# SECTION 3: GIT_SSH_COMMAND pre-set (walkthrough.sh or user)
# ===========================================================================
section "GIT_SSH_COMMAND pre-set by caller"

# T6: pre-set, no agent, no key file, no passphrase → trust it, return 0
out=$(run_case "T6" 'GIT_SSH_COMMAND="ssh -i /some/path/key"' 1 0 0) || true
check    "T6 exit 0"         "EXIT:0"    "$out"
check_absent "T6 no failure" "FAIL_MSG"  "$out"

# T7: pre-set, no agent, PASSPHRASE set, no key file → still trust it, no ssh-add crash
out=$(run_case "T7" 'GIT_SSH_COMMAND="ssh -i /some/path/key"; GITHUB_SSH_PASSPHRASE=secret' 1 0 0) || true
check    "T7 exit 0"         "EXIT:0"    "$out"
check_absent "T7 no failure" "FAIL_MSG"  "$out"

# T8: pre-set, working agent → return 0 immediately
out=$(run_case "T8" 'GIT_SSH_COMMAND="ssh -i /some/path/key"; SSH_AUTH_SOCK=/tmp/agent.sock' 0 0 0) || true
check    "T8 exit 0"         "EXIT:0"    "$out"

# ===========================================================================
# SECTION 4: No agent, no pre-set command — direct key-file paths
# ===========================================================================
section "Direct key-file (no agent, no pre-set GIT_SSH_COMMAND)"

# T9: no agent, no key file → fail
out=$(run_case "T9" '' 1 0 0) || true
check "T9 missing key → fail"  "FAIL_MSG" "$out"

# T10: no agent, key file present, no passphrase → unencrypted key, BatchMode
out=$(run_case "T10" '' 1 0 1) || true
check    "T10 exit 0"                       "EXIT:0"         "$out"
check    "T10 GIT_SSH_COMMAND with key"     "IdentitiesOnly" "$out"
check    "T10 BatchMode=yes"                "BatchMode=yes"  "$out"
check_absent "T10 no failure"              "FAIL_MSG"        "$out"

# T11: no agent, key file present, PASSPHRASE env set → start agent, add key
out=$(run_case "T11" 'GITHUB_SSH_PASSPHRASE=s3cr3t' 1 0 1) || true
check    "T11 exit 0"                       "EXIT:0"         "$out"
check    "T11 GIT_SSH_COMMAND with key"     "IdentitiesOnly" "$out"
check_absent "T11 no BatchMode (passphrase path)" "BatchMode" "$out"
check_absent "T11 no failure"              "FAIL_MSG"        "$out"

# T12: no agent, key file present, PASSPHRASE set but ssh-add fails → error
out=$(run_case "T12" 'GITHUB_SSH_PASSPHRASE=wrong' 1 1 1) || true
check "T12 ssh-add failure → fail msg"  "FAIL_MSG" "$out"

# T13: ssh-add not found, key file present, no passphrase → warn and continue
out=$(run_case "T13" '' missing 0 1) || true
check    "T13 exit 0"          "EXIT:0"      "$out"
check    "T13 warns"           "WARN:"       "$out"

# ===========================================================================
# SECTION 5: No ssh-add binary available
# ===========================================================================
section "ssh-add not available"

# T14: no ssh-add, no agent, key file present → warns, returns 0 with GIT_SSH_COMMAND
out=$(run_case "T14" '' missing 0 1) || true
check    "T14 exit 0"                   "EXIT:0"         "$out"
check    "T14 GIT_SSH_COMMAND set"      "IdentitiesOnly" "$out"
check    "T14 warns about no ssh-add"   "WARN:"          "$out"

# T15: no ssh-add, forwarded agent socket set — can't verify agent so falls through to key-file
# (ssh-add missing means we can't check; this is a reasonable degradation)
out=$(run_case "T15" 'SSH_AUTH_SOCK=/tmp/forwarded.sock' missing 0 1) || true
check    "T15 exit 0"          "EXIT:0"  "$out"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "========================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All $PASS tests passed.${NC}"
  exit 0
else
  echo -e "${RED}$FAIL test(s) failed, $PASS passed.${NC}"
  exit 1
fi
