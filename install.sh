#!/usr/bin/env bash
set -euo pipefail

REPO="zieka/bru"
INSTALL_DIR="/usr/local/bin"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ASSET="bru-darwin-aarch64" ;;
  x86_64)        ASSET="bru-darwin-x86_64" ;;
  *)
    echo "Error: unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

# Detect OS
OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
  echo "Error: bru currently only supports macOS (detected: $OS)" >&2
  exit 1
fi

echo "Installing bru ($ASSET)..."

# Get the latest release download URL
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o "https://.*/${ASSET}" \
  | head -1)

if [ -z "$DOWNLOAD_URL" ]; then
  echo "Error: could not find release asset $ASSET" >&2
  exit 1
fi

# Download to temp file
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -fsSL -o "$TMP" "$DOWNLOAD_URL"
chmod +x "$TMP"

# Install
if [ -w "$INSTALL_DIR" ]; then
  mv "$TMP" "$INSTALL_DIR/bru"
else
  echo "Need sudo to install to $INSTALL_DIR"
  sudo mv "$TMP" "$INSTALL_DIR/bru"
fi

echo "bru installed to $INSTALL_DIR/bru"
echo "Run 'bru --help' to get started."
