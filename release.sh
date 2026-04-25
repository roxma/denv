#!/bin/bash
set -euo pipefail

tag=$(git describe --tags --abbrev=0)
notes=$(git tag -l --format='%(contents)' "$tag")

RELEASE_DIR=release
[ ! -d "$RELEASE_DIR" ] || rm -r "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "=== Building $tag ==="

for arch in amd64 arm64 riscv64; do
  case $arch in
    amd64)   uname_arch=x86_64;;
    arm64)   uname_arch=aarch64;;
    riscv64) uname_arch=riscv64;;
  esac
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch \
    go build -ldflags="-s -w" -o "$RELEASE_DIR"/denv_linux_$uname_arch .
done

echo "=== Uploading to GitHub ==="

git push github "$tag"
gh release create "$tag" "$RELEASE_DIR"/denv_linux_* \
  --title "$tag" \
  --notes "$notes"

echo "=== Done ==="
