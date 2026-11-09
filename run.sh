#!/bin/bash
# Build, then (re)launch the app.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh "${1:-release}"
pkill -x NotchOrbit 2>/dev/null || true
open build/NotchOrbit.app
