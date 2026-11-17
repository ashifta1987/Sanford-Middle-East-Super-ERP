#!/usr/bin/env bash
# Local stack for the e2e suites (LOCAL ONLY): Postgres :5433 (embedded-postgres), PostgREST :3000, gateway :54321, Vite :5173.
#   scripts/local-stack/stack.sh start [--no-vite] | stop | status | pin-postgrest <postgrest binary>
# Env (defaults in brackets):
#   LOCALSTACK_DIR  [~/erp-work/localstack]   folder with node_modules (embedded-postgres), pgdata, logs
#   POSTGREST_BIN   [~/erp-work/tools/postgrest]  pinned PostgREST (see pin-postgrest)
# Why pin-postgrest: the macOS PostgREST release links libpq from Homebrew (/opt/homebrew/opt/libpq/lib/libpq.5.dylib). On a Mac
# without Homebrew it does not start. pin-postgrest copies the binary next to the libpq (+ libssl, libcrypto, krb5) that ships with
# embedded-postgres, points the binary at it (install_name_tool) and signs it ad hoc, so the stack needs nothing from Homebrew.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LS="${LOCALSTACK_DIR:-$HOME/erp-work/localstack}"
PGRST="${POSTGREST_BIN:-$HOME/erp-work/tools/postgrest}"
pgctl() { find "$LS/node_modules/@embedded-postgres" -name pg_ctl -type f | head -1; }
port_up() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

case "${1:-}" in
  pin-postgrest)
    src="${2:?give the postgrest binary to pin}"
    tools="$(dirname "$PGRST")"; mkdir -p "$tools/lib"
    lib="$(dirname "$(find "$LS/node_modules/@embedded-postgres" -name 'libpq.5.dylib' | head -1)")"
    cp "$src" "$PGRST"; cp "$lib"/*.dylib "$tools/lib/"
    old="$(otool -L "$PGRST" | awk '/libpq\.5\.dylib/ {print $1; exit}')"
    [ -n "$old" ] && install_name_tool -change "$old" @executable_path/lib/libpq.5.dylib "$PGRST"
    codesign --force -s - "$PGRST"
    "$PGRST" --version ;;
  start)
    port_up 5433 || "$(pgctl)" -D "$LS/pgdata" -l "$LS/pg.log" -o "-p 5433" start >/dev/null
    port_up 3000 || (cd "$LS" && nohup "$PGRST" "$REPO/scripts/local-stack/postgrest.conf" > "$LS/postgrest.log" 2>&1 &)
    port_up 54321 || (cd "$REPO" && nohup node scripts/local-stack/gateway.mjs > "$LS/gateway.log" 2>&1 &)
    if [ "${2:-}" != "--no-vite" ]; then
      port_up 5173 || (cd "$REPO" && VITE_SUPABASE_URL=http://127.0.0.1:54321 VITE_SUPABASE_ANON_KEY=local nohup npx vite --host 127.0.0.1 --port 5173 --strictPort > "$LS/vite.log" 2>&1 &)
    fi
    sleep 4; "$0" status ;;
  stop)
    pkill -f "vite --host 127.0.0.1 --port 5173" || true
    pkill -f "node scripts/local-stack/gateway.mjs" || true
    pkill -f "$PGRST" || true
    "$(pgctl)" -D "$LS/pgdata" stop -m fast >/dev/null 2>&1 || true
    "$0" status ;;
  status)
    for p in 5433:postgres 3000:postgrest 54321:gateway 5173:vite; do port_up "${p%%:*}" && echo "up    ${p#*:} :${p%%:*}" || echo "down  ${p#*:} :${p%%:*}"; done ;;
  *) echo "usage: $0 start [--no-vite] | stop | status | pin-postgrest <binary>"; exit 2 ;;
esac

