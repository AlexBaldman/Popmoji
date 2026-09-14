#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d dist/Popmoji.app ]; then bash scripts/build.sh; fi
open dist/Popmoji.app
