#!/usr/bin/env bash
# Re-attach to the tmux session started by run-devenv-light.sh, without having
# to remember the docker exec incantation or cd into the Penpot repo.

set -e

CONTAINER="penpot-devenv-ws0-main"
SESSION="penpot"

usage() {
  cat <<EOF
Usage: $0

Attaches to the '$SESSION' tmux session inside $CONTAINER.
Detach with Ctrl-b d: the services keep running.

Options:
  -h, --help   Show this help.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0;;
  *) echo "Unknown option: $1" >&2; usage; exit 1;;
esac

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != "true" ]]; then
  echo "Container $CONTAINER is not running." >&2
  echo "Start it with ./run-devenv-light.sh" >&2
  exit 1
fi

if ! docker exec "$CONTAINER" sudo -u penpot tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "No '$SESSION' tmux session in $CONTAINER." >&2
  echo "Start it with ./run-devenv-light.sh --recreate" >&2
  exit 1
fi

exec docker exec -ti "$CONTAINER" sudo -u penpot tmux -2 attach-session -t "$SESSION"
