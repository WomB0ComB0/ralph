#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
TARGET="$INSTALL_DIR/ralph"

echo "Installing Ralph..."
echo "Repo root: $REPO_ROOT"
echo "Target: $TARGET"

mkdir -p "$INSTALL_DIR"

# Create symlink
ln -sf "$REPO_ROOT/ralph.sh" "$TARGET"

# Make executable
chmod +x "$REPO_ROOT/ralph.sh"

echo "✅ Ralph successfully installed to $TARGET"
echo "You can now run 'ralph' from anywhere."
