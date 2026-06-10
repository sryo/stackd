#!/bin/bash
# Concatenate Runtime/src/*.js (sorted) into the served Runtime/api.js artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

{
  echo "// generated from Runtime/src/ — edit those, then run scripts/build-runtime.sh"
  echo "// Concatenation of Runtime/src/*.js in sorted (numeric-prefix) order."
  cat Runtime/src/*.js
} > Runtime/api.js
