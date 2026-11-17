# Compiles the shaders to SPIR-V for the Vulkan backend: the world shaders
# (assets/shaders/basic.vert, basic.frag) once per variant, and the other
# programs (ui, debug_line) once each. The modules are written next to the backend in
# src/client/spirv/ (gpu_vk.odin embeds them with #load).
#
# The Batch_Object layout defines come from src/client/spirv/basic_defines.glsl,
# which basic_spirv_defines_match_layout (src/client) checks against the Odin
# struct. Requires glslc (Vulkan SDK) on PATH.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'assets/shaders'
$out = Join-Path $root 'src/client/spirv'

$glslc = Get-Command glslc -ErrorAction SilentlyContinue
if (-not $glslc) {
    Write-Error 'glslc not found. Install the Vulkan SDK (https://vulkan.lunarg.com) and put its Bin folder on PATH.'
    exit 1
}

$defines = @()
foreach ($line in Get-Content (Join-Path $out 'basic_defines.glsl')) {
    if ($line -match '^#define\s+(\w+)\s+(\S+)\s*$') { $defines += "-D$($Matches[1])=$($Matches[2])" }
}

$variants = [ordered]@{
    'basic'                = @()
    'basic_batched'        = @('-DBATCHED')
    'basic_shadow'         = @('-DSHADOW_DEPTH_PASS')
    'basic_shadow_batched' = @('-DBATCHED', '-DSHADOW_DEPTH_PASS')
}

foreach ($name in $variants.Keys) {
    foreach ($stage in @('vert', 'frag')) {
        $target = Join-Path $out "$name.$stage.spv"
        & $glslc.Source --target-env=vulkan1.3 -O @defines @($variants[$name]) -o $target (Join-Path $source "basic.$stage")
        if ($LASTEXITCODE -ne 0) { Write-Error "glslc failed for $name.$stage"; exit 1 }
    }
}
foreach ($name in @('ui', 'debug_line')) {
    foreach ($stage in @('vert', 'frag')) {
        $target = Join-Path $out "$name.$stage.spv"
        & $glslc.Source --target-env=vulkan1.3 -O -o $target (Join-Path $source "$name.$stage")
        if ($LASTEXITCODE -ne 0) { Write-Error "glslc failed for $name.$stage"; exit 1 }
    }
}
Write-Host "SPIR-V written to $out"
