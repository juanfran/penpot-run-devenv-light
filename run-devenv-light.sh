#!/usr/bin/env bash
# Lightweight launcher for the Penpot devenv.
#
# Lets you pick which services to start so you don't pay the RAM cost of
# everything when you're only iterating on part of the stack.
#
# Defaults: frontend + backend, heap capped at 768m per JVM, ldap/mailer stopped.

set -e

DEVENV_PNAME="penpotdev"
COMPOSE_REL="docker/devenv/docker-compose.yaml"
CONTAINER="penpot-devenv-main"

PENPOT_REPO="${PENPOT_REPO:-$HOME/projects/penpot}"
SERVICES="frontend,backend"
JAVA_OPTS_DEFAULT="-Xmx768m -Xms50m"
AUX_KEEP=""
MINIMAL_FRONTEND=false
CLEAN=false
ALL_AUX=(mailer ldap)

usage() {
  cat <<EOF
Usage: $0 [options]

Picks which services to run inside the running devenv container and attaches
to a tmux session with one window per service.

Options:
  -p, --repo PATH        Path to the local Penpot repository.
                         Default: \$PENPOT_REPO or "$HOME/projects/penpot"
  -s, --services LIST    Comma-separated list of services to start.
                         Available: frontend, backend, storybook, exporter, mcp
                         Default: frontend,backend
  -j, --java-opts OPTS   JVM heap/options applied to every JVM (backend +
                         shadow-cljs). Default: "$JAVA_OPTS_DEFAULT"
      --minimal-frontend Skip the 'storybook' shadow-cljs target in the
                         frontend watch (only main + worker). Extra RAM saving
                         if you don't use Storybook.
      --clean            Wipe shadow-cljs + wasm caches and rebuild wasm from
                         scratch before starting the watcher. SLOW (the wasm
                         rebuild takes minutes). By default the watcher reuses
                         existing caches and only builds wasm if the artifact
                         is missing.
      --aux LIST         Comma-separated list of auxiliary containers to keep
                         running. Available: mailer, ldap.
                         Default: (none — both are stopped to save RAM)
  -h, --help             Show this help.

Env vars:
  PENPOT_REPO            Same as --repo (flag wins if both are set).
  JAVA_OPTS              Same as --java-opts (flag wins if both are set).

Examples:
  $0                                       # frontend + backend, 768m heap
  $0 --aux mailer                          # + mailcatcher (SMTP testing)
  $0 -s backend                            # only backend
  $0 -s frontend,backend,exporter
  $0 -s frontend --minimal-frontend        # no Storybook target compiled
  $0 --aux mailer,ldap                     # keep all aux containers
  JAVA_OPTS="-Xmx512m -Xms50m" $0          # tighter heap via env var
  PENPOT_REPO=~/code/penpot $0             # different repo location
  $0 -p ~/code/penpot -s backend
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--repo)           PENPOT_REPO="$2"; shift 2;;
    -s|--services)       SERVICES="$2"; shift 2;;
    -j|--java-opts)      JAVA_OPTS="$2"; shift 2;;
    --minimal-frontend)  MINIMAL_FRONTEND=true; shift;;
    --clean)             CLEAN=true; shift;;
    --aux)               AUX_KEEP="$2"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

JAVA_OPTS="${JAVA_OPTS:-$JAVA_OPTS_DEFAULT}"

if [[ ! -d "$PENPOT_REPO" ]]; then
  echo "Penpot repo not found at: $PENPOT_REPO" >&2
  echo "Set PENPOT_REPO or pass --repo PATH." >&2
  exit 1
fi
if [[ ! -f "$PENPOT_REPO/manage.sh" || ! -f "$PENPOT_REPO/$COMPOSE_REL" ]]; then
  echo "Path does not look like a Penpot repo: $PENPOT_REPO" >&2
  echo "Expected manage.sh and $COMPOSE_REL." >&2
  exit 1
fi
PENPOT_REPO="$(cd "$PENPOT_REPO" && pwd)"

VALID_SERVICES=(frontend backend storybook exporter mcp)
IFS=',' read -ra REQUESTED <<<"$SERVICES"
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  echo "No services selected." >&2; exit 1
fi
for s in "${REQUESTED[@]}"; do
  match=false
  for v in "${VALID_SERVICES[@]}"; do
    [[ "$s" == "$v" ]] && match=true
  done
  if ! $match; then
    echo "Unknown service '$s'. Valid: ${VALID_SERVICES[*]}" >&2; exit 1
  fi
done
has_service() { [[ ",$SERVICES," == *",$1,"* ]]; }

# Every docker compose call must run from the Penpot repo: the compose file
# uses ${PWD} to bind-mount the source tree into the container.
cd "$PENPOT_REPO"

if [[ ! $(docker ps -f "name=$CONTAINER" -q) ]]; then
  echo ">> starting devenv compose..."
  ./manage.sh start-devenv
  echo ">> waiting 5s for containers to be ready..."
  sleep 5
fi

KEEP_AUX=()
if [[ -n "$AUX_KEEP" ]]; then
  IFS=',' read -ra KEEP_AUX <<<"$AUX_KEEP"
fi
for a in "${KEEP_AUX[@]}"; do
  match=false
  for v in "${ALL_AUX[@]}"; do
    [[ "$a" == "$v" ]] && match=true
  done
  if ! $match; then
    echo "Unknown aux container '$a'. Valid: ${ALL_AUX[*]}" >&2; exit 1
  fi
done

STOP_AUX_LIST=()
START_AUX_LIST=()
for a in "${ALL_AUX[@]}"; do
  match=false
  for k in "${KEEP_AUX[@]}"; do
    [[ "$a" == "$k" ]] && match=true
  done
  if $match; then
    START_AUX_LIST+=("$a")
  else
    STOP_AUX_LIST+=("$a")
  fi
done

if [[ ${#STOP_AUX_LIST[@]} -gt 0 ]]; then
  echo ">> stopping aux containers: ${STOP_AUX_LIST[*]}"
  docker compose -p "$DEVENV_PNAME" -f "$COMPOSE_REL" \
    stop -t 2 "${STOP_AUX_LIST[@]}" >/dev/null 2>&1 || true
fi
if [[ ${#START_AUX_LIST[@]} -gt 0 ]]; then
  echo ">> starting aux containers: ${START_AUX_LIST[*]}"
  docker compose -p "$DEVENV_PNAME" -f "$COMPOSE_REL" \
    start "${START_AUX_LIST[@]}" >/dev/null 2>&1 || true
fi

REMOTE=$(mktemp)
trap 'rm -f "$REMOTE"' EXIT

{
  cat <<'HEAD'
#!/usr/bin/env bash
set -e
sudo chown penpot:users /home/penpot 2>/dev/null || true
cd ~
source ~/.bashrc

HEAD

  if has_service frontend || has_service storybook; then
    echo 'echo "[run-light] frontend setup..."'
    echo '(cd ~/penpot/frontend && ./scripts/setup)'
  fi
  if has_service exporter; then
    echo 'echo "[run-light] exporter setup..."'
    echo '(cd ~/penpot/exporter && ./scripts/setup)'
  fi
  if has_service mcp; then
    echo 'echo "[run-light] mcp setup + build..."'
    echo '(cd ~/penpot/mcp && ./scripts/setup && pnpm run build)'
  fi

  cat <<'MID'

tmux -2 new-session -d -s penpot
IDX=0
add_window() {
  local name=$1 cmd=$2
  if [[ $IDX -eq 0 ]]; then
    tmux rename-window -t penpot:0 "$name"
  else
    tmux new-window -t "penpot:$IDX" -n "$name"
  fi
  tmux send-keys -t "penpot:$IDX" "$cmd" Enter
  IDX=$((IDX+1))
}

MID

  if has_service frontend; then
    if $MINIMAL_FRONTEND; then
      shadow_cmd='clojure -M:dev:shadow-cljs watch main worker'
    else
      shadow_cmd='pnpm run watch:app:main'
    fi
    if $CLEAN; then
      # Match ./scripts/watch app exactly: nuke caches, rebuild wasm.
      prefix='pnpm run clear:shadow-cache && pnpm run clear:wasm && pnpm run build:wasm'
    else
      # Keep shadow-cljs cache; only build wasm if the artifact is missing.
      prefix='{ [ -f resources/public/js/render-wasm.wasm ] || pnpm run build:wasm; }'
    fi
    echo "add_window 'frontend' 'cd ~/penpot/frontend && ${prefix} && pnpm exec concurrently --kill-others-on-fail \"pnpm run watch:app:assets\" \"${shadow_cmd}\" \"pnpm run watch:app:libs\"'"
  fi
  if has_service storybook; then
    echo "add_window 'storybook' 'cd ~/penpot/frontend && ./scripts/watch storybook'"
  fi
  if has_service exporter; then
    cat <<'EOF'
add_window 'exporter' 'cd ~/penpot/exporter && rm -f target/app.js* && ./scripts/watch'
tmux split-window -v -t "penpot:$((IDX-1))"
tmux send-keys -t "penpot:$((IDX-1))" 'cd ~/penpot/exporter && ./scripts/wait-and-start.sh' Enter
EOF
  fi
  if has_service backend; then
    echo "add_window 'backend' 'cd ~/penpot/backend && ./scripts/start-dev'"
  fi
  if has_service mcp; then
    echo "add_window 'mcp' 'cd ~/penpot/mcp && ./scripts/start-mcp-devenv'"
  fi

  cat <<'TAIL'

tmux select-window -t penpot:0
tmux -2 attach-session -t penpot
TAIL
} > "$REMOTE"

docker cp "$REMOTE" "$CONTAINER:/tmp/run-light.sh" >/dev/null
docker exec "$CONTAINER" chmod +x /tmp/run-light.sh
docker exec "$CONTAINER" chown penpot:users /tmp/run-light.sh

echo ">> penpot repo     : $PENPOT_REPO"
echo ">> services        : $SERVICES"
echo ">> aux kept up     : ${START_AUX_LIST[*]:-(none)}"
echo ">> JAVA_OPTS       : $JAVA_OPTS"
echo ">> minimal-frontend: $MINIMAL_FRONTEND"
echo ">> clean rebuild   : $CLEAN"
echo ">> attaching to tmux (Ctrl-b d to detach)"

# Both vars are set: backend's _env clobbers JAVA_OPTS, but the JVM always
# honors _JAVA_OPTIONS, so the heap cap survives.
exec docker exec -ti \
  -e JAVA_OPTS="$JAVA_OPTS" \
  -e _JAVA_OPTIONS="$JAVA_OPTS" \
  -e PENPOT_PLUGIN_DEV="$PENPOT_PLUGIN_DEV" \
  "$CONTAINER" sudo -EH -u penpot /tmp/run-light.sh
