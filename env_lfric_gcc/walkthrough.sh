#!/usr/bin/env bash
# walkthrough.sh — minimal reproduction of the steps in walkthrough.md.
#
# Usage:
#   bash env_lfric_gcc/walkthrough.sh
#
# Override the install location:
#   WORKING_DIR=/path/to/dir bash env_lfric_gcc/walkthrough.sh
#
# The script stops on the first unrecoverable error. Each numbered section
# corresponds to a section in walkthrough.md.
#
# Note on install.sh exit behaviour: install.sh always exits 0 by default
# (EXIT_ON_ERROR=0) to keep interactive shells open on failure. We therefore
# run it with EXIT_ON_ERROR=1 so genuine errors propagate. The one expected
# non-zero exit is the lfric_atm build, which requires SSH access to private
# MetOffice physics repos (casim, jules, socrates). That failure is handled
# explicitly below; the Spack environment is complete regardless.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Configuration
#
#    WORKING_DIR: where all sources, Spack, and built packages land (~7.5 GB).
#    Defaults to $SCRATCH/lfric-install. Override on the command line:
#      WORKING_DIR=/my/path bash walkthrough.sh
# ---------------------------------------------------------------------------

WORKING_DIR="${WORKING_DIR:-$SCRATCH/lfric-install}"
SPACK_JOBS="${SPACK_JOBS:-8}"
MAKE_JOBS="${MAKE_JOBS:-8}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "Install directory: $WORKING_DIR"
echo "Spack jobs:        $SPACK_JOBS"

# ---------------------------------------------------------------------------
# 1. Load GCC 12.3.0
#
#    The login-node default is 7.5.0. spack compiler find must see 12.3.0.
# ---------------------------------------------------------------------------

echo ""
echo "=== 1. Load gcc-native/12.3 ==="
module load gcc-native/12.3
gcc --version | head -1   # must say 12.3.0

# ---------------------------------------------------------------------------
# 2. Verify SSH agent and MetOffice GitHub access
#
#    install.sh clones MetOffice/lfric_apps, lfric_core, simit-spack.
#    The lfric_atm build step also clones casim, jules, socrates.
#    All require an SSH key in a running agent, authorized for MetOffice SSO.
#
#    If ssh-add -l shows no keys:
#      eval "$(ssh-agent -s)"
#      ssh-add ~/.ssh/id_ed25519
#
#    If git ls-remote fails with "Repository not found" or 403, the key has
#    not been authorized for MetOffice SSO via GitHub Settings → SSH keys →
#    Configure SSO → Authorize for MetOffice.
# ---------------------------------------------------------------------------

echo ""
echo "=== 2. Verify SSH agent and MetOffice access ==="
if ! ssh-add -l > /dev/null 2>&1; then
  echo "ERROR: No SSH keys loaded in agent." >&2
  echo "  Run: eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519" >&2
  exit 1
fi
ssh-add -l
git ls-remote git@github.com:MetOffice/lfric_apps.git HEAD

# ---------------------------------------------------------------------------
# 3. Pre-set GIT_SSH_COMMAND to use the agent
#
#    install.sh's configure_github_ssh() builds:
#      ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes
#    when GIT_SSH_COMMAND is unset. That bypasses the agent and reads the key
#    file directly — failing for passphrase-protected keys.
#
#    Pre-setting the variable prevents the override. Without -i or
#    -o IdentitiesOnly, SSH tries the agent first and falls back to default
#    key files, covering all cases where the agent is loaded.
# ---------------------------------------------------------------------------

echo ""
echo "=== 3. Pre-set GIT_SSH_COMMAND ==="
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# ---------------------------------------------------------------------------
# 4. Create the working directory
# ---------------------------------------------------------------------------

echo ""
echo "=== 4. Create working directory ==="
mkdir -p "$WORKING_DIR"

# ---------------------------------------------------------------------------
# 5. Run install.sh
#
#    EXIT_ON_ERROR=1 makes install.sh exit non-zero on failure. By default
#    it exits 0 to keep interactive shells open, which prevents set -e from
#    catching problems in this script.
#
#    The lfric_atm build (called inside install.sh) requires SSH access to
#    private MetOffice physics repos (casim, jules, socrates) and commonly
#    fails when no SSH agent is available for those repos, or when the key
#    lacks MetOffice SSO authorization for those specific repos. That failure
#    does NOT mean the Spack environment failed; we check them separately.
#
#    On a login node with SPACK_JOBS=8, the first fresh run takes 2-4 hours.
#    Re-runs skip already-built Spack packages (content-addressed hashes).
#    UPDATE_REPOS=0 keeps existing source clones untouched.
# ---------------------------------------------------------------------------

echo ""
echo "=== 5. Run install.sh ==="
cd "$SCRIPT_DIR"

SPACK_INSTALL_OK=0
WORKING_DIR="$WORKING_DIR" SPACK_JOBS="$SPACK_JOBS" MAKE_JOBS="$MAKE_JOBS" \
  UPDATE_REPOS=0 EXIT_ON_ERROR=1 \
  bash install.sh 2>&1 | tee "$WORKING_DIR/install.log" \
  && SPACK_INSTALL_OK=1 || true   # capture exit without stopping the script

# Check that Spack itself completed, regardless of whether lfric_atm built.
SETUP_ENV="$WORKING_DIR/spack/share/spack/setup-env.sh"
if [ ! -f "$SETUP_ENV" ]; then
  echo "" >&2
  echo "ERROR: Spack was not installed — $SETUP_ENV not found." >&2
  echo "  The install failed before Spack was cloned. Check:" >&2
  echo "    tail -50 $WORKING_DIR/install.log" >&2
  exit 1
fi

# Source Spack so we can query the environment.
# shellcheck source=/dev/null
. "$SETUP_ENV"

if ! spack -e lfric-apps-isambard find metomi-rose cylc-flow xios > /dev/null 2>&1; then
  echo "" >&2
  echo "ERROR: Spack environment incomplete — metomi-rose, cylc-flow, or xios missing." >&2
  echo "  Check: spack -e lfric-apps-isambard find" >&2
  echo "  Log:   $WORKING_DIR/install.log" >&2
  exit 1
fi

if [ "$SPACK_INSTALL_OK" -eq 0 ]; then
  echo ""
  echo "NOTE: install.sh exited non-zero. Spack environment is complete." >&2
  echo "  The lfric_atm build likely failed because the SSH agent did not have" >&2
  echo "  access to MetOffice/casim, MetOffice/jules, or MetOffice/socrates." >&2
  echo "  The Spack environment (rose, cylc, psyclone, xios, etc.) is usable." >&2
fi

# ---------------------------------------------------------------------------
# 6. Verify the Spack environment
# ---------------------------------------------------------------------------

echo ""
echo "=== 6. Verify Spack environment ==="
spack -e lfric-apps-isambard find | grep -E "(cylc-flow|metomi-rose|xios|papi|blitz)"

# ---------------------------------------------------------------------------
# 7. Activate and verify tool versions
#
#    CYLC_RUN_BASE overrides the default /projects/u35v/$USER/cylc-run.
#    SPACK_DIR and WORKING_DIR are exported so activate.sh finds them.
# ---------------------------------------------------------------------------

echo ""
echo "=== 7. Activate environment and verify versions ==="
export CYLC_RUN_BASE="${CYLC_RUN_BASE:-$SCRATCH/cylc-run}"
export SPACK_DIR="$WORKING_DIR/spack"
export WORKING_DIR

# shellcheck source=/dev/null
source "$SCRIPT_DIR/activate.sh"

rose --version
cylc --version
psyclone --version

echo ""
echo "=== Done ==="
echo "To activate this environment in future sessions:"
echo "  SPACK_DIR=$WORKING_DIR/spack WORKING_DIR=$WORKING_DIR \\"
echo "    source $SCRIPT_DIR/activate.sh"
