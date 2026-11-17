# GPU Compatibility

SR Client renders with Vulkan 1.3 by default and falls back to OpenGL 4.5 when Vulkan is missing
(or when "Vulkan Renderer" is turned off in Settings, or with `--opengl`). Support depends on the operating system and
installed driver, so the families below are practical examples rather than an exhaustive certified
hardware list.

## Vulkan 1.3

With a current driver, these families generally run the Vulkan renderer:

- **NVIDIA:** GeForce GTX 900 series (Maxwell) and newer, including GTX 10, RTX 20, RTX 30, RTX 40
  and RTX 50 series.
- **AMD:** Radeon RX 400/500 (Polaris) and newer, including RX 5000, RX 6000 and RX 7000 series, and
  Ryzen APUs with Vega or newer graphics.
- **Intel:** 6th-generation Core (Skylake, Gen9) integrated graphics and newer, Iris Xe and Arc.

On a laptop with two GPUs, the Vulkan renderer picks the discrete one; `SR_GPU=<index or part
of the name>` overrides that (the client logs the GPUs it found). The choice is in the startup log
and in crash reports.

## OpenGL 4.5 (fallback)

With a current vendor or Mesa driver, these families generally expose OpenGL 4.5 or newer:

- **NVIDIA:** GeForce GTX 600 series and newer, including GTX 900, GTX 10, RTX 20, RTX 30, RTX 40, and RTX 50 series.
- **AMD:** Radeon HD 7000 series and newer GCN-based cards, plus Radeon RX 400/500, RX 5000, RX 6000, and RX 7000 series.
- **Intel:** Broadwell (5th-generation Core) and newer integrated graphics, including Iris, Iris Xe, and Arc.
- **AMD integrated graphics:** Ryzen APUs with Vega or newer Radeon graphics.

## Driver guidance

- On Windows, install the latest graphics driver from NVIDIA, AMD, or Intel rather than relying on
  a generic Windows display driver.
- On Linux, use a current Mesa stack and the vendor-appropriate OpenGL driver package.
- On other platforms, verify that the active driver exposes an OpenGL 4.5 **core** profile. The
  GPU's advertised DirectX or Vulkan version is not enough by itself.

## Not supported by default

- Apple stopped its native OpenGL implementation at 4.1, so macOS does not currently meet the
  client's OpenGL 4.5 requirement. Native macOS support is a future investigation.
- Very old integrated graphics and legacy drivers may expose only OpenGL 3.x or 4.1/4.3.

## Checking a system

On Linux, run `glxinfo -B` and check the `OpenGL version` and `OpenGL core profile version` lines.
On Windows, use a tool such as GPU-Z or OpenGL Extensions Viewer and confirm that the active
driver reports OpenGL 4.5 core support.
