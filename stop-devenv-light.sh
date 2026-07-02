#!/usr/bin/env bash
# Stop the Penpot devenv started by run-devenv-light.sh, without having to
# cd into the Penpot repo. Equivalent to ./manage.sh stop-devenv.

set -e

DEFAULTS_ENV_REL="docker/devenv/defaults.env"
INFRA_COMPOSE_REL="docker/devenv/docker-compose.infra.yml"
MAIN_COMPOSE_REL="docker/devenv/docker-compose.main.yml"
INFRA_PNAME="penpotdev-infra"
INSTANCE="ws0"
INSTANCE_PNAME="penpotdev-${INSTANCE}"

PENPOT_REPO="${PENPOT_REPO:-$HOME/projects/penpot}"

usage() {
  cat <<EOF
Usage: $0 [options]

Stops the Penpot devenv containers (the equivalent of running
./manage.sh stop-devenv from inside the Penpot repo).

Options:
  -p, --repo PATH   Path to the local Penpot repository.
                    Default: \$PENPOT_REPO or "$HOME/projects/penpot"
  -h, --help        Show this help.

Env vars:
  PENPOT_REPO       Same as --repo (flag wins if both are set).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--repo)  PENPOT_REPO="$2"; shift 2;;
    -h|--help)  usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ ! -d "$PENPOT_REPO" ]]; then
  echo "Penpot repo not found at: $PENPOT_REPO" >&2
  echo "Set PENPOT_REPO or pass --repo PATH." >&2
  exit 1
fi
for f in "$DEFAULTS_ENV_REL" "$INFRA_COMPOSE_REL" "$MAIN_COMPOSE_REL"; do
  if [[ ! -f "$PENPOT_REPO/$f" ]]; then
    echo "Path does not look like a current Penpot repo: $PENPOT_REPO" >&2
    echo "Missing expected file: $f" >&2
    exit 1
  fi
done
PENPOT_REPO="$(cd "$PENPOT_REPO" && pwd)"

cd "$PENPOT_REPO"

# Same shell overrides as the launcher so compose can identify the
# instance's project/containers correctly.
echo ">> stopping main container ($INSTANCE_PNAME)..."
env -i HOME="$HOME" PATH="$PATH" PWD="$PWD" \
  CURRENT_USER_ID="$(id -u)" \
  PENPOT_SOURCE_PATH="$PENPOT_REPO" \
  PENPOT_MAIN_CONTAINER_NAME="penpot-devenv-${INSTANCE}-main" \
  PENPOT_USER_DATA_VOLUME="penpotdev_${INSTANCE}_user_data" \
  PENPOT_PUBLIC_URI="https://localhost:3449" \
  PENPOT_REDIS_URI="redis://valkey/0" \
  PENPOT_PUBLIC_HTTPS_PORT=3449 \
  PENPOT_PUBLIC_HTTP_PORT=3450 \
  PENPOT_MCP_SERVER_PORT=4401 \
  PENPOT_MCP_REPL_PORT=4403 \
  SERENA_EXTERNAL_PORT=14181 \
  SERENA_DASHBOARD_EXTERNAL_PORT=14182 \
  SHADOW_SERVER_URL="wss://localhost:3449" \
  PENPOT_TENANT="devenv-${INSTANCE}" \
  PENPOT_TMUX_ATTACH=false \
  docker compose -p "$INSTANCE_PNAME" \
    --env-file "$DEFAULTS_ENV_REL" \
    -f "$MAIN_COMPOSE_REL" stop -t 2

echo ">> stopping shared infra ($INFRA_PNAME)..."
env -i HOME="$HOME" PATH="$PATH" PWD="$PWD" \
  docker compose -p "$INFRA_PNAME" \
    --env-file "$DEFAULTS_ENV_REL" \
    -f "$INFRA_COMPOSE_REL" stop -t 2

echo ">> done."
