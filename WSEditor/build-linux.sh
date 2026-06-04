#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$project_root/build"
install_prefix="${HOME}/.local"

cmake -S "$project_root" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir"
cmake --install "$build_dir" --prefix "$install_prefix"

if [[ ":$PATH:" != *":$install_prefix/bin:"* ]]; then
  echo "Installed wse to $install_prefix/bin"
  echo "If needed, add this to your shell profile:"
  echo "export PATH=\"$install_prefix/bin:\$PATH\""
fi
