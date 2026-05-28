# LFRic GCC Environment: Step-by-Step Walkthrough

This document records the complete, hands-on process of installing the LFRic
Apps Spack environment (GNU toolchain) on Isambard 3, written from a real
install attempt. Following these steps from top to bottom will reproduce the
stack from scratch.

---

## Overview

`install.sh` is the single end-to-end driver. It:

1. Verifies the migrated XIOS source against the IPSL GitLab mirror.
2. Clones `lfric_apps`, `lfric_core`, `spack`, and `simit-spack` at pinned
   revisions into `working_dir/`.
3. Patches `simit-spack` package definitions for Spack 1.0 compatibility.
4. Creates and concretizes a Spack environment (`lfric-apps-isambard`).
5. Installs all ~216 packages (including papi, blitz, xios, rose, cylc, psyclone).
6. Builds `lfric_atm` via `local_build.py` (requires SSH access to additional
   private MetOffice repos — see below).

Spack is **not** pre-installed; `install.sh` clones it into `working_dir/spack`.

---

## Prerequisites

### System tools

| Tool | Notes |
|------|-------|
| `git` | any recent version |
| `gcc@12.3.0` | load with `module load gcc-native/12.3` |
| `python3` | 3.x, present on login nodes |
| `bash` | 4+ (login-node default is fine) |

GCC 12.3.0 must be on `PATH` before running the installer so that `spack
compiler find` detects it. The default system GCC on Isambard 3 login nodes is
7.5.0; load the newer one explicitly:

```bash
module load gcc-native/12.3
gcc --version   # should say 12.3.0
```

### Storage

The full install takes about **40–50 GB** of disk. Use `$SCRATCH` — `/home` is
too small. Example:

```bash
export INSTALL_ROOT="$SCRATCH/lfric-install"
mkdir -p "$INSTALL_ROOT"
```

### SSH access to MetOffice GitHub

`install.sh` clones three private MetOffice GitHub repositories
(`lfric_apps`, `lfric_core`, `simit-spack`) and the `lfric_atm` build step
clones further physics repositories (`casim`, `jules`, `socrates`). All of these
require an SSH key that has been:

1. Added to your GitHub account.
2. Authorized for the **MetOffice** organization via SAML SSO.
3. Loaded into a running **SSH agent** before calling `install.sh`.

#### Step 1 — Create an SSH key (skip if you already have one)

```bash
ssh-keygen -t ed25519 -C "your.email@domain"
# Accept the default path (~/.ssh/id_ed25519).
```

#### Step 2 — Start an SSH agent and load the key

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh-add -l   # confirm the key appears
```

#### Step 3 — Add the public key to GitHub

```bash
cat ~/.ssh/id_ed25519.pub   # copy this output
```

Go to <https://github.com/settings/keys>, click **New SSH key**, paste the
public key, and save.

#### Step 4 — Authorize for MetOffice SSO

1. Go to <https://github.com/settings/keys>.
2. Click **Configure SSO** next to the key you added.
3. Click **Authorize** next to **MetOffice**.

#### Step 5 — Verify access

```bash
ssh -T git@github.com
git ls-remote git@github.com:MetOffice/lfric_apps.git HEAD
```

Both should succeed without prompting for a password.

#### Critical: pre-set GIT_SSH_COMMAND

`install.sh` calls `configure_github_ssh()`, which sets `GIT_SSH_COMMAND` to
use the raw key file (`~/.ssh/id_ed25519`) with `-o IdentitiesOnly=yes` — this
**bypasses the agent** and will fail for passphrase-protected keys. To prevent
this, set `GIT_SSH_COMMAND` yourself before calling `install.sh`; the script
only sets it when it is unset:

```bash
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
```

This tells git to use the running agent instead of the raw key file.

---

## Get this repository

```bash
git clone git@github.com:UniExeterRSE/Isambard3-LFRic-Env-Science-Suites.git
cd Isambard3-LFRic-Env-Science-Suites
```

---

## Option A — Install on a login node

```bash
module load gcc-native/12.3
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
cd env_lfric_gcc
WORKING_DIR="$SCRATCH/lfric-install" SPACK_JOBS=8 \
  bash install.sh > "$SCRATCH/lfric-install/install.log" 2>&1 &
```

Follow progress in another terminal:

```bash
tail -f "$SCRATCH/lfric-install/install.log"
```

**Expected duration:** 2–4 hours on a login node. The first Spack install
reaches ~212/216 packages before hitting the papi build failure described
below. The second run (after the fix) takes under 30 minutes to complete the
remaining 4 packages.

---

## Option B — Install on a compute node (recommended)

```bash
module load gcc-native/12.3
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
cd env_lfric_gcc
sbatch compute_node_install.slurm
```

The Slurm job requests 1 node, 144 CPUs, 192 GB RAM, and a 12-hour wall time.
It sets `SPACK_JOBS=32` for parallel compilation. Output goes to
`install-lfric-apps-isambard-env.<JOBID>.out`.

Monitor with:

```bash
squeue --me
tail -f install-lfric-apps-isambard-env.*.out
```

---

## Known issue: papi-5.7.0 build failure on first run

### Symptom

The first `spack install` run fails at package 213/216 with:

```
==> papi: Executing phase: 'build'
==> Error: ProcessError: Command exited with status 2:
make[1]: *** No rule to make target 'no', needed by 'tests'.  Stop.
```

This cascades to: `blitz → xios → lfric-apps-isambard` all skipped.

### Root cause

`papi-5.7.0/package.py` appends `--with-tests=no` to configure options when
the `~example` variant is set. On this version of papi, `--with-tests=` takes
a test-suite name, not a boolean — the Makefile has no `no` target.

`install.sh` includes a `fix_builtin_papi_tests()` function but it runs before
Spack 1.0 downloads its package repository into `~/.spack/package_repos/`, so
it patches the wrong copy on the first run. It self-corrects on subsequent
runs once the directory exists.

### Fix

After the first failed run, find and patch the papi package:

```bash
PAPI_PKG=$(find "$HOME/.spack/package_repos" \
  -path "*/builtin/packages/papi/package.py" -print -quit)
echo "Patching: $PAPI_PKG"
sed -i 's/--with-tests=no/--with-tests=/' "$PAPI_PKG"
grep "with-tests" "$PAPI_PKG"   # should now show: --with-tests=
```

### Re-run after fix

Re-run `install.sh` with the same parameters. It will skip the 212 already-
installed packages and rebuild only papi, blitz, xios, and lfric-apps-isambard:

```bash
module load gcc-native/12.3
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
cd env_lfric_gcc
WORKING_DIR="$SCRATCH/lfric-install" SPACK_JOBS=8 UPDATE_REPOS=0 \
  bash install.sh > "$SCRATCH/lfric-install/install2.log" 2>&1 &
tail -f "$SCRATCH/lfric-install/install2.log"
```

Expected packages built in the second run: `papi → blitz → xios →
lfric-apps-isambard` (the Spack bundle), followed by the `lfric_atm` build.

---

## What install.sh does in detail

### 1. XIOS source verification

The script runs `tests/xios_verification.sh` before touching Spack. It clones
the IPSL GitLab mirror of the former SVN revision 2252 and checks the commit
hash matches `26cc7d88e4f3fa1960461b377d9b8c82550a180e`. If verification fails,
the install aborts.

### 2. Cloning source repositories

All clones land in `WORKING_DIR/` (default: `env_lfric_gcc/working_dir`).

| Repository | Pinned ref | Destination |
|---|---|---|
| `MetOffice/lfric_apps` | `e906813e...` | `working_dir/lfric_apps` |
| `MetOffice/lfric_core` | `da8a9264...` (override) | `working_dir/lfric_core` |
| `spack/spack` | `73eaea13...` | `working_dir/spack` |
| `MetOffice/simit-spack` | `ece4c481...` | `working_dir/simit-spack-main` |

On re-runs, existing clones are kept (`UPDATE_REPOS=0` by default).

### 3. Source patches

Two patches are applied to `lfric_core` for Isambard compatibility:

- **`stop_timing` signature** in `timing_mod.F90`: adds optional
  `timing_section_name` argument.
- **`mpic++.mk` wrapper detection**: normalises `mpic++`/`nvc++` output to
  known compiler IDs.

### 4. Spack bootstrap

```bash
. working_dir/spack/share/spack/setup-env.sh
spack compiler find   # detects system gcc@12.3.0
```

### 5. simit-spack patches

`simit-spack` targets an older Spack API. The installer patches ~30 package
definitions to:

- Add `from spack.package import *` headers.
- Rewrite `spack.pkg.builtin.*` import paths to `spack_repo.*`.
- Fix/add definitions for `cylc-flow`, `metomi-rose`, `cylc-rose`,
  `cylc-uiserver`, `py-pyzmq`, `py-graphene`, `py-graphql-core`,
  `py-graphql-relay`, `foxml`, and others.

### 6. Spack environment

The environment manifest `spack-envs/lfric-apps-isambard/spack.yaml` pins:

```yaml
spack:
  concretizer:
    unify: when_possible
  packages:
    all:
      require: ["%gcc@12.3.0"]
      providers:
        mpi: [mpich]
    py-setuptools:
      version: [":79"]
  specs:
    - lfric-apps-isambard
```

The `lfric-apps-isambard` bundle pulls in all LFRic dependencies.

### 7. Concretization and install

```bash
spack -e lfric-apps-isambard concretize -f
spack -e lfric-apps-isambard install -j 1 libxml2   # serial pre-phase
spack -e lfric-apps-isambard install -j 1 yaxt      # serial (race avoidance)
spack -e lfric-apps-isambard install -j $SPACK_JOBS node-js
spack -e lfric-apps-isambard install -j $SPACK_JOBS
```

After a complete second run the environment contains ~216 packages including:

| Package | Installed version |
|---------|------------------|
| mpich | 5.0.1 |
| hdf5 | 1.14.6 |
| netcdf-c | 4.10.0 |
| netcdf-fortran | 4.6.2 |
| xios | 2252 |
| yaxt | 0.11.3 |
| papi | 5.7.0 |
| blitz | 1.0.2 |
| py-psyclone | 3.2.2 |
| metomi-rose | 2.5.1 |
| cylc-flow | 8.6.2 |
| cylc-rose | 1.7.0 |
| cylc-uiserver | 1.8.3 |

### 8. Build lfric_atm

With the Spack environment loaded, `local_build.py` is invoked:

```bash
python local_build.py lfric_atm \
    -c $WORKING_DIR/lfric_core \
    -w $WORKING_DIR/lfric_apps/applications/lfric_atm/working \
    -j 8 \
    -t build \
    -u meto-spice
```

**Important:** the build extracts additional physics source code from private
MetOffice repositories (`casim`, `jules`, `socrates`) via SSH. This requires a
live SSH agent with your MetOffice-authorized key loaded. If the agent is not
available, the build fails at the "Extracting UM physics" step with:

```
git@github.com: Permission denied (publickey).
RuntimeError: The command ['git', '-C', '...', 'fetch', 'origin', '2025.12.1'] failed
```

Ensure `ssh-add -l` shows your key before running install.sh.

---

## Activating the environment in a new session

After a successful install, source `activate.sh` at the start of every new
session before using rose, cylc, or building LFRic:

```bash
SPACK_DIR="$SCRATCH/lfric-install/spack" \
  source env_lfric_gcc/activate.sh
```

Verify the environment is loaded:

```bash
rose --version      # rose 2.5.1
cylc --version      # 8.6.2
psyclone --version  # PSyclone version: 3.2.2
```

`activate.sh` does the following:

1. Sources `working_dir/spack/share/spack/setup-env.sh`.
2. Activates the `lfric-apps-isambard` Spack environment.
3. Loads rose, cylc, psyclone, and supporting packages onto `PATH`.
4. Sets `SHUMLIB_ROOT`, `LDFLAGS`, `LD_LIBRARY_PATH` for shumlib.
5. Points `FC`, `MPIFC`, `F90`, `F77`, `LDMPI` at `mpif90` from MPICH.
6. Creates/updates `~/.cylc/flow/global.cylc` with a run-directory symlink
   under `/projects/u35v/$USER/cylc-run`.
7. Writes `~/.cylc/flow/platforms.d/isambard3.cylc` with a Slurm platform
   definition.

Override `SPACK_DIR` and `WORKING_DIR` if you installed to a non-default path:

```bash
export SPACK_DIR="$SCRATCH/lfric-install/spack"
export WORKING_DIR="$SCRATCH/lfric-install"
source env_lfric_gcc/activate.sh
```

---

## Environment validation (no build)

To check that rose and cylc are accessible without triggering a full install:

```bash
./env_lfric_gcc/verification.sh > verification.log 2>&1
```

---

## Cylc GUI

```bash
cylc gui --no-browser
```

Open the printed URL in a browser, or forward the port via SSH if working
remotely.

---

## Common overrides

Set these as environment variables before running `install.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `WORKING_DIR` | `env_lfric_gcc/working_dir` | Where clones and Spack live |
| `SPACK_JOBS` | `2` | Parallel Spack install jobs |
| `MAKE_JOBS` | `8` | Parallel make jobs for lfric_atm build |
| `UPDATE_REPOS` | `0` | Set to `1` to pull latest on existing clones |
| `USE_GITHUB_SSH` | `1` | `0` to use HTTPS + `GITHUB_TOKEN` |
| `GITHUB_SSH_KEY` | `~/.ssh/id_ed25519` | Path to your SSH key |
| `GITHUB_SSH_PASSPHRASE` | _(empty)_ | Passphrase for non-interactive Slurm jobs |
| `COMPILER_SPEC` | `gcc@12.3.0` | Spack compiler spec |
| `LFRIC_APPS_REF` | `e906813e...` | `lfric_apps` git commit |
| `SPACK_REF` | `73eaea13...` | Spack git commit |
| `SIMIT_SPACK_REF` | `ece4c481...` | `simit-spack` git commit |
| `REGEN_ENV` | `0` | Set to `1` to delete and recreate `spack.yaml` |
| `RUN_ROSE_CYLC` | `1` | Set to `0` to skip rose/cylc checks |
| `EXIT_ON_ERROR` | `0` | Set to `1` to exit the shell on failure |

---

## Troubleshooting

### SSH key not found

```
ERROR: SSH key not found at /home/.../.ssh/id_ed25519
```

Either generate a key with `ssh-keygen -t ed25519` or set:

```bash
export GITHUB_SSH_KEY=/path/to/your/key
```

### Git clone fails with "Permission denied (publickey)"

If git clone fails for lfric_apps or lfric_core, install.sh may be bypassing
your SSH agent. Pre-set `GIT_SSH_COMMAND` before calling install.sh:

```bash
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
```

### lfric_atm physics extraction fails (casim/jules/socrates)

The `extract_science.py` step clones additional private MetOffice physics
repos. This requires SSH access with MetOffice SSO authorization. Check:

```bash
ssh-add -l   # your key must appear here
git ls-remote git@github.com:MetOffice/casim.git HEAD
```

For non-interactive Slurm jobs, set `GITHUB_SSH_PASSPHRASE` before submitting
so that install.sh can start its own agent automatically.

### papi-5.7.0 build failure

See the dedicated section above. Short version: after the first failed run,
run:

```bash
PAPI_PKG=$(find "$HOME/.spack/package_repos" \
  -path "*/builtin/packages/papi/package.py" -print -quit)
sed -i 's/--with-tests=no/--with-tests=/' "$PAPI_PKG"
```

Then re-run install.sh.

### simit-spack clone fails (403 / access denied)

Your GitHub account does not have access to `MetOffice/simit-spack`. Request
access via the Met Office, or check that your SSH key is authorized for
MetOffice SSO.

### Compiler not found

```
WARN: compiler gcc@12.3.0 not found by Spack
```

Load the GCC 12 module before running the installer:

```bash
module load gcc-native/12.3
```

### Spack concretize fails with openmpi

The installer detects openmpi in the concretized spec and re-concretizes with
`--fresh` to force `mpich`. If it still appears, check that `spack.yaml` has:

```yaml
packages:
  all:
    providers:
      mpi: [mpich]
```

### XIOS verification fails

The IPSL GitLab mirror must be at commit
`26cc7d88e4f3fa1960461b377d9b8c82550a180e` on branch `XIOS2`. If the mirror
has changed, override:

```bash
export XIOS_GIT_COMMIT=<new-commit-hash>
export XIOS_SVN_REVISION=2252
./install.sh
```

### Cylc run directory mkdir fails (Permission denied on /projects/u35v)

`activate.sh` tries to create `$CYLC_RUN_BASE` which defaults to
`/projects/u35v/$USER/cylc-run`. If that path is not writable, set a custom
base before sourcing:

```bash
export CYLC_RUN_BASE="$SCRATCH/cylc-run"
source env_lfric_gcc/activate.sh
```

### View regeneration fails

If `spack env view regenerate` leaves a `._view` directory behind:

```bash
rm -rf "$WORKING_DIR/spack/var/spack/environments/lfric-apps-isambard/.spack-env/._view"
spack -e lfric-apps-isambard env view regenerate
```
