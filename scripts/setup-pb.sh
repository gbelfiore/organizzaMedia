#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PB_DIR="$ROOT/pocketbase"
VERSION="0.22.34"
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  ZIP="pocketbase_${VERSION}_darwin_arm64.zip"
else
  ZIP="pocketbase_${VERSION}_darwin_amd64.zip"
fi
URL="https://github.com/pocketbase/pocketbase/releases/download/v${VERSION}/${ZIP}"

mkdir -p "$PB_DIR"
if [ ! -x "$PB_DIR/pocketbase" ]; then
  echo "Scarico PocketBase $VERSION..."
  curl -fsSL "$URL" -o "$PB_DIR/pb.zip"
  unzip -o "$PB_DIR/pb.zip" -d "$PB_DIR"
  rm -f "$PB_DIR/pb.zip"
  chmod +x "$PB_DIR/pocketbase"
fi

EMAIL="${PB_ADMIN_EMAIL:-admin@foto.local}"
PASS="${PB_ADMIN_PASSWORD:-fotoadmin}"
"$PB_DIR/pocketbase" migrate up
"$PB_DIR/pocketbase" admin create "$EMAIL" "$PASS" 2>/dev/null || true
echo "PocketBase pronto in $PB_DIR"
