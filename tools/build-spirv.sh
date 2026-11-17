#!/bin/sh
# Compiles the world and interface shaders to SPIR-V for the Vulkan backend (see
# tools/build-spirv.ps1, which does the same on Windows). Needs glslc.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/assets/shaders"
out="$root/src/client/spirv"
command -v glslc >/dev/null || { echo "glslc not found: install the Vulkan SDK" >&2; exit 1; }
defines=$(sed -n 's/^#define[[:space:]]\+\([A-Za-z0-9_]\+\)[[:space:]]\+\([^[:space:]]\+\).*/-D\1=\2/p' "$out/basic_defines.glsl")
build() {
	name=$1; shift
	for stage in vert frag; do
		# shellcheck disable=SC2086
		glslc --target-env=vulkan1.3 -O $defines "$@" -o "$out/$name.$stage.spv" "$src/basic.$stage"
	done
}
build basic
build basic_batched -DBATCHED
build basic_shadow -DSHADOW_DEPTH_PASS
build basic_shadow_batched -DBATCHED -DSHADOW_DEPTH_PASS
# Other programs are one source pair each.
for name in ui debug_line; do
	for stage in vert frag; do
		glslc --target-env=vulkan1.3 -O -o "$out/$name.$stage.spv" "$src/$name.$stage"
	done
done
echo "SPIR-V written to $out"
