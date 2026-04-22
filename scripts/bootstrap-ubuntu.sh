#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_TEMPLATE="${REPO_ROOT}/.env.example"
ENV_FILE="${REPO_ROOT}/.env"
DATA_DIR="${REPO_ROOT}/volumes/minecraft"

log() {
  printf '[bootstrap] %s\n' "$*"
}

warn() {
  printf '[bootstrap] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Missing required file: $path"
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

is_missing_value() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == "replace_me" ]]
}

env_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$ENV_FILE" 2>/dev/null || true
}

upsert_env() {
  local key="$1"
  local value="$2"
  local tmp_file

  tmp_file="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ ("^" key "=") {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "$ENV_FILE" > "$tmp_file"

  mv "$tmp_file" "$ENV_FILE"
}

random_hex() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

run_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    (
      cd "$REPO_ROOT"
      docker compose "$@"
    )
  else
    (
      cd "$REPO_ROOT"
      run_sudo docker compose "$@"
    )
  fi
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

  require_file "$ENV_TEMPLATE"
  require_file "${REPO_ROOT}/compose.yml"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && { docker compose version >/dev/null 2>&1 || run_sudo docker compose version >/dev/null 2>&1; }; then
    log "Docker Engine and Compose plugin already installed."
    return
  fi

  log "Installing Docker Engine and Compose plugin."
  run_sudo apt-get update
  run_sudo apt-get install -y ca-certificates curl git gnupg

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

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log "Creating .env from template."
    cp "$ENV_TEMPLATE" "$ENV_FILE"
  else
    log "Using existing .env."
  fi
}

prompt_secret() {
  local prompt_text="$1"
  local value=""

  if is_interactive; then
    read -r -s -p "$prompt_text: " value
    printf '\n'
  fi

  printf '%s' "$value"
}

ensure_required_config() {
  local cf_api_key="${CF_API_KEY:-$(env_value CF_API_KEY)}"
  local rcon_password="${RCON_PASSWORD:-$(env_value RCON_PASSWORD)}"
  local optional_keys=(
    TZ
    MC_PORT
    RCON_PORT
    CF_FILENAME_MATCHER
    INIT_MEMORY
    MEMORY
    VIEW_DISTANCE
    SIMULATION_DISTANCE
    MOTD
  )
  local key
  local value

  if is_missing_value "$cf_api_key"; then
    cf_api_key="$(prompt_secret "CurseForge API key")"
  fi

  is_missing_value "$cf_api_key" && die "CF_API_KEY is required. Export it or add it to .env before running the script."

  if is_missing_value "$rcon_password"; then
    if is_interactive; then
      rcon_password="$(prompt_secret "RCON password (leave empty to auto-generate)")"
    fi

    if is_missing_value "$rcon_password"; then
      rcon_password="$(random_hex)"
      log "Generated RCON password: $rcon_password"
    fi
  fi

  upsert_env "CF_API_KEY" "$cf_api_key"
  upsert_env "RCON_PASSWORD" "$rcon_password"

  for key in "${optional_keys[@]}"; do
    value="${!key:-}"
    if [[ -n "$value" ]]; then
      upsert_env "$key" "$value"
    fi
  done
}

prepare_storage() {
  log "Preparing persistent data directory."
  mkdir -p "$DATA_DIR"
}

ensure_docker_access() {
  local target_user="${SUDO_USER:-}"

  if [[ -z "$target_user" || "$target_user" == "root" ]]; then
    return
  fi

  if id -nG "$target_user" | grep -qw docker; then
    return
  fi

  log "Adding ${target_user} to the docker group for future sessions."
  run_sudo usermod -aG docker "$target_user"
  warn "Open a new shell later if you want to run docker without sudo."
}

maybe_open_firewall() {
  local mc_port
  mc_port="$(env_value MC_PORT)"
  mc_port="${mc_port:-25565}"

  if [[ "${OPEN_UFW:-0}" != "1" ]]; then
    warn "Firewall not changed. Open TCP port ${mc_port} in Hetzner Cloud Firewall or UFW."
    return
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not installed. Open TCP port ${mc_port} in Hetzner Cloud Firewall."
    return
  fi

  if [[ "$(run_sudo ufw status | head -n1)" != "Status: active" ]]; then
    warn "ufw is not active. Open TCP port ${mc_port} in Hetzner Cloud Firewall if needed."
    return
  fi

  log "Opening TCP port ${mc_port} in UFW."
  run_sudo ufw allow "${mc_port}/tcp"
}

start_stack() {
  log "Pulling Docker image."
  docker_compose pull

  log "Starting the Minecraft service."
  docker_compose up -d

  log "Current service status:"
  docker_compose ps

  log "Recent Minecraft logs:"
  docker_compose logs --tail=40 minecraft || true
}

main() {
  ensure_ubuntu
  ensure_prereqs
  install_docker
  ensure_docker_access
  ensure_env_file
  ensure_required_config
  prepare_storage
  maybe_open_firewall
  start_stack

  log "Bootstrap complete."
  log "Follow logs with: docker compose logs -f minecraft"
  log "Persistent data lives in: ${DATA_DIR}"
}

main "$@"
