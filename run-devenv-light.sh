#!/usr/bin/env bash
# Lightweight launcher for the Penpot devenv.
#
# Lets you pick which services to start so you don't pay the RAM cost of
# everything when you're only iterating on part of the stack.
#
# Defaults: frontend + backend, heap capped at 768m per JVM, ldap/mailer stopped.
#
# Targets the ws0 workspace of Penpot's parallel-workspaces layout (the live
# repo at $PENPOT_REPO).

set -e

DEFAULTS_ENV_REL="docker/devenv/defaults.env"
INFRA_COMPOSE_REL="docker/devenv/docker-compose.infra.yml"
MAIN_COMPOSE_REL="docker/devenv/docker-compose.main.yml"
INFRA_PNAME="penpotdev-infra"
INSTANCE="ws0"
INSTANCE_PNAME="penpotdev-${INSTANCE}"
NETWORK_NAME="penpot_shared"
CONTAINER="penpot-devenv-${INSTANCE}-main"

PENPOT_REPO="${PENPOT_REPO:-$HOME/projects/penpot}"
SERVICES="frontend,backend"
JAVA_OPTS_DEFAULT="-Xmx768m -Xms50m"
AUX_KEEP=""
MINIMAL_FRONTEND=false
CLEAN=false
RECREATE=false
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
                         existing caches and only builds wasm if an artifact
                         is missing.
      --aux LIST         Comma-separated list of auxiliary containers to keep
                         running. Available: mailer, ldap.
                         Default: (none — both are stopped to save RAM)
      --recreate         Force-remove the ws0 main container before starting so
                         it is recreated fresh on the current network. Use this
                         if the container won't come up (Exited) after a
                         './manage.sh drop-devenv', a Docker restart, or a
                         DNS/network error in the logs (nginx "host not found in
                         upstream"). Data volumes are preserved.
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
    --recreate)          RECREATE=true; shift;;
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
for f in manage.sh "$DEFAULTS_ENV_REL" "$INFRA_COMPOSE_REL" "$MAIN_COMPOSE_REL"; do
  if [[ ! -f "$PENPOT_REPO/$f" ]]; then
    echo "Path does not look like a current Penpot repo: $PENPOT_REPO" >&2
    echo "Missing expected file: $f" >&2
    exit 1
  fi
done
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

STORYBOOK_HOST_PORT=0
if has_service storybook; then
  STORYBOOK_HOST_PORT=3451
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

# Every docker compose call must run from the Penpot repo: the compose files
# resolve relative paths (Caddyfile, postgresql.conf, etc.) from there.
cd "$PENPOT_REPO"

infra_compose() {
  env -i HOME="$HOME" PATH="$PATH" PWD="$PWD" \
    docker compose -p "$INFRA_PNAME" \
      --env-file "$DEFAULTS_ENV_REL" \
      -f "$INFRA_COMPOSE_REL" \
      "$@"
}

# Match manage.sh's instance-env-overrides for ws0: Compose gives shell-env
# precedence over --env-file, so these override the defaults.env baseline.
# We use the same overrides manage.sh would compute for ws0, so volumes and
# container names line up with `./manage.sh run-devenv`.
main_compose() {
  env -i HOME="$HOME" PATH="$PATH" PWD="$PWD" \
    CURRENT_USER_ID="$(id -u)" \
    PENPOT_SOURCE_PATH="$PENPOT_REPO" \
    PENPOT_MAIN_CONTAINER_NAME="$CONTAINER" \
    PENPOT_USER_DATA_VOLUME="penpotdev_${INSTANCE}_user_data" \
    PENPOT_PUBLIC_URI="https://localhost:3449" \
    PENPOT_REDIS_URI="redis://valkey/0" \
    PENPOT_PUBLIC_HTTPS_PORT=3449 \
    PENPOT_PUBLIC_HTTP_PORT=3450 \
    PENPOT_STORYBOOK_PORT="$STORYBOOK_HOST_PORT" \
    PENPOT_MCP_SERVER_PORT=4401 \
    PENPOT_MCP_REPL_PORT=4403 \
    SERENA_EXTERNAL_PORT=14181 \
    SERENA_DASHBOARD_EXTERNAL_PORT=14182 \
    SHADOW_SERVER_URL="wss://localhost:3449" \
    PENPOT_TENANT="devenv-${INSTANCE}" \
    PENPOT_TMUX_ATTACH=false \
    docker compose -p "$INSTANCE_PNAME" \
      --env-file "$DEFAULTS_ENV_REL" \
      -f "$MAIN_COMPOSE_REL" \
      "$@"
}

is_main_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]]
}

print_main_failure() {
  local state
  state="$(docker inspect -f 'status={{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}} error={{.State.Error}}' "$CONTAINER" 2>/dev/null || true)"
  echo "main container is not running: ${state:-container not found}" >&2
  echo "last $CONTAINER logs:" >&2
  docker logs --tail 80 "$CONTAINER" >&2 || true
}

wait_for_main_container() {
  local deadline state settle_deadline

  echo ">> waiting for main container to be ready..."
  deadline=$(( SECONDS + 30 ))
  while ! is_main_running; do
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
    if [[ "$state" == "exited" || "$state" == "dead" ]]; then
      print_main_failure
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      print_main_failure
      exit 1
    fi
    sleep 1
  done

  # Nginx/Caddy failures can happen just after Docker reports the container as
  # running. Keep the old fast path, but prove it survives initial service boot.
  settle_deadline=$(( SECONDS + 5 ))
  while (( SECONDS < settle_deadline )); do
    if ! is_main_running; then
      print_main_failure
      exit 1
    fi
    sleep 1
  done
}

# Compose files declare the network as external; create it if missing (same as
# manage.sh's ensure-devenv-network).
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  echo ">> creating docker network $NETWORK_NAME..."
  docker network create "$NETWORK_NAME" >/dev/null
fi

# --recreate: nuke the main container (running or a stale Exited one) so the
# next `compose up` builds it fresh on the current network. `compose up`
# reuses an existing container by name even when it's a networkless zombie
# left behind by a drop-devenv / Docker restart, which then dies on nginx's
# DNS lookup — removing it is the escape hatch. Volumes are untouched.
if $RECREATE; then
  echo ">> --recreate: removing $CONTAINER so it is rebuilt fresh..."
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

if [[ -z $(docker ps -f "name=^${CONTAINER}$" -q) ]]; then
  echo ">> bringing shared infra up ($INFRA_PNAME)..."
  infra_compose up -d >/dev/null

  echo ">> bringing main container up ($INSTANCE_PNAME / $CONTAINER)..."
  main_compose up -d main >/dev/null

  wait_for_main_container
  # Fresh user_data volume mounts come up root-owned; same fix manage.sh
  # applies in start-instance.
  docker exec "$CONTAINER" sudo chown penpot:users /home/penpot 2>/dev/null || true
fi

# mailer + ldap moved into the infra compose; stop/start them there.
if [[ ${#STOP_AUX_LIST[@]} -gt 0 ]]; then
  echo ">> stopping aux containers: ${STOP_AUX_LIST[*]}"
  infra_compose stop -t 2 "${STOP_AUX_LIST[@]}" >/dev/null 2>&1 || true
fi
if [[ ${#START_AUX_LIST[@]} -gt 0 ]]; then
  echo ">> starting aux containers: ${START_AUX_LIST[*]}"
  infra_compose start "${START_AUX_LIST[@]}" >/dev/null 2>&1 || true
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
      # Keep shadow-cljs cache; only build wasm if an artifact is missing.
      # shared.js is also build output, and the cljs build requires it.
      prefix='{ { [ -f resources/public/js/render-wasm.wasm ] && [ -f src/app/render_wasm/api/shared.js ]; } || pnpm run build:wasm; }'
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

if ! is_main_running; then
  print_main_failure
  exit 1
fi

docker cp "$REMOTE" "$CONTAINER:/tmp/run-light.sh" >/dev/null
docker exec "$CONTAINER" chmod +x /tmp/run-light.sh
docker exec "$CONTAINER" chown penpot:users /tmp/run-light.sh

echo ">> penpot repo     : $PENPOT_REPO"
echo ">> instance        : $INSTANCE ($CONTAINER)"
echo ">> services        : $SERVICES"
echo ">> aux kept up     : ${START_AUX_LIST[*]:-(none)}"
echo ">> storybook port  : ${STORYBOOK_HOST_PORT}"
echo ">> JAVA_OPTS       : $JAVA_OPTS"
echo ">> minimal-frontend: $MINIMAL_FRONTEND"
echo ">> clean rebuild   : $CLEAN"
echo ">> recreate main   : $RECREATE"
echo ">> attaching to tmux (Ctrl-b d to detach)"

# Both vars are set: backend's _env clobbers JAVA_OPTS, but the JVM always
# honors _JAVA_OPTIONS, so the heap cap survives.
exec docker exec -ti \
  -e JAVA_OPTS="$JAVA_OPTS" \
  -e _JAVA_OPTIONS="$JAVA_OPTS" \
  -e PENPOT_PLUGIN_DEV="$PENPOT_PLUGIN_DEV" \
  "$CONTAINER" sudo -EH -u penpot /tmp/run-light.sh
