#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

deb="${1:-}"
if [[ -z "$deb" ]]; then
  deb="$(find packages -maxdepth 1 -type f -name '*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {$1=""; sub(/^ /,""); print; exit}')"
fi

if [[ -z "$deb" || ! -f "$deb" ]]; then
  echo "No .deb found. Build PadDisplay first or pass a .deb path."
  exit 1
fi

version="$(dpkg-deb -f "$deb" Version)"
arch="$(dpkg-deb -f "$deb" Architecture)"
outdir="release"
mkdir -p "$outdir"

name="PadDisplay_${version}_${arch}.deb"
cp -f "$deb" "$outdir/$name"
(
  cd "$outdir"
  sha256sum "$name" > "$name.sha256"
)

echo "Prepared:"
echo "  $outdir/$name"
echo "  $outdir/$name.sha256"

if [[ "${2:-}" == "--publish" || "${1:-}" == "--publish" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) is required for --publish."
    exit 1
  fi
  tag="v${version}"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$outdir/$name" "$outdir/$name.sha256" --clobber
  else
    gh release create "$tag" "$outdir/$name" "$outdir/$name.sha256" --title "PadDisplay ${version}" --notes "PadDisplay ${version}"
  fi
  echo "Published GitHub release $tag"
fi
