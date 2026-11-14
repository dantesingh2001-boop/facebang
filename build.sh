#!/usr/bin/env bash
# Builds the single-file deliverable: src + lib -> facebang.lua
# The raw URL must stay one file, because an executor cannot require() a
# relative path fetched over HttpGet.
set -euo pipefail
cd "$(dirname "$0")"

OUT=facebang.lua
TMP=$(mktemp)

# lib files end with "return Module"; keep the module name so the inline
# wrapper can hand it back instead of returning nil
strip_return() {
	awk '/^return /{next} {print}' "$1"
}

{
	cat src/core.lua

	printf '\n\t----------------------------------------------------------- modules\n\n'

	printf '\tlocal TargetsLib = (function()\n'
	strip_return lib/targets.lua
	printf '\t\treturn Targets\n'
	printf '\tend)()\n\n'

	printf '\tlocal SelfLib = (function()\n'
	strip_return lib/self.lua
	printf '\t\treturn Self\n'
	printf '\tend)()\n\n'

	cat src/ui.lua
	cat src/main.lua
} > "$TMP"

mv "$TMP" "$OUT"
echo "built $OUT: $(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes"
