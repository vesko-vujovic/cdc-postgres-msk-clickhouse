#!/usr/bin/env bash
# Download the Debezium PostgreSQL connector and repackage it as a ZIP,
# because MSK Connect custom plugins must be ZIP or JAR.
set -euo pipefail

VERSION="${1:?usage: build_plugin.sh <debezium-version, e.g. 3.6.2.Final>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
ZIP="$OUT/debezium-connector-postgres-$VERSION.zip"
URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/$VERSION/debezium-connector-postgres-$VERSION-plugin.tar.gz"

if [ -f "$ZIP" ]; then
  echo "plugin already built: $ZIP"
  exit 0
fi

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $URL"
curl -fsSL "$URL" -o "$TMP/plugin.tar.gz"
tar -xzf "$TMP/plugin.tar.gz" -C "$TMP"
(cd "$TMP" && zip -qr "$ZIP" debezium-connector-postgres)
echo "built $ZIP"
