# run-penpot-light

Lightweight launcher for the [Penpot](https://github.com/penpot/penpot) development environment.

Penpot's default `./manage.sh run-devenv` spins up **four JVMs** inside the
devenv container (`frontend watch`, `frontend storybook`, `exporter`, `backend`)
plus the Storybook Vite dev server and a handful of auxiliary services
(MinIO, Postgres, Valkey/Redis, Mailcatcher, LDAP). On most machines this
quickly pushes Java RAM usage very high — overkill if you're only
iterating on part of the stack.

This script lets you pick which services to start, caps each JVM's heap to
sensible dev defaults, and stops auxiliary containers you probably don't
need. It can help you save several GB of memory for frontend + backend work.

No changes to the Penpot source tree are required. Everything lives in this
external folder.

## Requirements

- A local clone of the Penpot repository.
- Docker + `docker compose` already working with the Penpot devenv image
  (pull/build it with `./manage.sh pull-devenv` or `./manage.sh build-devenv --local`).

## Install

```bash
git clone <this-folder> ~/projects/run-penpot-light
chmod +x ~/projects/run-penpot-light/run-devenv-light.sh ~/projects/run-penpot-light/stop-devenv-light.sh
```

## Configuration

The script needs to know where your local Penpot clone is. Either:

- Export an env var: `export PENPOT_REPO=~/code/penpot`
- Or pass `-p` / `--repo` on every call.

If neither is set, it defaults to `$HOME/projects/penpot`.

## Usage

```text
Usage: ./run-devenv-light.sh [options]

Options:
  -p, --repo PATH        Path to the local Penpot repository.
                         Default: $PENPOT_REPO or $HOME/projects/penpot
  -s, --services LIST    Comma-separated list of services to start.
                         Available: frontend, backend, storybook, exporter, mcp
                         Default: frontend,backend
  -j, --java-opts OPTS   JVM heap/options applied to every JVM (backend +
                         shadow-cljs). Default: "-Xmx768m -Xms50m"
      --minimal-frontend Skip the 'storybook' shadow-cljs target in the
                         frontend watch (only main + worker). Extra RAM
                         saving if you don't use Storybook.
      --clean            Wipe shadow-cljs + wasm caches and rebuild wasm
                         from scratch. SLOW — the wasm rebuild takes
                         several minutes. Default: off (reuse existing
                         caches; only build wasm if its artifact is
                         missing).
      --aux LIST         Comma-separated list of auxiliary containers to
                         keep running. Available: mailer, ldap.
                         Default: none — both are stopped to save RAM.
  -h, --help             Show this help.
```

### Recommended preset: frontend + backend + mailcatcher, no Storybook

This is the typical dev configuration: edit frontend + backend, receive
transactional emails locally via Mailcatcher (UI at http://localhost:1080),
and skip every Storybook overhead (both the Vite dev server and the
shadow-cljs `storybook` target). Copy-paste:

```bash
./run-devenv-light.sh --aux mailer --minimal-frontend
```

Or, if you want to keep the shadow-cljs Storybook target compiling in
the background (slightly slower iteration, no functional difference if
you don't open Storybook):

```bash
./run-devenv-light.sh --aux mailer
```

### More examples

```bash
# Frontend + backend, 768m heap per JVM (default — no mailer, no ldap)
./run-devenv-light.sh

# Only backend
./run-devenv-light.sh -s backend

# Frontend + backend + exporter
./run-devenv-light.sh -s frontend,backend,exporter

# Frontend only, skipping Storybook compilation in shadow-cljs
./run-devenv-light.sh -s frontend --minimal-frontend

# Keep both aux containers up (mailer + ldap)
./run-devenv-light.sh --aux mailer,ldap

# Tighter heap via env var
JAVA_OPTS="-Xmx512m -Xms50m" ./run-devenv-light.sh

# Different Penpot clone location
PENPOT_REPO=~/code/penpot ./run-devenv-light.sh
./run-devenv-light.sh -p ~/code/penpot -s backend
```

## Services

| Service     | What it runs                                                       |
| ----------- | ------------------------------------------------------------------ |
| `frontend`  | `./scripts/watch app` (shadow-cljs `main worker storybook`)        |
| `backend`   | `./scripts/start-dev` (Clojure backend)                            |
| `storybook` | `./scripts/watch storybook` (Storybook Vite dev server)            |
| `exporter`  | `./scripts/watch` + `wait-and-start.sh` (PDF/PNG export service)   |
| `mcp`       | `./scripts/start-mcp-devenv` (MCP server, also enables the plugin) |

Each service runs in its own tmux window inside the `penpot-devenv-main`
container, on the `penpot` session — the same convention Penpot's own
`run-devenv` uses, so you can detach with `Ctrl-b d` and re-attach with:

```bash
cd $PENPOT_REPO && ./manage.sh run-devenv-shell tmux attach -t penpot
```

## How it caps memory

Penpot's `backend/scripts/_env` re-exports `JAVA_OPTS` with its own flags
(without `-Xmx`), which would overwrite any limit passed via `JAVA_OPTS`
from outside. To work around this, the script also exports `_JAVA_OPTIONS`,
a JVM-level variable the runtime always honors. As a result the backend
prints a one-time `Picked up _JAVA_OPTIONS: ...` line at startup — that's
expected.

shadow-cljs JVMs (frontend/storybook/exporter) honor `JAVA_OPTS` directly,
so the same value is applied via both vars.

## What `--minimal-frontend` does

Penpot's `watch:app` script runs:

```
clojure -M:dev:shadow-cljs watch main worker storybook
```

i.e. it compiles the Storybook ClojureScript target even when you aren't
running Storybook. `--minimal-frontend` swaps that for:

```
clojure -M:dev:shadow-cljs watch main worker
```

skipping the Storybook compile entirely. Use it when you don't open
Storybook locally.

## Build caches (why startup is fast)

Penpot's own `./scripts/watch app` always runs these three steps before
starting the watcher:

1. `clear:shadow-cache` — `rm -rf .shadow-cljs` (forces a full CLJS recompile,
   ~1 min).
2. `clear:wasm` — `cargo clean` on the Rust crate (wipes the entire Rust
   target dir, including Skia bindings).
3. `build:wasm` — rebuilds the Rust/WASM canvas renderer. This is the
   expensive one: **several minutes**, because Skia bindings get recompiled
   from scratch.

That's fine for a one-shot daily devenv, but painful if you start/stop
the stack often. By default this launcher **skips all three** and reuses
the existing caches. The only exception is `build:wasm`, which is run
automatically the very first time (when
`frontend/resources/public/js/render-wasm.wasm` doesn't exist yet).

If you actually need a clean rebuild — typically after:

- editing Rust code under `render-wasm/`
- pulling changes that touch wasm/cljs deps
- a previous build was killed mid-way and left corrupt artifacts

…pass `--clean`:

```bash
./run-devenv-light.sh --clean
```

This restores the exact behavior of `./scripts/watch app`.

## Stopping the devenv

When you're done, stop the containers with the bundled stop script — no
need to `cd` into the Penpot repo:

```bash
./stop-devenv-light.sh
```

It honors the same `PENPOT_REPO` env var / `--repo` flag as the launcher:

```bash
PENPOT_REPO=~/code/penpot ./stop-devenv-light.sh
./stop-devenv-light.sh -p ~/code/penpot
```

It runs `docker compose stop -t 2` against the `penpotdev` compose project,
i.e. the exact equivalent of `./manage.sh stop-devenv`. Volumes and data
are preserved; next run starts from where you left off.

## Auxiliary containers

By default the script stops `mailer` and `ldap` after the devenv is up.
These are only useful for testing SMTP and LDAP-based logins, which most
day-to-day development doesn't touch. Use `--aux` to keep specific ones up:

```bash
./run-devenv-light.sh --aux mailer          # mailcatcher only (recommended)
./run-devenv-light.sh --aux mailer,ldap     # both
```

The script also (re)starts the listed containers in case they were stopped
in a previous run, so you can freely switch between configurations.

Mailcatcher UI: http://localhost:1080

`postgres`, `redis` (Valkey) and `minio` stay up because the backend needs
them.

## Troubleshooting

- **`Penpot repo not found at: …`** — set `PENPOT_REPO` or pass `--repo PATH`.
- **`Path does not look like a Penpot repo`** — the path doesn't contain
  `manage.sh` and `docker/devenv/docker-compose.yaml`. Double-check it points
  at a Penpot clone, not its parent.
- **Container not running** — the script calls `./manage.sh start-devenv`
  for you on first run; if you've never pulled the devenv image, run
  `./manage.sh pull-devenv` from the Penpot repo first.
- **Backend OOM** — bump the heap, e.g. `JAVA_OPTS="-Xmx1500m -Xms50m"`.
- **Detach/re-attach** — `Ctrl-b d` to detach; re-attach with
  `./manage.sh run-devenv-shell tmux attach -t penpot`.
