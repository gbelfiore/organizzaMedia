#!/bin/zsh -l

set -e
set -u
set -o pipefail

cd "$(dirname "$0")"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  source "$NVM_DIR/nvm.sh"
fi
if [[ -f .nvmrc ]]; then
  nvm use >/dev/null 2>&1 || nvm use 22 >/dev/null 2>&1 || true
else
  nvm use 22 >/dev/null 2>&1 || true
fi

if ! command -v npm >/dev/null 2>&1; then
  for bin in "$NVM_DIR"/versions/node/*/bin(N); do
    PATH="$bin:$PATH"
  done
fi

if ! command -v npm >/dev/null 2>&1; then
  echo ""
  echo "npm non trovato. Apri Cursor e lancia da lì: npm run dev"
  echo ""
  read "?Premi Invio per chiudere..."
  exit 1
fi

if [[ ! -d node_modules || ! -d server/node_modules || ! -d web/node_modules || ! -x pocketbase/pocketbase ]]; then
  echo "Dipendenze o PocketBase mancanti, eseguo setup..."
  npm run setup
fi

PORTAL_URL="http://127.0.0.1:5173/"

open_portal() {
  if [[ -d "/Applications/Google Chrome.app" ]]; then
    open -a "Google Chrome" "$PORTAL_URL" 2>/dev/null && return 0
    osascript -e "tell application \"Google Chrome\" to activate" \
      -e "tell application \"Google Chrome\" to open location \"$PORTAL_URL\"" 2>/dev/null && return 0
  fi
  open "$PORTAL_URL" 2>/dev/null || true
}

free_port() {
  local pids
  pids="$(lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 0.2
  fi
}

cleanup() {
  trap - EXIT INT TERM
  kill 0 2>/dev/null || true
}

trap cleanup EXIT INT TERM

free_port 5173
free_port 3001
free_port 8090

echo ""
echo "Avvio Organizza foto (PocketBase + API + Vite)..."
echo "Chrome si aprirà su $PORTAL_URL quando è pronto."
echo "Chiudi questa finestra per fermare tutto."
echo ""

npm run pb &
npm run server &
npm run web &

for _ in {1..120}; do
  if curl -fsS "http://127.0.0.1:5173/" >/dev/null 2>&1; then
    open_portal
    break
  fi
  sleep 0.5
done

wait
