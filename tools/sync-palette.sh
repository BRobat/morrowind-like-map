#!/bin/sh
# Copies shared/palette.json into every platform that bundles it.
set -e
cd "$(dirname "$0")/.."
cp shared/palette.json apple/Sources/MorrowindMapCore/Resources/palette.json
echo "palette synced"
