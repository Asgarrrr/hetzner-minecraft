#!/usr/bin/env bash
set -Eeuo pipefail

APP_USER="${APP_USER:-minecraft}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
APP_HOME="${APP_HOME:-/opt/hetzner-minecraft}"
APP_USER_HOME="${APP_USER_HOME:-/home/$APP_USER}"
REPO_URL="${REPO_URL:-https://github.com/Asgarrrr/hetzner-minecraft.git}"
REPO_REF="${REPO_REF:-main}"
UPDATE_REPO="${UPDATE_REPO:-0}"
RUN_BOOTSTRAP="${RUN_BOOTSTRAP:-1}"
GIT_AUTH_ARGS=()

log() {
  printf '[provision] %s\n' "$*"
}

warn() {
  printf '[provision] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[provision] ERROR: %s\n' "$*" >&2
  exit 1
}

run_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

move_dir_contents() {
  local src="$1"
  local dst="$2"

  run_sudo mkdir -p "$dst"
  run_sudo bash -lc "shopt -s dotglob nullglob; for path in \"$src\"/*; do mv \"\$path\" \"$dst\"/; done"
}

ensure_ubuntu() {
  [[ -f /etc/os-release ]] || die "Unsupported system: /etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script targets Ubuntu hosts."
}

ensure_prereqs() {
  if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required when running as a non-root user."
  fi

  log "Installing base packages needed for provisioning."
  run_sudo apt-get update
  run_sudo apt-get install -y ca-certificates curl git gnupg sudo
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && { docker compose version >/dev/null 2>&1 || run_sudo docker compose version >/dev/null 2>&1; }; then
    log "Docker Engine and Compose plugin already installed."
    return
  fi

  log "Installing Docker Engine and Compose plugin."

  local maybe_conflicts=(
    docker.io
    docker-doc
    docker-compose
    docker-compose-v2
    podman-docker
    containerd
    runc
  )
  local installed_conflicts=()
  local pkg

  for pkg in "${maybe_conflicts[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      installed_conflicts+=("$pkg")
    fi
  done

  if ((${#installed_conflicts[@]} > 0)); then
    log "Removing conflicting packages: ${installed_conflicts[*]}"
    run_sudo apt-get remove -y "${installed_conflicts[@]}"
  fi

  run_sudo install -m 0755 -d /etc/apt/keyrings
  run_sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  run_sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Keep the Docker apt source in sync with the current Ubuntu codename.
  run_sudo bash -lc "cat > /etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF"

  run_sudo apt-get update
  run_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_sudo systemctl enable --now docker
}

ensure_group() {
  if getent group "$APP_GROUP" >/dev/null 2>&1; then
    return
  fi

  log "Creating group ${APP_GROUP}."
  run_sudo groupadd --system "$APP_GROUP"
}

ensure_user() {
  if id "$APP_USER" >/dev/null 2>&1; then
    log "Using existing user ${APP_USER}."
    local current_home
    current_home="$(getent passwd "$APP_USER" | cut -d: -f6)"

    if [[ "$current_home" == "$APP_HOME" && "$APP_USER_HOME" != "$APP_HOME" ]]; then
      log "Moving ${APP_USER} home from ${APP_HOME} to ${APP_USER_HOME}."
      run_sudo mkdir -p "$APP_USER_HOME"
      move_dir_contents "$APP_HOME" "$APP_USER_HOME"
      run_sudo usermod -d "$APP_USER_HOME" "$APP_USER"
      run_sudo chown -R "${APP_USER}:${APP_GROUP}" "$APP_USER_HOME"
    fi

    return
  fi

  log "Creating system user ${APP_USER} with home ${APP_USER_HOME}."
  run_sudo useradd \
    --system \
    --gid "$APP_GROUP" \
    --home-dir "$APP_USER_HOME" \
    --create-home \
    --shell /bin/bash \
    "$APP_USER"
}

ensure_app_dir() {
  log "Preparing application directory ${APP_HOME}."
  run_sudo mkdir -p "$APP_HOME"
  run_sudo chown -R "${APP_USER}:${APP_GROUP}" "$APP_HOME"
}

ensure_docker_group_membership() {
  if ! getent group docker >/dev/null 2>&1; then
    return
  fi

  if id -nG "$APP_USER" | grep -qw docker; then
    return
  fi

  log "Adding ${APP_USER} to docker group."
  run_sudo usermod -aG docker "$APP_USER"
}

prepare_git_auth() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    return
  fi

  [[ "$REPO_URL" =~ ^https://github\.com/ ]] || die "GITHUB_TOKEN auth currently supports only https://github.com/... REPO_URL values."

  local auth
  auth="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
  GIT_AUTH_ARGS=(-c "http.extraheader=AUTHORIZATION: basic ${auth}")
}

run_as_app() {
  run_sudo runuser -u "$APP_USER" -- "$@"
}

clean_app_dir_skeleton() {
  [[ -d "$APP_HOME" ]] || return
  [[ -d "${APP_HOME}/.git" ]] && return

  local entry
  local found=0

  while IFS= read -r entry; do
    found=1
    case "$entry" in
      .bash_history|.bash_logout|.bashrc|.profile|.sudo_as_admin_successful) ;;
      *) return ;;
    esac
  done < <(find "$APP_HOME" -mindepth 1 -maxdepth 1 -printf '%f\n')

  if [[ "$found" == "1" ]]; then
    log "Removing default shell skeleton files from ${APP_HOME} before clone."
    run_sudo rm -f \
      "${APP_HOME}/.bash_history" \
      "${APP_HOME}/.bash_logout" \
      "${APP_HOME}/.bashrc" \
      "${APP_HOME}/.profile" \
      "${APP_HOME}/.sudo_as_admin_successful"
  fi
}

clone_repo() {
  prepare_git_auth
  clean_app_dir_skeleton

  if [[ -d "${APP_HOME}/.git" ]]; then
    log "Repository already exists in ${APP_HOME}."

    if [[ "$UPDATE_REPO" != "1" ]]; then
      warn "Skipping repo update. Set UPDATE_REPO=1 to fetch the latest ${REPO_REF}."
      return
    fi

    log "Updating existing checkout to ${REPO_REF}."
    run_as_app git "${GIT_AUTH_ARGS[@]}" -C "$APP_HOME" fetch --all --prune
    run_as_app git -C "$APP_HOME" checkout "$REPO_REF"
    run_as_app git "${GIT_AUTH_ARGS[@]}" -C "$APP_HOME" pull --ff-only origin "$REPO_REF"
    return
  fi

  if [[ -n "$(find "$APP_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "${APP_HOME} exists and is not an empty git checkout. Clean it or choose another APP_HOME."
  fi

  log "Cloning ${REPO_URL} into ${APP_HOME}."
  if ! run_as_app git "${GIT_AUTH_ARGS[@]}" clone --branch "$REPO_REF" "$REPO_URL" "$APP_HOME"; then
    cat >&2 <<EOF
[provision] ERROR: git clone failed.
[provision] If the repository is private, rerun with one of these options:
[provision]   REPO_URL=git@github.com:Asgarrrr/hetzner-minecraft.git
[provision]   GITHUB_TOKEN=ghp_or_fine_grained_token
EOF
    exit 1
  fi
}

ensure_bootstrap_script() {
  [[ -x "${APP_HOME}/scripts/bootstrap-ubuntu.sh" ]] || run_sudo chmod +x "${APP_HOME}/scripts/bootstrap-ubuntu.sh"
}

run_bootstrap() {
  local env_script

  if [[ "$RUN_BOOTSTRAP" != "1" ]]; then
    warn "RUN_BOOTSTRAP=0, stopping after clone."
    return
  fi

  ensure_bootstrap_script
  ensure_docker_group_membership

  env_script="$(mktemp)"
  trap 'rm -f "${env_script:-}"' EXIT

  cat > "$env_script" <<EOF
export CF_API_KEY=$(printf '%q' "${CF_API_KEY:-}")
export RCON_PASSWORD=$(printf '%q' "${RCON_PASSWORD:-}")
export TZ=$(printf '%q' "${TZ:-}")
export MC_PORT=$(printf '%q' "${MC_PORT:-}")
export RCON_PORT=$(printf '%q' "${RCON_PORT:-}")
export CF_FILENAME_MATCHER=$(printf '%q' "${CF_FILENAME_MATCHER:-}")
export INIT_MEMORY=$(printf '%q' "${INIT_MEMORY:-}")
export MEMORY=$(printf '%q' "${MEMORY:-}")
export VIEW_DISTANCE=$(printf '%q' "${VIEW_DISTANCE:-}")
export SIMULATION_DISTANCE=$(printf '%q' "${SIMULATION_DISTANCE:-}")
export MOTD=$(printf '%q' "${MOTD:-}")
export OPEN_UFW=$(printf '%q' "${OPEN_UFW:-0}")
EOF

  run_sudo chown "${APP_USER}:${APP_GROUP}" "$env_script"
  run_sudo chmod 600 "$env_script"

  log "Running bootstrap as ${APP_USER}."
  run_sudo runuser -u "$APP_USER" -- bash -lc "set -e; source '$env_script'; cd '$APP_HOME'; exec sg docker -c './scripts/bootstrap-ubuntu.sh'"
}

main() {
  ensure_ubuntu
  ensure_prereqs
  install_docker
  ensure_group
  ensure_user
  ensure_app_dir
  clone_repo
  run_bootstrap

  log "Provisioning complete."
  log "App user: ${APP_USER}"
  log "App directory: ${APP_HOME}"
}

main "$@"
