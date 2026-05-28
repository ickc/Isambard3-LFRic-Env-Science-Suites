#!/usr/bin/env bash

# LFRic Apps end-to-end driver for Isambard-style Spack installs.
# - Clones repos (lfric_apps, lfric_core, simit-spack)
# - Prepares Spack and an environment based on the lfric-apps-isambard package
# - Builds lfric_atm via local_build.py, runs the example, then runs rose/cylc checks

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKING_DIR="${WORKING_DIR:-$ROOT_DIR/working_dir}"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
IS_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  IS_SOURCED=1
fi

fail() {
  echo "ERROR: $*" >&2
  return 1
}

info() {
  echo "INFO: $*"
}

warn() {
  echo "WARN: $*" >&2
}

configure_github_ssh() {
  local key="${GITHUB_SSH_KEY:-$HOME/.ssh/id_ed25519}"
  local tmp_ssh_askpass=""

  # Check for a working SSH agent FIRST; this covers agent-forwarding where the
  # private key file lives only on the originating machine, not the HPC node.
  if command -v ssh-add >/dev/null 2>&1 && [ -n "${SSH_AUTH_SOCK:-}" ]; then
    if ssh-add -l >/dev/null 2>&1; then
      # Agent has keys loaded; ensure first-time clones don't stall on host-key prompts.
      if [ -z "${GIT_SSH_COMMAND:-}" ]; then
        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
        export GIT_SSH_COMMAND
      fi
      return 0
    fi
    warn "SSH_AUTH_SOCK is set but unusable; will try key-file or fresh agent."
    unset SSH_AUTH_SOCK SSH_AGENT_PID
  fi

  # If the caller pre-set GIT_SSH_COMMAND, trust it completely.
  # We don't know which key file to add to an agent, so stop here.
  if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    return 0
  fi

  # No working agent and no pre-set command: we need a local key file.
  if [ ! -f "$key" ]; then
    fail "SSH key not found at $key and no usable SSH agent."
    return 1
  fi

  GIT_SSH_COMMAND="ssh -i \"$key\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  if [ -z "${GITHUB_SSH_PASSPHRASE:-}" ]; then
    GIT_SSH_COMMAND="$GIT_SSH_COMMAND -o BatchMode=yes"
  fi
  export GIT_SSH_COMMAND

  if ! command -v ssh-add >/dev/null 2>&1; then
    warn "ssh-add not found; Git will use GIT_SSH_COMMAND with $key."
    return 0
  fi

  # No working agent — prompt for passphrase on interactive terminals.
  if [ -z "${GITHUB_SSH_PASSPHRASE:-}" ] && [ -t 0 ] && [ -t 1 ]; then
    printf 'Enter passphrase for %s: ' "$key" >/dev/tty
    IFS= read -r -s GITHUB_SSH_PASSPHRASE </dev/tty || true
    printf '\n' >/dev/tty
    export GITHUB_SSH_PASSPHRASE
  fi

  if [ -z "${GITHUB_SSH_PASSPHRASE:-}" ]; then
    warn "No usable ssh-agent; continuing with direct key-file SSH. Set GITHUB_SSH_PASSPHRASE for encrypted keys in batch jobs."
    return 0
  fi

  eval "$(ssh-agent -s)" >/dev/null
  tmp_ssh_askpass="$(mktemp)"
  cat > "$tmp_ssh_askpass" <<'SSH_ASKPASS_EOF'
#!/usr/bin/env bash
printf '%s\n' "${GITHUB_SSH_PASSPHRASE}"
SSH_ASKPASS_EOF
  chmod 700 "$tmp_ssh_askpass"
  export SSH_ASKPASS="$tmp_ssh_askpass"
  export SSH_ASKPASS_REQUIRE=force

  if command -v setsid >/dev/null 2>&1; then
    setsid ssh-add "$key" </dev/null
  else
    ssh-add "$key"
  fi
  local status=$?
  rm -f "$tmp_ssh_askpass"
  unset SSH_ASKPASS SSH_ASKPASS_REQUIRE

  if [ "$status" -ne 0 ]; then
    fail "Failed to add SSH key $key."
    return 1
  fi
  return 0
}

run_xios_verification() {
  local verify_script="${XIOS_VERIFY_SCRIPT:-$ROOT_DIR/../tests/xios_verification.sh}"
  local verify_workdir="${XIOS_VERIFY_WORKDIR:-$WORKING_DIR/xios-verification}"

  if [ ! -f "$verify_script" ]; then
    fail "XIOS verification script not found at $verify_script."
    return 1
  fi

  info "Verifying migrated XIOS source before Spack concretization."
  if ! XIOS_GIT_URL="${XIOS_GIT_URL:-https://gitlab.in2p3.fr/ipsl/projets/xios-projects/xios.git}" \
      XIOS_GIT_BRANCH="${XIOS_GIT_BRANCH:-XIOS2}" \
      XIOS_GIT_COMMIT="${XIOS_GIT_COMMIT:-26cc7d88e4f3fa1960461b377d9b8c82550a180e}" \
      XIOS_SVN_REVISION="${XIOS_SVN_REVISION:-2252}" \
      XIOS_WORKDIR="$verify_workdir" \
      KEEP_XIOS_VERIFICATION_CLONE="${KEEP_XIOS_VERIFICATION_CLONE:-0}" \
      bash "$verify_script"; then
    fail "XIOS source verification failed."
    return 1
  fi
  return 0
}

patch_stop_timing_signature() {
  local timing_file="$WORKING_DIR/lfric_core/infrastructure/source/utilities/timing_mod.F90"
  if [ ! -f "$timing_file" ]; then
    warn "timing_mod.F90 not found at $timing_file; skipping stop_timing patch."
    return 0
  fi
  if grep -q "optional :: timing_section_name" "$timing_file"; then
    return 0
  fi
  if ! perl -0777 -i -pe 's/subroutine stop_timing\(\s*timing_section_handle\s*\)\s*\n\s*implicit none\s*\n\s*integer\(tik\),\s*intent\(in\)\s*::\s*timing_section_handle/subroutine stop_timing( timing_section_handle, timing_section_name )\n\n        implicit none\n\n        integer(tik),  intent(in) :: timing_section_handle\n        character(*),  intent(in), optional :: timing_section_name/s' "$timing_file"; then
    warn "Failed to patch stop_timing signature in $timing_file."
    return 0
  fi
  info "Patched stop_timing signature for compatibility."
  return 0
}

patch_mpicxx_wrapper_detection() {
  local mpicxx_mk="$WORKING_DIR/lfric_core/infrastructure/build/cxx/mpic++.mk"
  if [ ! -f "$mpicxx_mk" ]; then
    warn "mpic++.mk not found at $mpicxx_mk; skipping wrapper patch."
    return 0
  fi
  if grep -q "Normalise wrapper output" "$mpicxx_mk"; then
    return 0
  fi
  cat > "$mpicxx_mk" <<'EOF'
##############################################################################
# (c) Crown copyright 2024 Met Office. All rights reserved.
# The file LICENCE, distributed with this code, contains details of the terms
# under which the code may be used.
##############################################################################

MPIC_COMPILER := $(shell $(CXX) --version                    | awk -F " " 'NR<2 { printf "%s", $$1 }')

# Normalise wrapper output to known compiler ids.
ifneq (,$(findstring g++, $(MPIC_COMPILER)))
  MPIC_COMPILER := g++
endif
ifneq (,$(findstring nvc++, $(MPIC_COMPILER)))
  MPIC_COMPILER := nvc++
endif
ifeq ($(MPIC_COMPILER),PIC_COMPILER)
  MPIC_COMPILER := g++
endif

$(info ** Chosen MPI C++ compiler "$(MPIC_COMPILER)")

ifeq '$(MPIC_COMPILER)' 'g++'
  CXX_COMPILER = g++
else ifeq '$(MPIC_COMPILER)' 'icc'
  CXX_COMPILER = icc
else ifeq '$(MPIC_COMPILER)' 'Cray'
  CXX_COMPILER = craycc
else ifeq '$(MPIC_COMPILER)' 'nvc++'
  CXX_COMPILER = nvc++
else
  $(error Unrecognised mpic++ compiler option: "$(MPIC_COMPILER)")
endif

include $(LFRIC_BUILD)/cxx/$(CXX_COMPILER).mk
EOF
  info "Patched mpic++.mk wrapper detection."
  return 0
}

map_cylc_dep_to_spack() {
  local dep="${1%%==*}"
  case "$dep" in
    aiofiles) echo "py-aiofiles" ;;
    async-timeout) echo "py-async-timeout" ;;
    graphene) echo "py-graphene" ;;
    graphql-core) echo "py-graphql-core" ;;
    graphql-relay) echo "py-graphql-relay" ;;
    graphql) echo "py-graphql-core" ;;
    graphql_relay) echo "py-graphql-relay" ;;
    jinja2) echo "py-jinja2" ;;
    ldap3) echo "py-ldap3" ;;
    rx) echo "py-rx" ;;
    protobuf) echo "py-protobuf" ;;
    promise) echo "py-promise" ;;
    psutil) echo "py-psutil" ;;
    pyuv) echo "py-pyuv" ;;
    packaging) echo "py-packaging" ;;
    python-dateutil) echo "py-python-dateutil" ;;
    dateutil) echo "py-python-dateutil" ;;
    typing-extensions) echo "py-typing-extensions" ;;
    typing_extensions) echo "py-typing-extensions" ;;
    requests) echo "py-requests" ;;
    sqlalchemy) echo "py-sqlalchemy" ;;
    keyring) echo "py-keyring" ;;
    metomi.isodatetime|metomi.isodatetime.*) echo "py-metomi-isodatetime" ;;
    colorama) echo "py-colorama" ;;
    ansimarkup) echo "py-ansimarkup" ;;
    urwid) echo "py-urwid" ;;
    pyzmq) echo "py-pyzmq" ;;
    jupyter_server|jupyter-server) echo "py-jupyter-server" ;;
    tornado) echo "py-tornado" ;;
    traitlets) echo "py-traitlets" ;;
    *) return 1 ;;
  esac
}

install_missing_cylc_deps() {
  local output="$1"
  local env_name="${SPACK_ENV:-${ENV_NAME:-}}"
  local missing_deps=()
  local spack_specs=()
  local dep
  local spec

  while IFS= read -r dep; do
    [ -n "$dep" ] && missing_deps+=("$dep")
  done < <(printf '%s\n' "$output" | sed -n "s/.*The '\\([^']\\+\\)' distribution was not found.*/\\1/p")

  while IFS= read -r dep; do
    [ -n "$dep" ] && missing_deps+=("$dep")
  done < <(printf '%s\n' "$output" | sed -n "s/.*No module named '\\([^']\\+\\)'.*/\\1/p")

  if [ "${#missing_deps[@]}" -eq 0 ]; then
    return 1
  fi

  for dep in "${missing_deps[@]}"; do
    if spec="$(map_cylc_dep_to_spack "$dep")"; then
      spack_specs+=("$spec")
    else
      echo "WARN: No Spack mapping for missing cylc dependency '$dep'." >&2
    fi
  done

  if [ "${#spack_specs[@]}" -eq 0 ]; then
    return 1
  fi

  if ! command -v spack >/dev/null 2>&1; then
    return 1
  fi
  if [ -z "$env_name" ]; then
    echo "WARN: Spack environment is not active; cannot auto-install cylc deps." >&2
    return 1
  fi

  local added_any=0
  for spec in "${spack_specs[@]}"; do
    if spack -e "$env_name" find "$spec" >/dev/null 2>&1; then
      continue
    fi
    info "Auto-installing missing cylc dependency: $spec"
    if ! spack -e "$env_name" add "$spec"; then
      return 1
    fi
    added_any=1
  done

  if [ "$added_any" -eq 0 ]; then
    return 1
  fi

  if ! spack -e "$env_name" concretize -f; then
    return 1
  fi
  if ! spack -e "$env_name" install -j "${SPACK_JOBS:-1}"; then
    return 1
  fi
  return 0
}

print_rose_cylc_info() {
  local env_name="${ENV_NAME:-lfric-apps-isambard}"
  local spack_dir="${SPACK_DIR:-$HOME/lfric_spack_package_rose_cylc/working_dir/spack}"
  local spack_setup="$spack_dir/share/spack/setup-env.sh"

  if [ -f "$spack_setup" ]; then
    . "$spack_setup"
    if command -v spack >/dev/null 2>&1; then
      info "Using local Spack at $spack_dir"
      if spack env activate -p "$env_name" >/dev/null 2>&1; then
        spack find metomi-rose cylc-flow cylc-rose cylc-uiserver || warn "Required specs not found in $env_name"
        spack load metomi-rose cylc-flow cylc-rose cylc-uiserver >/dev/null 2>&1 || \
          warn "Unable to load rose/cylc from Spack environment $env_name"
        view_dir="$spack_dir/var/spack/environments/$env_name/.spack-env/view"
        if [ -d "$view_dir/bin" ]; then
          export PATH="$view_dir/bin:$PATH"
        fi
      else
        warn "Unable to activate Spack environment $env_name"
      fi
    else
      warn "Spack setup script found but spack command unavailable"
    fi
  else
    warn "Spack setup not found at $spack_setup"
  fi

  command -v rose >/dev/null 2>&1 && info "rose path: $(command -v rose)" || warn "rose not found on PATH"
  command -v cylc >/dev/null 2>&1 && info "cylc path: $(command -v cylc)" || warn "cylc not found on PATH"
  if command -v rose >/dev/null 2>&1; then
    echo "ROSE VERSION: $(rose --version)" || warn "rose --version failed"
  else
    warn "rose --version failed"
  fi
  if command -v cylc >/dev/null 2>&1; then
    echo "CYLC VERSION: $(cylc --version)" || warn "cylc --version failed"
  else
    warn "cylc --version failed"
  fi

  if [ "${EXTENDED_TOOL_VALIDATION:-1}" = "1" ]; then
    info "Extended rose/cylc validation on this machine."
    info "Hostname: $(hostname -f 2>/dev/null || hostname)"
    info "rose path: $(command -v rose || echo "not found")"
    info "cylc path: $(command -v cylc || echo "not found")"
    if command -v rose >/dev/null 2>&1; then
      echo "ROSE VERSION: $(rose --version)" || warn "rose --version failed."
    fi
    if command -v cylc >/dev/null 2>&1; then
      echo "CYLC VERSION: $(cylc --version)" || warn "cylc --version failed."
    fi
    cat <<'EOF'
INFO: Suggested manual checks:
  rose --version
  cylc --version
  cylc validate --help
  rose app-run --help
  spack -e lfric-apps-isambard find metomi-rose cylc-flow cylc-rose cylc-uiserver
EOF
  fi
}

repo_url() {
  printf '%s%s.git' "$GITHUB_BASE" "$1"
}

rewrite_github_to_https() {
  local file="$1"
  if [ -f "$file" ]; then
    sed -i 's|git@github.com:|https://github.com/|g' "$file"
  fi
}

rewrite_github_to_ssh() {
  local file="$1"
  if [ -f "$file" ]; then
    sed -i 's|https://github.com/|git@github.com:|g' "$file"
  fi
}

clone_or_update() {
  local name="$1"
  local url="$2"
  local ref="${3:-}"
  local depth="${4:-}"
  local path="$WORKING_DIR/$name"
  local ref_is_commit=0
  local clone_depth="$depth"

  if [ -n "$ref" ] && [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    ref_is_commit=1
    clone_depth=""
  fi

  if [ -d "$path/.git" ]; then
    info "$name already present."
    if [ "$UPDATE_REPOS" = "1" ]; then
      git -C "$path" fetch --tags --prune
      if [ "$ref_is_commit" -eq 1 ] \
        && git -C "$path" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
        if ! git -C "$path" fetch --unshallow && ! git -C "$path" fetch --depth=1000000; then
          fail "Failed to unshallow $name to reach ref $ref."
          return 1
        fi
      fi
      if [ -n "$ref" ]; then
        if ! git -C "$path" checkout "$ref"; then
          fail "Failed to checkout $name ref $ref."
          return 1
        fi
      fi
      git -C "$path" pull --ff-only || true
    fi
    return 0
  fi

  if [ -e "$path" ]; then
    fail "$path exists but is not a git repository."
    return 1
  fi

  if [ -n "$ref" ] && git ls-remote --exit-code --heads --tags "$url" "$ref" >/dev/null 2>&1; then
    local clone_cmd=(git clone --branch "$ref")
    if [ -n "$clone_depth" ]; then
      clone_cmd+=(--depth "$clone_depth")
    fi
    clone_cmd+=("$url" "$path")
    if ! "${clone_cmd[@]}"; then
      return 1
    fi
  else
    local clone_cmd=(git clone)
    if [ -n "$clone_depth" ]; then
      clone_cmd+=(--depth "$clone_depth")
    fi
    clone_cmd+=("$url" "$path")
    if ! "${clone_cmd[@]}"; then
      return 1
    fi
    if [ -n "$ref" ]; then
      if ! git -C "$path" checkout "$ref"; then
        return 1
      fi
    fi
  fi
}

clone_lfric_core() {
  local ref="$1"
  local url
  url="$(repo_url "MetOffice/lfric_core")"
  local path="$WORKING_DIR/lfric_core"

  if [ -d "$path/.git" ]; then
    info "lfric_core already present."
    if [ "$UPDATE_REPOS" = "1" ]; then
      git -C "$path" fetch --tags --prune
      git -C "$path" checkout "$ref" || true
      git -C "$path" pull --ff-only || true
    fi
    return 0
  fi

  if [ -e "$path" ]; then
    fail "$path exists but is not a git repository."
    return 1
  fi

  if git ls-remote --exit-code --heads --tags "$url" "$ref" >/dev/null 2>&1; then
    if ! git clone --branch "$ref" ${LFRIC_CORE_DEPTH:+--depth "$LFRIC_CORE_DEPTH"} "$url" "$path"; then
      return 1
    fi
  else
    if ! git clone "$url" "$path"; then
      return 1
    fi
    if ! git -C "$path" checkout "$ref"; then
      return 1
    fi
  fi
}

ensure_builtin_repo() {
  local branch=""
  local raw_path=""
  local repo_root=""
  local builtin_repo_dir=""

  spack repo list >/dev/null 2>&1 || true
  raw_path="$(spack repo list 2>/dev/null | awk '$2=="builtin"{print ($4!="" ? $4 : $3); exit}')"
  raw_path="${raw_path%:}"
  if [ -z "$raw_path" ]; then
    echo "WARN: builtin repo not found in Spack config." >&2
    return 0
  fi

  if [ -d "$raw_path/.git" ]; then
    repo_root="$raw_path"
  else
    repo_root="$(git -C "$raw_path" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
    echo "WARN: unable to locate builtin repo root for $raw_path." >&2
    return 0
  fi

  branch="$(spack config get repos | awk '/builtin:/{found=1} found && $1=="branch:"{print $2; exit}')"
  if [ -z "$branch" ]; then
    branch="develop"
  fi

  if ! git -C "$repo_root" fetch origin "$branch"; then
    fail "Failed to fetch spack-packages branch $branch."
    return 1
  fi

  if [ ! -f "$repo_root/spack-repo-index.yaml" ] \
    || [ ! -f "$repo_root/repos/spack_repo/builtin/packages/singularityce/package.py" ]; then
    if ! git -C "$repo_root" archive --format=tar "origin/$branch" \
      spack-repo-index.yaml repos/spack_repo/builtin \
      | tar -x -C "$repo_root"; then
      fail "Unable to refresh builtin repo contents from $branch."
      return 1
    fi
  fi

  builtin_repo_dir="$repo_root/repos/spack_repo/builtin"
  BUILTIN_REPO_ROOT="$repo_root"
  BUILTIN_REPO_DIR="$builtin_repo_dir"
}

fix_builtin_papi_rocp_sdk() {
  local repo_dir="$1"
  local raw_path=""
  local pkg=""
  if [ -z "$repo_dir" ]; then
    raw_path="$(spack repo list 2>/dev/null | awk '$2=="builtin"{print ($4!="" ? $4 : $3); exit}')"
    raw_path="${raw_path%:}"
    if [ -z "$raw_path" ]; then
      return 0
    fi
    if [ -d "$raw_path/packages" ]; then
      repo_dir="$raw_path"
    else
      repo_dir="$(git -C "$raw_path" rev-parse --show-toplevel 2>/dev/null || true)/repos/spack_repo/builtin"
    fi
  fi
  pkg="$repo_dir/packages/papi/package.py"
  patch_papi_rocp_sdk "$pkg"
}

fix_builtin_papi_tests() {
  local repo_dir="$1"
  local raw_path=""
  local pkg=""
  if [ -z "$repo_dir" ]; then
    raw_path="$(spack repo list 2>/dev/null | awk '$2=="builtin"{print ($4!="" ? $4 : $3); exit}')"
    raw_path="${raw_path%:}"
    if [ -z "$raw_path" ]; then
      return 0
    fi
    if [ -d "$raw_path/packages" ]; then
      repo_dir="$raw_path"
    else
      repo_dir="$(git -C "$raw_path" rev-parse --show-toplevel 2>/dev/null || true)/repos/spack_repo/builtin"
    fi
  fi
  pkg="$repo_dir/packages/papi/package.py"
  if [ ! -f "$pkg" ]; then
    return 0
  fi
  if grep -q 'with-tests=' "$pkg"; then
    sed -i 's/--with-tests=no/--with-tests=/' "$pkg"
  fi
}

patch_papi_rocp_sdk() {
  local pkg="$1"
  if [ -z "$pkg" ] || [ ! -f "$pkg" ]; then
    return 0
  fi
  if grep -q "x in spec.variants and spec.variants\\[x\\].value" "$pkg"; then
    return 0
  fi
  sed -i \
    "s/lambda x: spec\\.variants\\[x\\]\\.value/lambda x: x in spec.variants and spec.variants[x].value/" \
    "$pkg"
}

fix_papi_rocp_sdk_in_cache() {
  local search_root="${SPACK_USER_CONFIG_PATH:-$HOME/.spack}"
  local spack_dir="${SPACK_DIR:-}"
  local candidates=()
  local pkg=""

  if [ -n "$spack_dir" ] && [ -f "$spack_dir/var/spack/repos/builtin/packages/papi/package.py" ]; then
    candidates+=("$spack_dir/var/spack/repos/builtin/packages/papi/package.py")
  fi

  if [ -d "$search_root/package_repos" ]; then
    local search_candidates=()
    if command -v rg >/dev/null 2>&1; then
      mapfile -t search_candidates < <(
        rg --files -g "package.py" "$search_root/package_repos" 2>/dev/null \
          | rg "/papi/package.py$"
      )
    else
      mapfile -t search_candidates < <(find "$search_root/package_repos" -path "*/papi/package.py" 2>/dev/null)
    fi
    if [ "${#search_candidates[@]}" -gt 0 ]; then
      candidates+=("${search_candidates[@]}")
    fi
  fi

  if [ "${#candidates[@]}" -eq 0 ]; then
    return 0
  fi

  local -A seen=()
  for pkg in "${candidates[@]}"; do
    if [ -n "${seen[$pkg]:-}" ]; then
      continue
    fi
    seen[$pkg]=1
    patch_papi_rocp_sdk "$pkg"
  done
}

fix_build_system_imports() {
  local repo_dir="$1"
  local matches=()
  local has_build_systems=0
  if [ -d "$SPACK_DIR/lib/spack/spack/build_systems" ]; then
    has_build_systems=1
  fi
  local bs_entries=(
    "PythonPackage:python"
    "PerlPackage:perl"
    "CMakePackage:cmake"
    "AutotoolsPackage:autotools"
    "MakefilePackage:makefile"
  )
  if command -v rg >/dev/null 2>&1; then
    mapfile -t matches < <(rg -l "Package|spack\\.build_systems" "$repo_dir")
  else
    mapfile -t matches < <(grep -rl -e "Package" -e "spack.build_systems" "$repo_dir")
  fi
  for pkg in "${matches[@]}"; do
    for entry in "${bs_entries[@]}"; do
      local klass="${entry%%:*}"
      local module="${entry##*:}"
      if [ "$has_build_systems" -eq 1 ]; then
        if grep -q "from spack.package import ${klass}" "$pkg"; then
          sed -i "s|from spack.package import ${klass}|from spack.package import *\\nfrom spack.build_systems.${module} import ${klass}|" "$pkg"
        fi
        if grep -q "from spack.build_systems.${module} import ${klass}" "$pkg"; then
          if ! grep -q "from spack.package import \\*" "$pkg"; then
            sed -i "0,/from spack.build_systems.${module} import ${klass}/s//from spack.package import *\\nfrom spack.build_systems.${module} import ${klass}/" "$pkg"
          fi
        fi
      else
        sed -i "/from spack.build_systems.${module} import ${klass}/d" "$pkg"
        if grep -q "from spack.package import ${klass}" "$pkg"; then
          sed -i "s|from spack.package import ${klass}|from spack.package import *|" "$pkg"
        fi
      fi
    done
  done
}

fix_spack_pkg_builtin_imports() {
  local repo_dir="$1"
  local files=()
  if command -v rg >/dev/null 2>&1; then
    mapfile -t files < <(rg -l "spack\\.pkg\\.builtin" "$repo_dir")
  else
    mapfile -t files < <(grep -rl "spack.pkg.builtin" "$repo_dir")
  fi
  for pkg_file in "${files[@]}"; do
    local names=()
    if command -v rg >/dev/null 2>&1; then
      mapfile -t names < <(rg -o "spack\\.pkg\\.builtin\\.[A-Za-z0-9_-]+" "$pkg_file" | sed "s/.*builtin\\.//")
    else
      mapfile -t names < <(grep -o "spack.pkg.builtin.[A-Za-z0-9_-]*" "$pkg_file" | sed "s/.*builtin\\.//")
    fi
    for pkg_name in "${names[@]}"; do
      local pkg_mod="${pkg_name//-/_}"
      sed -i "s|spack.pkg.builtin.${pkg_name}|spack_repo.builtin.packages.${pkg_mod}.package|g" "$pkg_file"
    done
  done
}

ensure_spack_package_imports() {
  local repo_dir="$1"
  local files=()
  if command -v rg >/dev/null 2>&1; then
    mapfile -t files < <(rg --files -g "package.py" "$repo_dir")
  else
    mapfile -t files < <(find "$repo_dir" -name package.py)
  fi
  for pkg_file in "${files[@]}"; do
    if grep -q "from spack.package import \\*" "$pkg_file"; then
      continue
    fi
    if ! grep -Eq "(^|[^A-Za-z_])(version|depends_on|variant|extends|conflicts|resource|patch|provides|maintainers)\\s*\\(" "$pkg_file"; then
      continue
    fi
    if head -n 1 "$pkg_file" | grep -q "^#!"; then
      {
        read -r first_line
        echo "$first_line"
        echo "from spack.package import *"
        cat
      } < "$pkg_file" > "${pkg_file}.tmp" && mv "${pkg_file}.tmp" "$pkg_file"
    else
      {
        echo "from spack.package import *"
        cat "$pkg_file"
      } > "${pkg_file}.tmp" && mv "${pkg_file}.tmp" "$pkg_file"
    fi
  done
}

ensure_repo_api_v1() {
  local repo_yaml="$1"
  if [ ! -f "$repo_yaml" ]; then
    return 0
  fi
  if grep -q "^[[:space:]]*api:" "$repo_yaml"; then
    return 0
  fi
  local tmp_file
  tmp_file="$(mktemp)"
  awk '{
    print $0
    if ($0 ~ /^[[:space:]]*repo:[[:space:]]*$/) {
      print "  api: v1.0"
    }
  }' "$repo_yaml" > "$tmp_file"
  mv "$tmp_file" "$repo_yaml"
}

patch_simit_rose_picker() {
  local pkg_file
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/rose-picker/package.py"
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  if [ ! -f "$pkg_file" ]; then
    fail "rose-picker package not found at $pkg_file; cannot patch GitHub URL."
    return 1
  fi
  if ! grep -q "https://github.com/MetOffice/rose_picker.git" "$pkg_file" \
    || grep -q "self.spec.prefix.lib.python" "$pkg_file"; then
    info "Patching rose-picker package definition to use GitHub mirror."
  else
    return 0
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class RosePicker(Package):

    """rose_picker - utility for LFRic."""

    homepage = "https://github.com/MetOffice/rose_picker"
    git = "https://github.com/MetOffice/rose_picker.git"

    version("2.0.0", tag="git_migration", preferred=True)

    depends_on("python@3.11:", type=("build", "run"))
    depends_on("py-pip", type="build")

    def install(self, spec, prefix):
        python = spec["python"].command
        python("-m", "pip", "install", "--no-deps", "--prefix", prefix, ".")

    def setup_run_environment(self, env):
        python = self.spec["python"]
        pyver = python.version.up_to(2)
        env.prepend_path(
            "PYTHONPATH",
            join_path(self.spec.prefix, "lib", "python{0}".format(pyver), "site-packages"),
        )
EOF
}

patch_simit_cylc_flow() {
  local pkg_file
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/cylc-flow/package.py"
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  if [ ! -f "$pkg_file" ]; then
    fail "cylc-flow package not found at $pkg_file; cannot patch."
    return 1
  fi
  info "Patching cylc-flow package definition to avoid metadata generation failures."
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class CylcFlow(PythonPackage):

    """Cylc - workflow engine that orchestrates cycling workflows very efficiently.

    Cylc is used in production weather, climate, and environmental
    forecasting on HPC, but is not specialized to those domains.
    """

    homepage = "https://cylc.github.io/"
    pypi = "cylc-flow/cylc_flow-8.6.2.tar.gz"

    version(
        "8.6.2",
        sha256="66d0f4ce8e2fa4ac2f0a29e184ea534a2f4814dd2a116c8d721f11fd6a161f21",
        preferred=True,
    )
    version(
        "8.1.0",
        sha256="19e1e510178d2ea6210bbd5e56dbe30c5066665564b46a6faad134dede831487",
    )
    version(
        "8.0.4",
        sha256="866f39bec037805690ce582a2cb0ccdbf646ea46a4c691c9cb1a1ea13f649a7a",
    )
    version(
        "8.0.1",
        sha256="dfccc1290390f226fe44253bcb0caf65aa175e2f7d165793083feed1f8ea0a7f",
    )
    version(
        "8.0.0",
        sha256="5a4b4bb4e101d65c5c397e6ab810d21b90c8774dca3a9e708de96b22e43d0cfe",
    )
    version(
        "8.0rc2",
        sha256="a8887fcf8f014e2665c9ebbe8a596a71e383e23859fa485860469b7f59fafd2f",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-flit-core", type="build")
    depends_on("py-setuptools-scm", type="build")
    depends_on("py-wheel", type="build")
    depends_on("graphviz")
    depends_on("py-ansimarkup")
    depends_on("py-colorama")
    depends_on("py-graphql-core")
    depends_on("py-graphene")
    depends_on("py-jinja2@3.0.3")
    depends_on("py-metomi-isodatetime")
    depends_on("py-packaging")
    depends_on("py-protobuf")
    depends_on("py-psutil")
    depends_on("py-urwid")
    depends_on("py-pyzmq")
EOF
}

patch_simit_py_ansimarkup() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-ansimarkup"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    if grep -q "7b3e3d93fecc5b64d23a6e8eb96dbc8b0b576a211829d948afb397d241a8c51b" "$pkg_file" \
      && grep -q "py-colorama" "$pkg_file"; then
      return 0
    fi
  fi
  info "Adding py-ansimarkup package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyAnsimarkup(PythonPackage):

    """Convert text into colored ANSI text using markup tags."""

    pypi = "ansimarkup/ansimarkup-2.1.0.tar.gz"

    version(
        "2.1.0",
        sha256="7b3e3d93fecc5b64d23a6e8eb96dbc8b0b576a211829d948afb397d241a8c51b",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-hatchling", type="build")
    depends_on("py-colorama")
EOF
}

patch_simit_py_aiofiles() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-aiofiles"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ] && grep -q "py-poetry-core" "$pkg_file"; then
    return 0
  fi
  info "Adding py-aiofiles package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyAiofiles(PythonPackage):

    """File support for asyncio."""

    pypi = "aiofiles/aiofiles-0.7.0.tar.gz"

    version(
        "0.7.0",
        sha256="a1c4fc9b2ff81568c83e21392a82f344ea9d23da906e4f6a52662764545e19d4",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-poetry-core", type="build")
EOF
}

patch_simit_py_async_timeout() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-async-timeout"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-async-timeout package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyAsyncTimeout(PythonPackage):

    """Timeout context manager for asyncio programs."""

    pypi = "async-timeout/async-timeout-4.0.3.tar.gz"

    version(
        "4.0.3",
        sha256="4640d96be84d82d02ed59ea2b7105a0f7b33abe8703703cd0ab0bf87c427522f",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-flit-core", type="build")
EOF
}

patch_simit_py_poetry_core() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-poetry-core"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ] && grep -q 'version("2.3.0"' "$pkg_file"; then
    return 0
  fi
  info "Ensuring py-poetry-core package is updated in simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyPoetryCore(PythonPackage):

    """PEP 517 build backend for Poetry."""

    pypi = "poetry-core/poetry_core-2.3.0.tar.gz"

    version(
        "2.3.0",
        sha256="f6da8f021fe380d8c9716085f4dcc5d26a5120a2452e077196333892af5de307",
    )

    depends_on("python@3.10:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_colorama() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-colorama"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-colorama package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyColorama(PythonPackage):

    """Cross-platform colored terminal text."""

    pypi = "colorama/colorama-0.4.6.tar.gz"

    version(
        "0.4.6",
        sha256="08695f5cb7ed6e0531a20572697297273c47b8cae5a63ffc6d6ed5c201be6e44",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-hatchling", type="build")
EOF
}

patch_simit_py_graphene() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-graphene"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-graphene package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyGraphene(PythonPackage):

    """GraphQL framework for Python."""

    pypi = "graphene/graphene-3.4.3.tar.gz"

    version(
        "3.4.3",
        sha256="2a3786948ce75fe7e078443d37f609cbe5bb36ad8d6b828740ad3b95ed1a0aaa",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-graphql-core")
    depends_on("py-graphql-relay")
    depends_on("py-python-dateutil")
    depends_on("py-typing-extensions")
EOF
}

patch_simit_py_six() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-six"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-six package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PySix(PythonPackage):

    """Python 2 and 3 compatibility utilities."""

    pypi = "six/six-1.16.0.tar.gz"

    version(
        "1.16.0",
        sha256="1e61c37477a1626458e36f7b1d82aa5c9b094fa4802892072e49de9c60c4c926",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_graphql_core() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-graphql-core"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-graphql-core package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyGraphqlCore(PythonPackage):

    """GraphQL core library."""

    pypi = "graphql-core/graphql_core-3.2.7.tar.gz"

    version(
        "3.2.7",
        sha256="27b6904bdd3b43f2a0556dad5d579bdfdeab1f38e8e8788e555bdcb586a6f62c",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-poetry-core", type="build")
    depends_on("py-typing-extensions")
EOF
}

patch_simit_py_graphql_relay() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-graphql-relay"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-graphql-relay package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyGraphqlRelay(PythonPackage):

    """Relay library for GraphQL."""

    pypi = "graphql-relay/graphql-relay-3.2.0.tar.gz"

    version(
        "3.2.0",
        sha256="1ff1c51298356e481a0be009ccdff249832ce53f30559c1338f22a0e0d17250c",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-poetry-core", type="build")
    depends_on("py-graphql-core")
    depends_on("py-typing-extensions")
EOF
}

patch_simit_py_jsonschema() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-jsonschema"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-jsonschema package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from importlib import import_module

from spack.package import *


jsonschema = import_module("spack_repo.builtin.packages.py_jsonschema.package")


class PyJsonschema(jsonschema.PyJsonschema):

    """An implementation of JSON Schema validation for Python."""

    version(
        "4.17.3",
        sha256="0f864437ab8b6076ba6707453ef8f98a6a0d512a80e93f8abdb676f737ecb60d",
    )
EOF
}

patch_simit_py_psyclone() {
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-psyclone/package.py"
  if [ ! -f "$pkg_file" ]; then
    fail "py-psyclone package not found at $pkg_file."
    return 1
  fi
  info "Relaxing py-jsonschema pin in py-psyclone package."
  PKG_FILE="$pkg_file" python3 - <<'PY'
from pathlib import Path
import os

pkg_file = Path(os.environ["PKG_FILE"])
data = pkg_file.read_text()
old = 'depends_on("py-jsonschema@=4.17.3", type=("build", "run"), when="@2.5.0:")'
new = 'depends_on("py-jsonschema@4.17.3:", type=("build", "run"), when="@2.5.0:")'
if old in data:
    pkg_file.write_text(data.replace(old, new))
elif new not in data:
    raise SystemExit(f"Expected dependency not found in {pkg_file}")
PY
}

patch_simit_py_jupyter_server() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-jupyter-server"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-jupyter-server package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyJupyterServer(PythonPackage):

    """Jupyter Server backend for web applications like JupyterLab."""

    homepage = "https://github.com/jupyter-server/jupyter_server"
    pypi = "jupyter_server/jupyter_server-2.17.0.tar.gz"

    version(
        "2.17.0",
        sha256="c38ea898566964c888b4772ae1ed58eca84592e88251d2cfc4d171f81f7e99d5",
    )
    version(
        "2.14.2",
        sha256="66095021aa9638ced276c248b1d81862e4c50f292d575920bbe960de1c56b12b",
    )

    depends_on("python@3.9:", type=("build", "run"))
    depends_on("py-hatchling@1.11:", type="build")
    depends_on("py-hatch-jupyter-builder@0.8.1:", type="build")
    depends_on("py-pip", type="build")
    depends_on("py-setuptools", type="build")
    depends_on("py-wheel", type="build")

    with default_args(type=("build", "run")):
        depends_on("py-anyio@3.1.0:")
        depends_on("py-argon2-cffi@21.1:")
        depends_on("py-jinja2@3.0.3:")
        depends_on("py-jupyter-client@7.4.4:")
        depends_on("py-jupyter-core@4.12:")
        depends_on("py-jupyter-events@0.11:")
        depends_on("py-jupyter-server-terminals@0.4.4:")
        depends_on("py-nbconvert@6.4.4:")
        depends_on("py-nbformat@5.3:")
        depends_on("py-overrides@5.0:")
        depends_on("py-packaging@22.0:")
        depends_on("py-prometheus-client@0.9:")
        depends_on("py-pyzmq@24:")
        depends_on("py-send2trash@1.8.2:")
        depends_on("py-terminado@0.8.3:")
        depends_on("py-tornado@6.2:")
        depends_on("py-traitlets@5.6:")
        depends_on("py-websocket-client@1.7:")
EOF
}

patch_simit_py_aniso8601() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-aniso8601"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-aniso8601 package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyAniso8601(PythonPackage):

    """Python library for parsing ISO 8601 strings."""

    pypi = "aniso8601/aniso8601-7.0.0.tar.gz"

    version(
        "7.0.0",
        sha256="513d2b6637b7853806ae79ffaca6f3e8754bdd547048f5ccc1420aec4b714f1e",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_pyasn1() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-pyasn1"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-pyasn1 package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyPyasn1(PythonPackage):

    """ASN.1 types and codecs."""

    pypi = "pyasn1/pyasn1-0.6.1.tar.gz"

    version(
        "0.6.1",
        sha256="6f580d2bdd84365380830acf45550f2511469f673cb4a5ae3857a3170128b034",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_pyasn1_modules() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-pyasn1-modules"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ] && grep -q "pyasn1_modules-0.4.1.tar.gz" "$pkg_file"; then
    return 0
  fi
  info "Adding py-pyasn1-modules package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyPyasn1Modules(PythonPackage):

    """ASN.1 modules for pyasn1."""

    pypi = "pyasn1-modules/pyasn1_modules-0.4.1.tar.gz"

    version(
        "0.4.1",
        sha256="c28e2dbf9c06ad61c71a075c7e0f9fd0f1b0bb2d2ad4377f240d33ac2ab60a7c",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-pyasn1")
EOF
}

patch_simit_py_certifi() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-certifi"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-certifi package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyCertifi(PythonPackage):

    """Python package for providing Mozilla's CA Bundle."""

    pypi = "certifi/certifi-2025.1.31.tar.gz"

    version(
        "2025.1.31",
        sha256="3d5da6925056f6f18f119200434a4780a94263f10d1c21d032a6f6b2baa20651",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_charset_normalizer() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-charset-normalizer"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ] && grep -q "charset-normalizer-3.3.2.tar.gz" "$pkg_file"; then
    return 0
  fi
  info "Adding py-charset-normalizer package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyCharsetNormalizer(PythonPackage):

    """Character encoding auto-detection in Python."""

    pypi = "charset-normalizer/charset-normalizer-3.3.2.tar.gz"

    version(
        "3.3.2",
        sha256="f30c3cb33b24454a82faecaf01b19c18562b1e89558fb6c56de4d9118a032fd5",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_idna() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-idna"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ] && grep -q "py-flit-core" "$pkg_file"; then
    return 0
  fi
  info "Adding py-idna package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyIdna(PythonPackage):

    """Internationalized Domain Names in Applications (IDNA)."""

    pypi = "idna/idna-3.7.tar.gz"

    version(
        "3.7",
        sha256="028ff3aadf0609c1fd278d8ea3089299412a7a8b9bd005dd08b9f8285bcb5cfc",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-flit-core", type="build")
EOF
}

patch_simit_py_urllib3() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-urllib3"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ] && grep -q "py-hatchling" "$pkg_file" && grep -q "py-hatch-vcs" "$pkg_file"; then
    return 0
  fi
  info "Adding py-urllib3 package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyUrllib3(PythonPackage):

    """HTTP library with thread-safe connection pooling."""

    pypi = "urllib3/urllib3-2.2.3.tar.gz"

    version(
        "2.2.3",
        sha256="e7d814a81dad81e6caf2ec9fdedb284ecc9c73076b62654547cc64ccdcae26e9",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-hatchling", type="build")
    depends_on("py-hatch-vcs", type="build")
EOF
}

patch_simit_py_greenlet() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-greenlet"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-greenlet package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyGreenlet(PythonPackage):

    """Lightweight in-process concurrent programming."""

    pypi = "greenlet/greenlet-3.1.1.tar.gz"

    version(
        "3.1.1",
        sha256="4ce3ac6cdb6adf7946475d7ef31777c26d94bccc377e070a7986bd2d5c515467",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_protobuf() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-protobuf"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-protobuf package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyProtobuf(PythonPackage):

    """Protocol Buffers implementation in Python."""

    pypi = "protobuf/protobuf-6.33.4.tar.gz"

    version(
        "6.33.4",
        sha256="dc2e61bca3b10470c1912d166fe0af67bfc20eb55971dcef8dfa48ce14f0ed91",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_psutil() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-psutil"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-psutil package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyPsutil(PythonPackage):

    """Cross-platform process and system monitoring for Python."""

    pypi = "psutil/psutil-5.9.8.tar.gz"

    version(
        "5.9.8",
        sha256="6be126e3225486dff286a8fb9a06246a5253f4c7c53b475ea5f5ac934e64194c",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_pyuv() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-pyuv"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-pyuv package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *
from llnl.util.filesystem import filter_file


class PyPyuv(PythonPackage):

    """Python interface to libuv."""

    pypi = "pyuv/pyuv-1.4.0.tar.gz"

    version(
        "1.4.0",
        sha256="caea2004d1125fe17cbde3c211c8abc72844e9b8dd7dfa007711e98fbc96fbc2",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("libuv")

    def patch(self):
        filter_file(
            "Py_REFCNT\\(self\\) = refcnt;",
            "Py_SET_REFCNT(self, refcnt);",
            "src/handle.c",
        )
        filter_file(
            "PyUnicode_EncodeUTF8\\(PyUnicode_AS_UNICODE\\(unicode\\), PyUnicode_GET_SIZE\\(unicode\\), \"surrogateescape\"\\);",
            "PyUnicode_AsEncodedString(unicode, \"utf-8\", \"surrogateescape\");",
            "src/common.c",
        )
EOF
}

patch_simit_py_ldap3() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-ldap3"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-ldap3 package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyLdap3(PythonPackage):

    """A strictly RFC 4510 conforming LDAP V3 pure Python client library."""

    pypi = "ldap3/ldap3-2.9.1.tar.gz"

    version(
        "2.9.1",
        sha256="f3e7fc4718e3f09dda568b57100095e0ce58633bcabbed8667ce3f8fbaa4229f",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-pyasn1")
    depends_on("py-pyasn1-modules")
EOF
}

patch_simit_py_requests() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-requests"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-requests package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyRequests(PythonPackage):

    """Python HTTP for Humans."""

    pypi = "requests/requests-2.32.3.tar.gz"

    version(
        "2.32.3",
        sha256="55365417734eb18255590a9ff9eb97e9e1da868d4ccd6402399eaf68af20a760",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-certifi")
    depends_on("py-charset-normalizer")
    depends_on("py-idna")
    depends_on("py-urllib3")
EOF
}

patch_simit_py_sqlalchemy() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-sqlalchemy"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-sqlalchemy package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PySqlalchemy(PythonPackage):

    """SQL Toolkit and Object Relational Mapper."""

    pypi = "sqlalchemy/sqlalchemy-1.4.54.tar.gz"

    version(
        "1.4.54",
        sha256="4470fbed088c35dc20b78a39aaf4ae54fe81790c783b3264872a0224f437c31a",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-greenlet")
EOF
}

patch_simit_py_metomi_isodatetime() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-metomi-isodatetime"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-metomi-isodatetime package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyMetomiIsodatetime(PythonPackage):

    """Metomi date/time library providing ISO 8601 support."""

    version(
        "3.1.0",
        url="https://files.pythonhosted.org/packages/00/cc/e910e3e8616807dfb9a526e2887623398fee67c987a2112aee103bd120f5/metomi-isodatetime-1!3.1.0.tar.gz",
        sha256="2ec15eb9c323d5debd0678f33af99bc9a91aa0b534ee5f65f3487aed518ebf2d",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_metomi_rose() {
  local pkg_file
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/metomi-rose/package.py"
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  if [ ! -f "$pkg_file" ]; then
    fail "metomi-rose package not found at $pkg_file; cannot patch."
    return 1
  fi
  info "Patching metomi-rose package definition to include runtime dependencies."
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class MetomiRose(PythonPackage):

    """Metomi Rose - configuration and workflow suite."""

    homepage = "https://metomi.github.io/rose/"
    pypi = "metomi-rose/metomi_rose-2.5.1.tar.gz"

    version(
        "2.5.1",
        sha256="02fad351f2356b9d2d25432e5d117baf78d4287b0b680cebe5d836f57d6ad2cc",
        preferred=True,
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-aiofiles")
    depends_on("py-jinja2")
    depends_on("py-keyring")
    depends_on("py-ldap3")
    depends_on("py-metomi-isodatetime")
    depends_on("py-psutil")
    depends_on("py-requests")
    depends_on("py-sqlalchemy@1:1")
EOF
}

patch_simit_cylc_rose() {
  local pkg_file
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/cylc-rose/package.py"
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  if [ ! -f "$pkg_file" ]; then
    fail "cylc-rose package not found at $pkg_file; cannot patch."
    return 1
  fi
  info "Patching cylc-rose package definition to include runtime dependencies."
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class CylcRose(PythonPackage):

    """Rose plugin for Cylc workflow engine."""

    homepage = "https://cylc.github.io/"
    pypi = "cylc-rose/cylc_rose-1.7.0.tar.gz"

    version(
        "1.7.0",
        sha256="e31a9fb68f30113240126d366f868d2e324d63f0584164085c5e31876b97f75a",
        preferred=True,
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("metomi-rose@2.5:2.5")
    depends_on("cylc-flow@8.6:8.6")
    depends_on("py-metomi-isodatetime")
    depends_on("py-ansimarkup")
    depends_on("py-jinja2")
EOF
}

patch_simit_cylc_uiserver() {
  local pkg_file
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/cylc-uiserver/package.py"
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  if [ ! -f "$pkg_file" ]; then
    fail "cylc-uiserver package not found at $pkg_file; cannot patch."
    return 1
  fi
  info "Patching cylc-uiserver package definition to include runtime dependencies."
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class CylcUiserver(PythonPackage):

    """Cylc UI server - provides the Cylc GUI."""

    homepage = "https://cylc.github.io/"
    pypi = "cylc-uiserver/cylc_uiserver-1.8.3.tar.gz"

    version(
        "1.8.3",
        sha256="2f019ac1e6fb78bab612008bc0cc9f2852ce4056d79ef01c46846561b6e7a882",
        preferred=True,
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("cylc-flow@8.6.2:8.6")
    depends_on("py-ansimarkup")
    depends_on("py-graphene")
    depends_on("py-jupyter-server@2.13.0:")
    depends_on("py-packaging")
    depends_on("py-psutil")
    depends_on("py-pyzmq")
    depends_on("py-requests")
    depends_on("py-tornado@6.5:")
    depends_on("py-traitlets@5.2.1:")
EOF
}

patch_simit_py_promise() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-promise"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-promise package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyPromise(PythonPackage):

    """Promise/A+ implementation for Python."""

    pypi = "promise/promise-2.3.tar.gz"

    version(
        "2.3",
        sha256="dfd18337c523ba4b6a58801c164c1904a9d4d1b1747c7d5dbf45b693a49d93d0",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_rx() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-rx"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    return 0
  fi
  info "Adding py-rx package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyRx(PythonPackage):

    """Reactive Extensions for Python."""

    pypi = "Rx/Rx-3.2.0.tar.gz"

    version(
        "3.2.0",
        sha256="b657ca2b45aa485da2f7dcfd09fac2e554f7ac51ff3c2f8f2ff962ecd963d91c",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_urwid() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-urwid"
  pkg_file="$pkg_dir/package.py"
  info "Adding py-urwid package to simit-spack repo."
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyUrwid(PythonPackage):

    """Console user interface library for Python."""

    pypi = "urwid/urwid-3.0.3.tar.gz"

    version(
        "3.0.3",
        sha256="300804dd568cda5aa1c5b204227bd0cfe7a62cef2d00987c5eb2e4e64294ed9b",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
EOF
}

patch_simit_py_pyzmq() {
  local pkg_dir
  local pkg_file
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  pkg_dir="$SIMIT_SPACK_DIR/repos/metoffice/packages/py-pyzmq"
  pkg_file="$pkg_dir/package.py"
  if [ -f "$pkg_file" ]; then
    if grep -q "PYZMQ_USE_BUNDLED" "$pkg_file" && grep -q "depends_on(\"libzmq\")" "$pkg_file"; then
      return 0
    fi
    info "Updating py-pyzmq package definition in simit-spack repo."
  else
    info "Adding py-pyzmq package to simit-spack repo."
  fi
  if ! mkdir -p "$pkg_dir"; then
    fail "Unable to create $pkg_dir."
    return 1
  fi
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PyPyzmq(PythonPackage):

    """Python bindings for ZeroMQ."""

    pypi = "pyzmq/pyzmq-27.1.0.tar.gz"

    version(
        "27.1.0",
        sha256="ac0765e3d44455adb6ddbf4417dcce460fc40a05978c08efdf2948072f6db540",
    )
    version(
        "24.0.1",
        sha256="216f5d7dbb67166759e59b0479bca82b8acf9bed6015b526b8eb10143fb08e77",
    )
    version(
        "22.3.0",
        sha256="8eddc033e716f8c91c6a2112f0a8ebc5e00532b4a6ae1eb0ccc48e027f9c671c",
    )

    depends_on("python@3:")
    depends_on("py-setuptools", type="build")
    depends_on("py-cython", type="build")
    depends_on("py-packaging", type="build")
    depends_on("py-scikit-build-core+pyproject", type="build")
    depends_on("libzmq", type=("build", "link"))

    def setup_build_environment(self, env):
        prefix = self.spec["libzmq"].prefix
        env.set("ZMQ_PREFIX", prefix)
        env.set("ZMQ_DIR", prefix)
        env.set("ZMQ_INCLUDE", prefix.include)
        env.set("ZMQ_LIB", prefix.lib)
        env.set("PYZMQ_USE_BUNDLED", "0")
EOF
}

patch_simit_foxml() {
  local pkg_file
  pkg_file="$SIMIT_SPACK_DIR/repos/metoffice/packages/foxml/package.py"
  if [ -z "$SIMIT_SPACK_DIR" ]; then
    return 0
  fi
  if [ ! -f "$pkg_file" ]; then
    fail "foxml package not found at $pkg_file; cannot patch."
    return 1
  fi
  if grep -q "commit=\"6f60cf178d0776b21406303e91f1e6b42ff0f204\"" "$pkg_file"; then
    return 0
  fi
  info "Patching foxml package definition to use git commit checkout."
  cat > "$pkg_file" <<'EOF'
# Copyright 2013-2022 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class Foxml(CMakePackage):

    """FoX - the Fortan/XML library.

    FoX is an XML library written in Fortran 95. It allows software
    developers to read, write and modify XML documents from Fortran
    applications without the complications of dealing with
    multi-language development. FoX can be freely redistributed as
    part of open source and commercial software packages.
    """

    homepage = "https://github.com/andreww/fox"
    git = "https://github.com/andreww/fox.git"

    version(
        "6f60cf1",
        commit="6f60cf178d0776b21406303e91f1e6b42ff0f204",
        preferred=True,
    )
EOF
}

main() {
  if ! command -v git >/dev/null 2>&1; then
    fail "git is required but not found in PATH."
    return 1
  fi
  if ! command -v awk >/dev/null 2>&1; then
    fail "awk is required but not found in PATH."
    return 1
  fi

  START_DIR="$(pwd)"
  TMP_PYTHON_DIR=""
  TMP_GIT_CONFIG=""
  TMP_GIT_ASKPASS=""
  cleanup() {
    if [ "${FUNCNAME[1]:-}" != "main" ]; then
      return 0
    fi
    if [ -n "$TMP_PYTHON_DIR" ] && [ -d "$TMP_PYTHON_DIR" ]; then
      rm -rf "$TMP_PYTHON_DIR"
    fi
    if [ -n "$TMP_GIT_CONFIG" ] && [ -f "$TMP_GIT_CONFIG" ]; then
      rm -f "$TMP_GIT_CONFIG"
    fi
    if [ -n "$TMP_GIT_ASKPASS" ] && [ -f "$TMP_GIT_ASKPASS" ]; then
      rm -f "$TMP_GIT_ASKPASS"
    fi
    if [ -n "${START_DIR:-}" ]; then
      cd "$START_DIR" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup RETURN

  USE_GITHUB_SSH="${USE_GITHUB_SSH:-1}"
  UPDATE_REPOS="${UPDATE_REPOS:-0}"
  EXIT_ON_ERROR="${EXIT_ON_ERROR:-0}"

  if [ ! -d "$WORKING_DIR" ]; then
    if ! mkdir -p "$WORKING_DIR"; then
      fail "Unable to create working directory $WORKING_DIR."
      return 1
    fi
  fi

  if ! run_xios_verification; then
    return 1
  fi

  GITHUB_SSH_KEY="${GITHUB_SSH_KEY:-$HOME/.ssh/id_ed25519}"
  GITHUB_SSH_PASSPHRASE="${GITHUB_SSH_PASSPHRASE:-}"

  LFRIC_APPS_REF="${LFRIC_APPS_REF:-e906813e45406163723ad697584b500161a8874e}"
  LFRIC_APPS_DEPTH="${LFRIC_APPS_DEPTH:-1}"
  LFRIC_CORE_DEPTH="${LFRIC_CORE_DEPTH:-}"

  SPACK_DIR="${SPACK_DIR:-$WORKING_DIR/spack}"
  SPACK_REF="${SPACK_REF:-73eaea13f381e3495299284856fd02a64e1d154c}"
  SPACK_JOBS="${SPACK_JOBS:-2}"
  info "Using SPACK_JOBS=$SPACK_JOBS"

  # Clear any stale Spack environment from the parent shell to avoid setup errors.
  unset SPACK_ENV
  unset SPACK_ENV_PATH

  ENV_NAME="${ENV_NAME:-lfric-apps-isambard}"
  ENV_DIR="${ENV_DIR:-$WORKING_DIR/spack-envs/$ENV_NAME}"
  ENV_FILE="$ENV_DIR/spack.yaml"
  REGEN_ENV="${REGEN_ENV:-0}"
  SPACK_STAGE="${SPACK_STAGE:-$WORKING_DIR/spack-stage/${ENV_NAME}-$$}"
  if ! mkdir -p "$SPACK_STAGE"; then
    fail "Unable to create Spack stage directory $SPACK_STAGE."
    return 1
  fi
  export SPACK_STAGE

  PACKAGE_REPO="$ROOT_DIR/lfric-isambard-spack_repo"
  if [ ! -d "$PACKAGE_REPO" ]; then
    fail "lfric-isambard-spack_repo not found at $PACKAGE_REPO."
    return 1
  fi

  COMPILER_SPEC="${COMPILER_SPEC:-gcc@12.3.0}"
  COMPILER_SPEC="${COMPILER_SPEC#%}"

  SIMIT_SPACK_DIR="${SIMIT_SPACK_DIR:-$WORKING_DIR/simit-spack-main}"
  if [ -z "${SIMIT_SPACK_URL:-}" ]; then
    if [ "$USE_GITHUB_SSH" = "1" ]; then
      SIMIT_SPACK_URL="git@github.com:MetOffice/simit-spack.git"
    else
      SIMIT_SPACK_URL="https://github.com/MetOffice/simit-spack.git"
    fi
  fi
  SIMIT_SPACK_REF="${SIMIT_SPACK_REF:-ece4c48121791f2f1fef5d5999ccf75e74df520e}"
  CLONE_SIMIT_SPACK="${CLONE_SIMIT_SPACK:-1}"


  BUILTIN_REPO_DIR=""
  local _spack_user_cfg="${SPACK_USER_CONFIG_PATH:-$HOME/.spack}"
  if [ -d "$_spack_user_cfg/package_repos" ]; then
    local builtin_repo_yaml
    builtin_repo_yaml="$(find "$_spack_user_cfg/package_repos" -maxdepth 5 -path "*/repos/spack_repo/builtin/repo.yaml" -print -quit 2>/dev/null)"
    if [ -n "$builtin_repo_yaml" ]; then
      BUILTIN_REPO_DIR="$(dirname "$builtin_repo_yaml")"
    fi
  fi

  if [ "$USE_GITHUB_SSH" = "1" ]; then
    GITHUB_BASE="git@github.com:"
  else
    GITHUB_BASE="https://github.com/"
  fi

  if [ "${USE_GITHUB_SSH:-0}" != "1" ]; then
    orig_git_config="${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}"
    TMP_GIT_CONFIG="$(mktemp)"
    {
      if [ -f "$orig_git_config" ]; then
        printf '[include]\n\tpath = %s\n' "$orig_git_config"
      fi
      printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n'
    } > "$TMP_GIT_CONFIG"
    export GIT_CONFIG_GLOBAL="$TMP_GIT_CONFIG"
  fi

  export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"

  GITHUB_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ "${USE_GITHUB_SSH:-0}" != "1" ] && [ -z "$GITHUB_TOKEN_VALUE" ]; then
    echo "WARNING: GITHUB_TOKEN or GH_TOKEN not set; private GitHub repos may fail to fetch." >&2
  fi

  if [ -n "$GITHUB_TOKEN_VALUE" ]; then
    TMP_GIT_ASKPASS="$(mktemp)"
    cat > "$TMP_GIT_ASKPASS" <<'GIT_ASKPASS_EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "${GITHUB_USER:-${GITHUB_ACTOR:-x-access-token}}" ;;
  *Password*) printf '%s\n' "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ;;
  *) printf '\n' ;;
esac
GIT_ASKPASS_EOF
    chmod 700 "$TMP_GIT_ASKPASS"
    export GIT_ASKPASS="$TMP_GIT_ASKPASS"
    export GIT_TERMINAL_PROMPT=0
  fi

  if [ "$USE_GITHUB_SSH" = "1" ]; then
    configure_github_ssh || return 1
  fi

  clone_or_update "lfric_apps" "$(repo_url "MetOffice/lfric_apps")" "$LFRIC_APPS_REF" "$LFRIC_APPS_DEPTH" \
    || { fail "Failed to clone lfric_apps."; return 1; }

  if [ "$USE_GITHUB_SSH" = "1" ]; then
    rewrite_github_to_ssh "$WORKING_DIR/lfric_apps/dependencies.yaml"
  else
    rewrite_github_to_https "$WORKING_DIR/lfric_apps/dependencies.yaml"
  fi

  if [ ! -f "$WORKING_DIR/lfric_apps/dependencies.yaml" ]; then
    fail "dependencies.yaml not found in $WORKING_DIR/lfric_apps."
    return 1
  fi

  LFRIC_CORE_REF="$(awk '/^lfric_core:/{f=1} f&&/ref:/{print $2; exit}' "$WORKING_DIR/lfric_apps/dependencies.yaml")"
  LFRIC_CORE_REF_OVERRIDE="${LFRIC_CORE_REF_OVERRIDE:-da8a926408be418a8bf4da1f7caaa9791d0b37ca}"
  if [ -n "$LFRIC_CORE_REF_OVERRIDE" ]; then
    LFRIC_CORE_REF="$LFRIC_CORE_REF_OVERRIDE"
  fi
  if [ -z "$LFRIC_CORE_REF" ]; then
    fail "Unable to determine lfric_core ref from dependencies.yaml."
    return 1
  fi

  clone_lfric_core "$LFRIC_CORE_REF" || { fail "Failed to clone lfric_core."; return 1; }
  patch_stop_timing_signature
  patch_mpicxx_wrapper_detection

  if [ -d "$SPACK_DIR" ] && [ ! -d "$SPACK_DIR/.git" ]; then
    warn "Spack directory $SPACK_DIR exists but is not a git repo; removing for a clean clone."
    rm -rf "$SPACK_DIR"
  fi
  if [ ! -d "$SPACK_DIR" ]; then
    if ! git clone https://github.com/spack/spack.git "$SPACK_DIR"; then
      fail "Failed to clone Spack into $SPACK_DIR."
      return 1
    fi
  fi
  if [ -n "$SPACK_REF" ]; then
    if ! git -C "$SPACK_DIR" fetch --tags; then
      fail "Failed to fetch Spack tags in $SPACK_DIR."
      return 1
    fi
    if ! git -C "$SPACK_DIR" checkout "$SPACK_REF"; then
      fail "Failed to checkout Spack ref $SPACK_REF."
      return 1
    fi
  fi

  if [ ! -f "$SPACK_DIR/share/spack/setup-env.sh" ]; then
    fail "Spack setup not found at $SPACK_DIR/share/spack/setup-env.sh."
    return 1
  fi

  . "$SPACK_DIR/share/spack/setup-env.sh"
  if ! spack --version; then
    fail "Spack is not available after sourcing setup-env.sh."
    return 1
  fi

  if ! mkdir -p "$SPACK_DIR/var/spack/environments"; then
    fail "Unable to create Spack environments directory under $SPACK_DIR/var/spack/environments."
    return 1
  fi

  if ! ensure_builtin_repo; then
    return 1
  fi
  if [ -n "${BUILTIN_REPO_DIR:-}" ] && [ -d "$BUILTIN_REPO_DIR" ]; then
    fix_builtin_papi_rocp_sdk "$BUILTIN_REPO_DIR"
    fix_builtin_papi_tests "$BUILTIN_REPO_DIR"
  else
    echo "WARN: builtin repo dir not available; skipping builtin repo fixes." >&2
  fi
  fix_papi_rocp_sdk_in_cache

  if [ ! -d "$SIMIT_SPACK_DIR" ]; then
    if [ "$CLONE_SIMIT_SPACK" = "1" ]; then
      if ! git clone "$SIMIT_SPACK_URL" "$SIMIT_SPACK_DIR"; then
        fail "Failed to clone simit-spack into $SIMIT_SPACK_DIR."
        return 1
      fi
      if [ -n "$SIMIT_SPACK_REF" ]; then
        if ! git -C "$SIMIT_SPACK_DIR" checkout "$SIMIT_SPACK_REF"; then
          fail "Failed to checkout simit-spack ref $SIMIT_SPACK_REF."
          return 1
        fi
      fi
    else
      fail "simit-spack-main not found at $SIMIT_SPACK_DIR. Set SIMIT_SPACK_DIR or enable CLONE_SIMIT_SPACK=1."
      return 1
    fi
  else
    if [ "$UPDATE_REPOS" = "1" ] && [ -n "$SIMIT_SPACK_REF" ]; then
      git -C "$SIMIT_SPACK_DIR" fetch --tags --prune
      git -C "$SIMIT_SPACK_DIR" checkout "$SIMIT_SPACK_REF" || true
    fi
  fi

  if ! patch_simit_rose_picker; then
    return 1
  fi
  if ! patch_simit_cylc_flow; then
    return 1
  fi
  if ! patch_simit_cylc_rose; then
    return 1
  fi
  if ! patch_simit_cylc_uiserver; then
    return 1
  fi
  if ! patch_simit_py_ansimarkup; then
    return 1
  fi
  if ! patch_simit_py_aiofiles; then
    return 1
  fi
  if ! patch_simit_py_async_timeout; then
    return 1
  fi
  if ! patch_simit_py_poetry_core; then
    return 1
  fi
  if ! patch_simit_py_colorama; then
    return 1
  fi
  if ! patch_simit_py_six; then
    return 1
  fi
  if ! patch_simit_py_graphql_core; then
    return 1
  fi
  if ! patch_simit_py_graphql_relay; then
    return 1
  fi
  if ! patch_simit_py_jsonschema; then
    return 1
  fi
  if ! patch_simit_py_psyclone; then
    return 1
  fi
  if ! patch_simit_py_jupyter_server; then
    return 1
  fi
  if ! patch_simit_py_aniso8601; then
    return 1
  fi
  if ! patch_simit_py_graphene; then
    return 1
  fi
  if ! patch_simit_py_metomi_isodatetime; then
    return 1
  fi
  if ! patch_simit_py_pyasn1; then
    return 1
  fi
  if ! patch_simit_py_pyasn1_modules; then
    return 1
  fi
  if ! patch_simit_py_ldap3; then
    return 1
  fi
  if ! patch_simit_py_protobuf; then
    return 1
  fi
  if ! patch_simit_py_psutil; then
    return 1
  fi
  if ! patch_simit_py_pyuv; then
    return 1
  fi
  if ! patch_simit_py_certifi; then
    return 1
  fi
  if ! patch_simit_py_charset_normalizer; then
    return 1
  fi
  if ! patch_simit_py_idna; then
    return 1
  fi
  if ! patch_simit_py_urllib3; then
    return 1
  fi
  if ! patch_simit_py_requests; then
    return 1
  fi
  if ! patch_simit_py_greenlet; then
    return 1
  fi
  if ! patch_simit_py_sqlalchemy; then
    return 1
  fi
  if ! patch_simit_metomi_rose; then
    return 1
  fi
  if ! patch_simit_py_promise; then
    return 1
  fi
  if ! patch_simit_py_rx; then
    return 1
  fi
  if ! patch_simit_py_urwid; then
    return 1
  fi
  if ! patch_simit_py_pyzmq; then
    return 1
  fi
  if ! patch_simit_foxml; then
    return 1
  fi

  SIMIT_REPO="$SIMIT_SPACK_DIR/repos/metoffice"
  if [ ! -d "$SIMIT_REPO" ]; then
    fail "simit-spack metoffice repo not found at $SIMIT_REPO."
    return 1
  fi
  ensure_repo_api_v1 "$SIMIT_REPO/repo.yaml"
  fix_spack_pkg_builtin_imports "$SIMIT_REPO"
  fix_build_system_imports "$SIMIT_REPO"
  ensure_spack_package_imports "$SIMIT_REPO"

  spack compiler find || true
  if ! spack compilers | grep -q "$COMPILER_SPEC"; then
    echo "WARN: compiler $COMPILER_SPEC not found by Spack; load a matching compiler module or set COMPILER_SPEC." >&2
  fi

  if ! mkdir -p "$ENV_DIR"; then
    fail "Unable to create environment directory $ENV_DIR."
    return 1
  fi
  if [ "$REGEN_ENV" = "1" ] && [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
  fi
  if [ "$REGEN_ENV" = "1" ] && [ -f "$ENV_DIR/spack.lock" ]; then
    rm -f "$ENV_DIR/spack.lock"
  fi
  if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<EOF
spack:
  view: true
  concretizer:
    unify: when_possible
  repos:
  - "${PACKAGE_REPO}"
  - "${SIMIT_REPO}"
EOF
    if [ -n "$BUILTIN_REPO_DIR" ]; then
      cat >> "$ENV_FILE" <<EOF
  - "${BUILTIN_REPO_DIR}"
EOF
    else
      warn "Unable to locate Spack builtin repo under ${SPACK_USER_CONFIG_PATH:-$HOME/.spack}/package_repos; py-jupyter-server may fail to resolve."
    fi
    cat >> "$ENV_FILE" <<EOF
  packages:
    all:
      require: ["%${COMPILER_SPEC}"]
      providers:
        mpi: [mpich]
    python:
      variants: +shared
    py-setuptools:
      version: [":79"]
  specs:
  - "lfric-apps-isambard"
EOF
  else
    echo "Using existing environment manifest at $ENV_FILE"
  fi

  if ! spack env list | grep -Eq "^[[:space:]]*$ENV_NAME$"; then
    if ! spack env create "$ENV_NAME" "$ENV_FILE"; then
      fail "Failed to create Spack environment $ENV_NAME from $ENV_FILE."
      return 1
    fi
  fi

  if ! spack -e "$ENV_NAME" concretize -f; then
    fail "Spack concretize failed for environment $ENV_NAME."
    return 1
  fi
  fix_papi_rocp_sdk_in_cache

  # Re-check after concretize: on first run Spack clones ~/.spack/package_repos
  # during concretize, so ensure_builtin_repo (called before concretize) finds
  # only the remote URL, not a local path, and cannot apply the papi fix.
  if [ -z "${BUILTIN_REPO_DIR:-}" ] && [ -d "${SPACK_USER_CONFIG_PATH:-$HOME/.spack}/package_repos" ]; then
    local _yaml
    _yaml="$(find "${SPACK_USER_CONFIG_PATH:-$HOME/.spack}/package_repos" -maxdepth 5 \
      -path "*/repos/spack_repo/builtin/repo.yaml" -print -quit 2>/dev/null)"
    [ -n "$_yaml" ] && BUILTIN_REPO_DIR="$(dirname "$_yaml")"
  fi
  if [ -n "${BUILTIN_REPO_DIR:-}" ] && [ -d "$BUILTIN_REPO_DIR" ]; then
    fix_builtin_papi_rocp_sdk "$BUILTIN_REPO_DIR"
    fix_builtin_papi_tests "$BUILTIN_REPO_DIR"
  fi

  if spack -e "$ENV_NAME" spec -I lfric-apps-isambard 2>/dev/null | grep -q "openmpi@"; then
    info "openmpi detected in environment; re-concretizing with --fresh to force mpich."
    if ! spack -e "$ENV_NAME" concretize -f -U; then
      fail "Spack concretize (fresh) failed for environment $ENV_NAME."
      return 1
    fi
    fix_papi_rocp_sdk_in_cache
    if [ -n "${BUILTIN_REPO_DIR:-}" ] && [ -d "$BUILTIN_REPO_DIR" ]; then
      fix_builtin_papi_rocp_sdk "$BUILTIN_REPO_DIR"
      fix_builtin_papi_tests "$BUILTIN_REPO_DIR"
    fi
  fi

  # Some netcdf-c builds probe for xml2-config even when DAP is disabled.
  if ! spack -e "$ENV_NAME" install -j "$SPACK_JOBS" libxml2; then
    fail "Spack install failed for libxml2 in environment $ENV_NAME."
    return 1
  fi
  libxml2_prefix="$(spack -e "$ENV_NAME" location -i libxml2 2>/dev/null || true)"
  if [ -n "$libxml2_prefix" ]; then
    export XML2_CONFIG="$libxml2_prefix/bin/xml2-config"
    export PATH="$libxml2_prefix/bin:$PATH"
  fi

  # yaxt installs can race in parallel installs; do it serially first.
  if ! spack -e "$ENV_NAME" install -j 1 yaxt; then
    fail "Spack install failed for yaxt in environment $ENV_NAME."
    return 1
  fi

  if ! spack -e "$ENV_NAME" find node-js >/dev/null 2>&1; then
    info "Installing node-js with SPACK_JOBS=$SPACK_JOBS."
    if ! spack -e "$ENV_NAME" install -j "$SPACK_JOBS" node-js; then
      fail "Spack install failed for node-js in environment $ENV_NAME."
      return 1
    fi
  fi

  if ! spack -e "$ENV_NAME" install -j "$SPACK_JOBS"; then
    fail "Spack install failed for environment $ENV_NAME."
    return 1
  fi

  if ! spack -e "$ENV_NAME" env view regenerate; then
    view_tmp="$SPACK_DIR/var/spack/environments/$ENV_NAME/.spack-env/._view"
    if [ -d "$view_tmp" ]; then
      rm -rf "$view_tmp"
      if ! spack -e "$ENV_NAME" env view regenerate; then
        fail "Failed to regenerate Spack environment view for $ENV_NAME."
        return 1
      fi
    else
      fail "Failed to regenerate Spack environment view for $ENV_NAME."
      return 1
    fi
  fi

  if ! spack env activate -p "$ENV_NAME"; then
    fail "Failed to activate Spack environment $ENV_NAME."
    return 1
  fi

  REQUIRED_SPECS=(
    mpich
    hdf5
    netcdf-c
    netcdf-fortran
    xios
    yaxt
    pfunit
    shumlib
    pkgconf
    python
    py-jinja2
    py-pyyaml
    py-psyclone
    py-fparser
    metomi-rose
    cylc-flow
    cylc-rose
    cylc-uiserver
    py-ansimarkup
    py-aiofiles
    py-colorama
    py-graphene
    py-graphql-core
    py-graphql-relay
    py-protobuf
    py-psutil
    py-ldap3
    py-requests
    py-sqlalchemy
  )

  missing_specs=()
  for spec in "${REQUIRED_SPECS[@]}"; do
    if ! spack -e "$ENV_NAME" find "$spec" >/dev/null 2>&1; then
      missing_specs+=("$spec")
    fi
  done
  if [ "${#missing_specs[@]}" -gt 0 ]; then
    if [ "${AUTO_INSTALL_MISSING_SPECS:-1}" = "1" ]; then
      info "Installing missing specs in environment: ${missing_specs[*]}"
      if ! spack -e "$ENV_NAME" install -j "$SPACK_JOBS" "${missing_specs[@]}"; then
        fail "Failed to install missing Spack specs: ${missing_specs[*]}"
        return 1
      fi
    else
      fail "Missing required Spack specs: ${missing_specs[*]}"
      return 1
    fi
  fi

  if ! spack load "${REQUIRED_SPECS[@]}"; then
    fail "Failed to load required Spack specs."
    return 1
  fi

  if ! python -c "import graphql, graphene" >/dev/null 2>&1; then
    fail "Python sanity check failed: unable to import graphql/graphene."
    return 1
  fi

  if shumlib_prefix=$(spack -e "$ENV_NAME" location -i shumlib 2>/dev/null); then
    export SHUMLIB_ROOT="${SHUMLIB_ROOT:-$shumlib_prefix}"
    if [ -d "$SHUMLIB_ROOT/lib" ]; then
      export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L$SHUMLIB_ROOT/lib -Wl,-rpath=$SHUMLIB_ROOT/lib"
      export LIBRARY_PATH="$SHUMLIB_ROOT/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
      export LD_LIBRARY_PATH="$SHUMLIB_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
  fi

  mpich_prefix="$(spack -e "$ENV_NAME" location -i mpich 2>/dev/null || true)"
  if [ -n "$mpich_prefix" ] && [ -x "$mpich_prefix/bin/mpif90" ]; then
    mpi_fc="$mpich_prefix/bin/mpif90"
    mpi_cxx="$mpich_prefix/bin/mpic++"
    if [ ! -x "$mpi_cxx" ]; then
      mpi_cxx="$mpich_prefix/bin/mpicxx"
    fi
    export PATH="$mpich_prefix/bin:$PATH"
  else
    mpi_fc="mpif90"
    mpi_cxx="mpic++"
    if ! command -v "$mpi_cxx" >/dev/null 2>&1; then
      mpi_cxx="mpicxx"
    fi
  fi
  if [ "${KEEP_FC:-0}" != "1" ]; then
    export FC="$mpi_fc"
    export LDMPI="$mpi_fc"
    export MPIFC="$mpi_fc"
    export MPIF90="$mpi_fc"
    export F90="$mpi_fc"
    export F77="$mpi_fc"
  fi
  if [ -z "${CXX:-}" ] && [ -n "$mpi_cxx" ]; then
    export CXX="$mpi_cxx"
  fi

  mpif90_path="$(command -v mpif90 || true)"
  if [ -n "$mpif90_path" ]; then
    echo "DEBUG: mpif90=$mpif90_path"
    echo "DEBUG: mpif90 --version: $(mpif90 --version | head -n 1)"
  else
    echo "DEBUG: mpif90 not found in PATH"
  fi

  if python_prefix=$(spack -e "$ENV_NAME" location -i python 2>/dev/null); then
    export PATH="$python_prefix/bin:$PATH"
    if [ -x "$python_prefix/bin/python3" ] && ! command -v python >/dev/null 2>&1; then
      TMP_PYTHON_DIR="$(mktemp -d)"
      ln -s "$python_prefix/bin/python3" "$TMP_PYTHON_DIR/python"
      export PATH="$TMP_PYTHON_DIR:$PATH"
    fi
  fi
  if psyclone_prefix=$(spack -e "$ENV_NAME" location -i py-psyclone 2>/dev/null); then
    export PATH="$psyclone_prefix/bin:$PATH"
  fi

  ROSE_PICKER_PREFIX=""
  if [ -n "${ROSE_PICKER:-}" ] && [ -x "$ROSE_PICKER" ]; then
    export PATH="$(dirname "$ROSE_PICKER"):$PATH"
    ROSE_PICKER_PREFIX="$(cd "$(dirname "$ROSE_PICKER")/.." && pwd)"
  elif rose_picker_prefix=$(spack -e "$ENV_NAME" location -i rose-picker 2>/dev/null); then
    spack load rose-picker >/dev/null 2>&1
    export PATH="$rose_picker_prefix/bin:$PATH"
    ROSE_PICKER_PREFIX="$rose_picker_prefix"
  fi

  if [ -n "$ROSE_PICKER_PREFIX" ] && [ -d "$ROSE_PICKER_PREFIX/bin" ]; then
    echo "DEBUG: rose_picker bin directory $ROSE_PICKER_PREFIX/bin"
    ls -1 "$ROSE_PICKER_PREFIX/bin" || true
  fi
  if command -v rose_picker >/dev/null 2>&1; then
    echo "DEBUG: rose_picker available at $(command -v rose_picker)"
  else
    echo "DEBUG: rose_picker not found on PATH"
  fi

  APPS_ROOT_DIR="${APPS_ROOT_DIR:-$WORKING_DIR/lfric_apps}"
  CORE_ROOT_DIR="${CORE_ROOT_DIR:-$WORKING_DIR/lfric_core}"
  LFRIC_TARGET_PLATFORM="${LFRIC_TARGET_PLATFORM:-meto-spice}"
  FPP="${FPP:-cpp -traditional-cpp}"
  PYTHON_BIN="${PYTHON:-python}"
  export FPP

  if [ ! -f "$APPS_ROOT_DIR/build/local_build.py" ]; then
    fail "local_build.py not found at $APPS_ROOT_DIR/build/local_build.py."
    return 1
  fi

  if [ "${CLEAN_PHYSICS_SCRATCH:-1}" != "0" ]; then
    rm -rf "$APPS_ROOT_DIR/applications/lfric_atm/physics_scratch"
    rm -rf "$APPS_ROOT_DIR/applications/lfric_atm/working/physics_scratch"
  fi

  LOCAL_BUILD_LOG="$APPS_ROOT_DIR/applications/lfric_atm/make.log"
  LOCAL_BUILD_WORKING_DIR="$APPS_ROOT_DIR/applications/lfric_atm/working"
  if [ "${CLEAN_BUILD_WORKING:-1}" != "0" ]; then
    rm -rf "$LOCAL_BUILD_WORKING_DIR/build_lfric_atm"
  fi

  BUILD_CMD=(
    "$PYTHON_BIN"
    "$APPS_ROOT_DIR/build/local_build.py"
    lfric_atm
    -c "$CORE_ROOT_DIR"
    -w "$LOCAL_BUILD_WORKING_DIR"
    -j "${MAKE_JOBS:-8}"
    -t build
  )

  local_build_help="$("$PYTHON_BIN" "$APPS_ROOT_DIR/build/local_build.py" -h 2>&1 || true)"
  added_target_flag=0
  if printf '%s\n' "$local_build_help" | grep -qE '(^|[[:space:]])-u([[:space:],]|$)|--target'; then
    BUILD_CMD+=(-u "$LFRIC_TARGET_PLATFORM")
    added_target_flag=1
  else
    warn "local_build.py does not support -u; skipping LFRIC_TARGET_PLATFORM."
  fi

  if [ "${VERBOSE_BUILD:-0}" = "1" ]; then
    BUILD_CMD+=(-v)
  fi

  if ! cd "$APPS_ROOT_DIR"; then
    fail "Failed to change directory to $APPS_ROOT_DIR."
    return 1
  fi
  "${BUILD_CMD[@]}" |& tee "$LOCAL_BUILD_LOG"
  build_status=${PIPESTATUS[0]}
  if [ "$build_status" -ne 0 ]; then
    if [ "$added_target_flag" -eq 1 ] \
      && [ "$build_status" -eq 2 ] \
      && grep -q "unrecognized arguments: -u" "$LOCAL_BUILD_LOG"; then
      warn "local_build.py rejected -u; retrying without LFRIC_TARGET_PLATFORM."
      BUILD_CMD=(
        "$PYTHON_BIN"
        "$APPS_ROOT_DIR/build/local_build.py"
        lfric_atm
        -c "$CORE_ROOT_DIR"
        -w "$LOCAL_BUILD_WORKING_DIR"
        -j "${MAKE_JOBS:-8}"
        -t build
      )
      if [ "${VERBOSE_BUILD:-0}" = "1" ]; then
        BUILD_CMD+=(-v)
      fi
      "${BUILD_CMD[@]}" |& tee "$LOCAL_BUILD_LOG"
      build_status=${PIPESTATUS[0]}
    fi
  fi
  if [ "$build_status" -ne 0 ]; then
    fail "local_build.py failed for lfric_atm (exit $build_status). See $LOCAL_BUILD_LOG."
    return 1
  fi

  PROJECT="${PROJECT:-lfric_atm}"
  APP_BIN="$APPS_ROOT_DIR/applications/$PROJECT/bin/$PROJECT"
  if [ ! -x "$APP_BIN" ]; then
    fail "Executable not found at $APP_BIN."
    return 1
  fi

  EXAMPLE_DIR="$APPS_ROOT_DIR/applications/$PROJECT/example"
  if [ -d "$EXAMPLE_DIR" ] && [ -f "$EXAMPLE_DIR/configuration.nml" ]; then
    if ! cd "$EXAMPLE_DIR"; then
      fail "Failed to change directory to $EXAMPLE_DIR."
      return 1
    fi
    "$APP_BIN" configuration.nml
  else
    echo "WARNING: example configuration not found under $EXAMPLE_DIR. Run $APP_BIN manually." >&2
  fi

  print_rose_cylc_info
}

main "$@"
status=$?
if [ "$status" -ne 0 ]; then
  if [ "${EXIT_ON_ERROR:-0}" = "1" ]; then
    if [ "$IS_SOURCED" -eq 1 ]; then
      return "$status"
    fi
    exit "$status"
  fi
  echo "ERROR: driver_rose_clyc.sh failed (exit $status). Keeping shell open; set EXIT_ON_ERROR=1 to exit on failure." >&2
  if [ "$IS_SOURCED" -eq 1 ]; then
    return 0
  fi
  exit 0
fi
