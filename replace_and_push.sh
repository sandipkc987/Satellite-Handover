#!/usr/bin/env bash

set -e

REPO_URL="https://github.com/sandipkc987/Satellite-Handover.git"
LOCAL_DIR="C:\Users\sandy\AppData\Local\Temp\Satellite-Handover-replace"
BRANCH="main"

echo "Cloning repository..."
rm -rf "$LOCAL_DIR"
git clone --branch "$BRANCH" "$REPO_URL" "$LOCAL_DIR"

cd "$LOCAL_DIR"
echo "Removing existing tracked files..."
git rm -r --cached -q . || true
git rm -r -f . || true
git clean -fdx

echo "Creating new files..."
mkdir -p "$(dirname "README.md")"
cat > "README.md" <<'EOF'
# Satellite-Handover\n\nRepository replaced with new content.
EOF

mkdir -p "$(dirname "main.m")"
cat > "main.m" <<'EOF'
% Example entry point for Satellite-Handover project\ndisp('Hello from new repository content.');\n
EOF

git add --all
git commit -m "Replace repository contents via automated script"

echo "Pushing to remote..."
git push origin "$BRANCH"

echo "Done. Repository updated at https://github.com/sandipkc987/Satellite-Handover.git (branch main)."
