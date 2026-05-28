#!/usr/bin/env bash
# walkthrough.sh — minimal reproduction of the steps in walkthrough.md.
#
# This script encodes exactly what was done to produce a working install,
# stripping trial-and-error. It is meant to be read and run step by step,
# not sourced as a library.
#
# Usage:
#   bash walkthrough.sh
#
# The script will stop on the first error (set -e). Each numbered section
# corresponds to a section in walkthrough.md.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Configuration — edit these if your paths differ
# ---------------------------------------------------------------------------

WORKING_DIR="${WORKING_DIR:-$SCRATCH/lfric-install}"
SPACK_JOBS="${SPACK_JOBS:-8}"
MAKE_JOBS="${MAKE_JOBS:-8}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Load GCC 12.3.0
#
#    The default system GCC on Isambard 3 login nodes is 7.5.0.
#    spack compiler find must detect gcc@12.3.0 or the install will warn and
#    may use the wrong compiler.
# ---------------------------------------------------------------------------

echo "=== 1. Load gcc-native/12.3 ==="
module load gcc-native/12.3
gcc --version | head -1   # must say 12.3.0

# ---------------------------------------------------------------------------
# 2. Verify SSH access to MetOffice GitHub
#
#    install.sh clones MetOffice/lfric_apps, lfric_core, and simit-spack.
#    The lfric_atm build step also clones casim, jules, socrates.
#    All require an SSH key authorized for MetOffice SSO.
#
#    ssh-add -l must show at least one loaded key.
#    git ls-remote must succeed without prompting.
# ---------------------------------------------------------------------------

echo "=== 2. Verify SSH agent and MetOffice access ==="
ssh-add -l   # fails with exit code 1 if no agent or no keys loaded
git ls-remote git@github.com:MetOffice/lfric_apps.git HEAD

# ---------------------------------------------------------------------------
# 3. Pre-set GIT_SSH_COMMAND so install.sh uses the agent
#
#    install.sh's configure_github_ssh() sets GIT_SSH_COMMAND to:
#      ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes
#    This bypasses the agent and reads the key file directly, which fails for
#    passphrase-protected keys.
#
#    The function only sets GIT_SSH_COMMAND if it is unset, so we pre-set it
#    to let SSH use the agent instead.
# ---------------------------------------------------------------------------

echo "=== 3. Pre-set GIT_SSH_COMMAND ==="
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# ---------------------------------------------------------------------------
# 4. Create the working directory
#
#    The full install uses ~7.5 GB. $SCRATCH is used because /home is too
#    small on Isambard 3.
# ---------------------------------------------------------------------------

echo "=== 4. Create working directory: $WORKING_DIR ==="
mkdir -p "$WORKING_DIR"

# ---------------------------------------------------------------------------
# 5. Run install.sh
#
#    WORKING_DIR points the installer to $SCRATCH.
#    SPACK_JOBS controls parallel package builds.
#    UPDATE_REPOS=0 keeps existing clones on re-runs (idempotent).
#
#    The install is run in the foreground so errors are visible immediately.
#    On a login node with SPACK_JOBS=8 this takes 2-4 hours.
#    Redirect to a log file and tail it in another terminal if preferred.
#
#    Note on idempotency: Spack stores each built package at a hash-addressed
#    path in WORKING_DIR/spack/var/spack/db/ and
#    WORKING_DIR/spack/opt/spack/. Re-running install.sh will skip any
#    already-built hashes; it does not re-run make for them.
#    Source-repo clones are kept as-is when UPDATE_REPOS=0.
# ---------------------------------------------------------------------------

echo "=== 5. Run install.sh ==="
cd "$SCRIPT_DIR"
WORKING_DIR="$WORKING_DIR" SPACK_JOBS="$SPACK_JOBS" MAKE_JOBS="$MAKE_JOBS" \
  UPDATE_REPOS=0 \
  bash install.sh 2>&1 | tee "$WORKING_DIR/install.log"

# ---------------------------------------------------------------------------
# 6. Verify the Spack environment
#
#    Even if the lfric_atm build fails (it needs a live SSH agent for
#    casim/jules/socrates), the Spack environment is complete.
# ---------------------------------------------------------------------------

echo "=== 6. Verify Spack environment ==="
SPACK_DIR="$WORKING_DIR/spack"
. "$SPACK_DIR/share/spack/setup-env.sh"
spack -e lfric-apps-isambard find | grep -E "(cylc-flow|metomi-rose|xios|papi|blitz)"

# ---------------------------------------------------------------------------
# 7. Activate and check tool versions
#
#    activate.sh sources Spack, activates the environment, and sets up PATH,
#    FC, MPIFC, SHUMLIB_ROOT, and Cylc configuration.
#
#    CYLC_RUN_BASE overrides the default /projects/u35v/$USER/cylc-run, which
#    may not be writable.
# ---------------------------------------------------------------------------

echo "=== 7. Activate environment and verify versions ==="
export CYLC_RUN_BASE="$SCRATCH/cylc-run"
export SPACK_DIR="$WORKING_DIR/spack"
export WORKING_DIR
# shellcheck source=/dev/null
source "$SCRIPT_DIR/activate.sh"

rose --version
cylc --version
psyclone --version
