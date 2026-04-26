#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh
shellcheck install.sh
shfmt -d -i 4 -ci install.sh
git diff --check -- install.sh README.md
bash tests/test_forward.sh
