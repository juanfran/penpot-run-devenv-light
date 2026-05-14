#!/usr/bin/env bash
# Stop the Penpot devenv started by run-devenv-light.sh, without having to
# cd into the Penpot repo. Equivalent to ./manage.sh stop-devenv.

set -e

DEVENV_PNAME="penpotdev"
COMPOSE_REL="docker/devenv/docker-compose.yaml"

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
if [[ ! -f "$PENPOT_REPO/$COMPOSE_REL" ]]; then
  echo "Path does not look like a Penpot repo: $PENPOT_REPO" >&2
  echo "Expected $COMPOSE_REL." >&2
  exit 1
fi
PENPOT_REPO="$(cd "$PENPOT_REPO" && pwd)"

cd "$PENPOT_REPO"
echo ">> stopping devenv compose ($DEVENV_PNAME)..."
docker compose -p "$DEVENV_PNAME" -f "$COMPOSE_REL" stop -t 2
echo ">> done."
