# LFRic GCC Environment: Step-by-Step Walkthrough

This document is a record of what was actually done to install the environment,
written after a real install attempt on Isambard 3. Accompany this with
`walkthrough.sh`, which is the minimal reproduction script derived from this
experience (skipping the trial-and-error).

---

## Overview

`install.sh` is the end-to-end driver. It:

1. Verifies the migrated XIOS source against the IPSL GitLab mirror.
2. Clones `lfric_apps`, `lfric_core`, `spack`, and `simit-spack` at pinned
   revisions into `WORKING_DIR/`.
3. Patches `simit-spack` package definitions (~30 files) for Spack 1.0
   compatibility.
4. Creates and concretizes a Spack environment (`lfric-apps-isambard`).
5. Installs all ~216 packages.
6. Builds `lfric_atm` from source (requires SSH to additional private repos).

Spack itself is **not** pre-installed. `install.sh` clones it into
`WORKING_DIR/spack` at a pinned commit.

---

## What this install produces

After a complete run, `activate.sh` gives:

```
rose 2.5.1
cylc 8.6.2
PSyclone version: 3.2.2
```

Key library versions installed:

| Package | Version |
|---------|---------|
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

Disk usage: ~7.5 GB in `WORKING_DIR`.

---

## Prerequisites

### Modules

GCC 12.3.0 must be on `PATH`. The default system GCC on Isambard 3 login nodes
is 7.5.0; load the correct version first:

```bash
module load gcc-native/12.3
gcc --version   # must say 12.3.0
```

`spack compiler find` runs inside `install.sh` and must detect `gcc@12.3.0`.
If the module is not loaded beforehand, the install will warn and either use
the wrong compiler or abort.

### SSH access to MetOffice GitHub

`install.sh` clones three private MetOffice repositories:

- `MetOffice/lfric_apps`
- `MetOffice/lfric_core`
- `MetOffice/simit-spack`

The `lfric_atm` build step additionally clones:

- `MetOffice/casim`
- `MetOffice/jules`
- `MetOffice/socrates`

All of these require an SSH key that is both added to your GitHub account and
authorized for the MetOffice organization via SAML SSO.

**Verify your access before starting:**

```bash
ssh-add -l              # your key must appear here
git ls-remote git@github.com:MetOffice/lfric_apps.git HEAD
```

Both must succeed. If `ssh-add -l` shows no keys, load one:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

If `git ls-remote` fails with "Repository not found" or a 403, your key has
not been authorized for MetOffice SSO. Go to GitHub → Settings → SSH and GPG
keys → Configure SSO → Authorize for MetOffice.

#### Critical: GIT_SSH_COMMAND must use the agent

`install.sh` calls `configure_github_ssh()` which, when `GIT_SSH_COMMAND` is
unset, builds:

```
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes
```

This bypasses the SSH agent and reads the key file directly. It works only if
the key has no passphrase. For a passphrase-protected key the clone fails with
"Permission denied (publickey)".

The function only sets `GIT_SSH_COMMAND` if the variable is **unset or empty**,
so pre-setting it prevents the override:

```bash
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
```

This command (without `-i` or `-o IdentitiesOnly`) lets SSH try the agent
first and fall back to default key files. The four cases:

| Key has passphrase | SSH agent loaded | Works with pre-set command? |
|--------------------|------------------|-----------------------------|
| No | No | Yes — SSH reads `~/.ssh/id_ed25519` directly |
| No | Yes | Yes — SSH uses agent |
| Yes | Yes | Yes — SSH uses agent |
| Yes | No | No — needs `GITHUB_SSH_PASSPHRASE` (see below) |

For unattended Slurm jobs with a passphrase-protected key:

```bash
export GITHUB_SSH_PASSPHRASE="your-passphrase"
# install.sh then starts its own agent and loads the key
```

#### HTTPS alternative

Set `USE_GITHUB_SSH=0` and `GITHUB_TOKEN=<token>`. The token is required
because all MetOffice repos are private — HTTPS cloning of private repos needs
a credential. SSH uses the key for authentication, so `GITHUB_TOKEN` is not
needed when using SSH.

### Storage

Use `$SCRATCH`; `/home` is too small. A complete install uses ~7.5 GB.

```bash
export WORKING_DIR="$SCRATCH/lfric-install"
mkdir -p "$WORKING_DIR"
```

---

## Running the install

The install was performed on a **login node** (not a compute node) with
`SPACK_JOBS=8`. On a login node the install takes 2–4 hours; on a compute node
with `SPACK_JOBS=32` it is faster.

```bash
# From the repo root:
module load gcc-native/12.3
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
export WORKING_DIR="$SCRATCH/lfric-install"

cd env_lfric_gcc
SPACK_JOBS=8 MAKE_JOBS=8 bash install.sh \
  > "$WORKING_DIR/install.log" 2>&1 &

tail -f "$WORKING_DIR/install.log"
```

### What install.sh does step by step

**1. XIOS verification**

Before cloning anything, the script runs `tests/xios_verification.sh`. It
clones the IPSL GitLab mirror and checks the commit hash matches
`26cc7d88e4f3fa1960461b377d9b8c82550a180e` (former SVN revision 2252). If the
hash doesn't match, the install aborts.

**2. Source clones**

| Repository | Ref | Destination |
|---|---|---|
| `MetOffice/lfric_apps` | `e906813e...` | `WORKING_DIR/lfric_apps` |
| `MetOffice/lfric_core` | read from `lfric_apps/dependencies.yaml`, then overridden to `da8a9264...` | `WORKING_DIR/lfric_core` |
| `spack/spack` | `73eaea13...` | `WORKING_DIR/spack` |
| `MetOffice/simit-spack` | `ece4c481...` | `WORKING_DIR/simit-spack-main` |

The `lfric_core` ref is read from `lfric_apps/dependencies.yaml`, but then
unconditionally overridden by `LFRIC_CORE_REF_OVERRIDE` (hardcoded in
install.sh). The override exists because the ref in `dependencies.yaml` points
to a commit that has a compile-time mismatch on Isambard 3 (see patch below).

On re-runs, existing clone directories are kept unchanged (`UPDATE_REPOS=0` by
default).

**3. lfric_core patches**

Two patches are applied to `lfric_core` using sed/perl string substitution
(not `.patch` files). They are idempotent — each checks whether the change is
already present before applying.

- **`stop_timing` signature** (`infrastructure/source/utilities/timing_mod.F90`):
  inserts `character(*), intent(in), optional :: timing_section_name` into the
  `stop_timing` subroutine argument list to fix a compile-time interface
  mismatch on Isambard 3.
- **`mpic++.mk` wrapper detection** (`infrastructure/build/cxx/mpic++.mk`):
  rewrites the file to normalise `mpic++`/`nvc++` wrapper output to known
  compiler IDs (`g++`, `nvc++`, etc.) so the build system picks the right C++
  flags.

These patches break if the exact lines they target change upstream; they are
survivable maintenance items rather than design features.

**4. Spack bootstrap**

```bash
. WORKING_DIR/spack/share/spack/setup-env.sh
spack compiler find   # detects gcc@12.3.0
```

Spack 1.0 fetches its package definitions from
`https://github.com/spack/spack-packages` into
`~/.spack/package_repos/<hash>/` during concretize (not during bootstrap).
This matters for the papi fix below.

**5. simit-spack patches**

`simit-spack` targets an older Spack API. About 30 package files are patched
by sed and Python string manipulation:

- `from spack.package import *` headers added where missing.
- Import paths rewritten from `spack.pkg.builtin.*` to `spack_repo.*`.
- Several package definitions (`cylc-flow`, `metomi-rose`, `cylc-rose`,
  `cylc-uiserver`, `py-pyzmq`, `py-graphene`, `py-graphql-core`,
  `py-graphql-relay`, `foxml`, and others) rewritten to fix version
  constraints, missing dependencies, or broken install hooks.

Like the lfric_core patches, these are text-substitution rather than
version-controlled diffs, so they are sensitive to upstream API changes in
simit-spack or Spack itself.

**6. Spack environment**

The manifest `spack-envs/lfric-apps-isambard/spack.yaml` is written/updated:

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

The `lfric-apps-isambard` bundle (local package repo) declares all LFRic
runtime and build dependencies.

**7. Concretize and install**

```bash
spack -e lfric-apps-isambard concretize -f
spack -e lfric-apps-isambard install -j 1 libxml2
spack -e lfric-apps-isambard install -j 1 yaxt
spack -e lfric-apps-isambard install -j $SPACK_JOBS node-js
spack -e lfric-apps-isambard install -j $SPACK_JOBS
```

Spack's install is **genuinely incremental**: each package is stored at a
content-addressed path (hash of spec + dependencies). Installed packages are
recorded in `WORKING_DIR/spack/var/spack/db/`. On re-runs, any already-built
hash is skipped outright, not just by directory existence check.

`libxml2` and `yaxt` are installed serially first to avoid known race
conditions with parallel builds.

**8. lfric_atm build**

```bash
python local_build.py lfric_atm \
    -c $WORKING_DIR/lfric_core \
    -w $WORKING_DIR/lfric_apps/applications/lfric_atm/working/build_lfric_atm \
    -j 8 -t build -u meto-spice
```

The `-u meto-spice` (UM_FCM_TARGET_PLATFORM) tells the build system to include
Met Office physics packages (casim, jules, socrates). These are cloned from
private MetOffice GitHub repos via SSH during the build. A live SSH agent with
a MetOffice-authorized key is required at this point too.

---

## What actually happened during this install

### First run failed at papi

The install got to package 213/216 then failed with:

```
==> papi: Executing phase: 'build'
make[1]: *** No rule to make target 'no', needed by 'tests'.  Stop.
==> Error: ProcessError: Command exited with status 2
```

`papi-5.7.0/package.py` appends `--with-tests=no` to configure options. This
version of papi's Makefile interprets `--with-tests=` as a test-suite name, so
`no` is treated as a target name that doesn't exist.

`install.sh` has `fix_builtin_papi_tests()` for exactly this, but on a fresh
install Spack downloads its package definitions into `~/.spack/package_repos/`
during `spack concretize`, which runs *after* the fix was attempted. The first
run log confirmed:

```
WARN: unable to locate builtin repo root for https://github.com/spack/spack-packages.git.
WARN: builtin repo dir not available; skipping builtin repo fixes.
```

After the first failed run, the correct `papi/package.py` was visible in
`~/.spack/package_repos/` and was patched manually:

```bash
PAPI_PKG=$(find "$HOME/.spack/package_repos" \
  -path "*/builtin/packages/papi/package.py" -print -quit)
sed -i 's/--with-tests=no/--with-tests=/' "$PAPI_PKG"
```

**This bug is now fixed in `install.sh`**: a second BUILTIN_REPO_DIR scan
runs after `spack concretize`, so the papi fix is applied before any package
builds. A manual workaround should not be needed on future runs from scratch.

### Second run succeeded for Spack

Re-running `install.sh` with `UPDATE_REPOS=0` skipped the 212 already-built
packages (Spack's incremental behaviour) and rebuilt only:

```
papi → blitz → xios → lfric-apps-isambard (Spack bundle)
```

All 216 packages installed successfully.

### lfric_atm build failed (no SSH agent)

The build reached "Extracting UM physics" then failed:

```
RuntimeError: The command ['git', '-C', '...', 'fetch', 'origin', '2025.12.1'] failed
git@github.com: Permission denied (publickey).
```

The `extract_science.py` script clones casim, jules, and socrates. At this
point in the session there was no SSH agent running. The Spack environment
itself was complete and functional regardless of this failure.

---

## Activating the environment

After a successful Spack install (even if lfric_atm was not built), source
`activate.sh`:

```bash
SPACK_DIR="$SCRATCH/lfric-install/spack" \
  source env_lfric_gcc/activate.sh
```

Verify:

```bash
rose --version      # rose 2.5.1
cylc --version      # 8.6.2
psyclone --version  # PSyclone version: 3.2.2
```

`activate.sh` does the following:

1. Sources `WORKING_DIR/spack/share/spack/setup-env.sh`.
2. Activates the `lfric-apps-isambard` environment.
3. Loads rose, cylc, psyclone, and supporting packages onto `PATH`.
4. Sets `SHUMLIB_ROOT`, `LDFLAGS`, `LD_LIBRARY_PATH`.
5. Points `FC`, `MPIFC`, `F90`, `F77`, `LDMPI` at `mpif90` from MPICH.
6. Creates/updates `~/.cylc/flow/global.cylc` with a run-directory entry.
7. Writes `~/.cylc/flow/platforms.d/isambard3.cylc` (Slurm platform definition).

The Cylc run directory defaults to `/projects/u35v/$USER/cylc-run`. If that
path is not writable, set before sourcing:

```bash
export CYLC_RUN_BASE="$SCRATCH/cylc-run"
source env_lfric_gcc/activate.sh
```

---

## Compute node install (recommended for speed)

Submit from the `env_lfric_gcc/` directory with the agent exported:

```bash
module load gcc-native/12.3
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
sbatch compute_node_install.slurm
```

`compute_node_install.slurm` sets `SPACK_JOBS=32`, requests 144 CPUs, 192 GB
RAM, and a 12-hour wall time. Output goes to
`install-lfric-apps-isambard-env.<JOBID>.out`.

For the lfric_atm build step, the job also needs SSH access to MetOffice
physics repos. Export `GITHUB_SSH_PASSPHRASE` to let install.sh start its own
agent in the job:

```bash
export GITHUB_SSH_PASSPHRASE="your-passphrase"
sbatch --export=ALL compute_node_install.slurm
```

---

## Common overrides

| Variable | Default | Purpose |
|---|---|---|
| `WORKING_DIR` | `env_lfric_gcc/working_dir` | Where clones and Spack live |
| `SPACK_JOBS` | `2` | Parallel Spack install jobs |
| `MAKE_JOBS` | `8` | Parallel make jobs for lfric_atm |
| `UPDATE_REPOS` | `0` | Set to `1` to pull/reset existing clones |
| `USE_GITHUB_SSH` | `1` | `0` for HTTPS with `GITHUB_TOKEN` |
| `GITHUB_SSH_KEY` | `~/.ssh/id_ed25519` | Path to SSH key |
| `GITHUB_SSH_PASSPHRASE` | _(empty)_ | Passphrase for batch jobs |
| `COMPILER_SPEC` | `gcc@12.3.0` | Spack compiler spec |
| `REGEN_ENV` | `0` | Set to `1` to delete and recreate `spack.yaml` |

---

## Troubleshooting

Issues actually encountered during this install are marked **(encountered)**.
Others are documented for completeness but were not hit.

### papi-5.7.0 build failure — **(encountered, now fixed in install.sh)**

**Symptom:**

```
make[1]: *** No rule to make target 'no', needed by 'tests'.  Stop.
```

**Resolution:** The bug in `install.sh` that caused the papi fix to be skipped
on first run has been fixed (post-concretize re-scan of `~/.spack/package_repos`).
If for any reason it still occurs, the manual workaround is:

```bash
PAPI_PKG=$(find "$HOME/.spack/package_repos" \
  -path "*/builtin/packages/papi/package.py" -print -quit)
sed -i 's/--with-tests=no/--with-tests=/' "$PAPI_PKG"
# Then re-run install.sh
```

### lfric_atm physics extraction fails — **(encountered)**

**Symptom:**

```
git@github.com: Permission denied (publickey).
RuntimeError: The command ['git', '-C', '...', 'fetch', 'origin', '2025.12.1'] failed
```

**Cause:** The lfric_atm build clones casim, jules, and socrates. No SSH agent
was running at the time.

**Resolution:** Ensure `ssh-add -l` shows a loaded key before running
install.sh. The Spack environment is complete regardless; only the lfric_atm
binary is missing.

### Cylc run directory mkdir fails — **(encountered)**

**Symptom:**

```
mkdir: cannot create directory '/projects/u35v': Permission denied
```

**Cause:** activate.sh tries to create the default Cylc run location. The
environment still activates and rose/cylc are usable.

**Resolution:**

```bash
export CYLC_RUN_BASE="$SCRATCH/cylc-run"
source env_lfric_gcc/activate.sh
```

### GIT_SSH_COMMAND bypasses agent — hypothetical for users with passphrase

Without pre-setting `GIT_SSH_COMMAND`, install.sh uses the key file directly.
For passphrase-protected keys without an agent this fails. Pre-set:

```bash
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
```

### Compiler not found — hypothetical

```
WARN: compiler gcc@12.3.0 not found by Spack
```

```bash
module load gcc-native/12.3
```

### Spack concretize includes openmpi — hypothetical

The installer detects this and re-concretizes with `--fresh`. If still present,
check that `spack.yaml` has `providers: mpi: [mpich]`.

### XIOS verification fails — hypothetical

Override the expected commit:

```bash
export XIOS_GIT_COMMIT=<new-hash>
./install.sh
```

### View regeneration fails — hypothetical

```bash
rm -rf "$WORKING_DIR/spack/var/spack/environments/lfric-apps-isambard/.spack-env/._view"
spack -e lfric-apps-isambard env view regenerate
```
