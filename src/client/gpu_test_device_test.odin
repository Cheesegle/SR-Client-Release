package main

// The GPU device a rendering test draws with, on either backend: a hidden
// OpenGL 4.5 window (its default framebuffer is the target), or an offscreen
// Vulkan device with a colour+depth target. Both read back rows bottom-up, so
// a test's `(h-1-y)*w` math is the same everywhere.
//
//	gpu := test_gpu_open(W, H)
//	if !testing.expect(t, gpu.ok, "no GPU device for the test") do return
//	defer test_gpu_close(&gpu, t)
//
// glfw.Init comes first (tests own it). test_gpu_close frees the resource
// caches, so nothing outlives the device, and on Vulkan fails the test on
// any validation error raised while it was open.

import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"

when ODIN_TEST {
	Test_Gpu :: struct {
		ok:            bool,
		window:        glfw.WindowHandle, // hidden; on Vulkan without an API (tests use it for input)
		target:        Gpu_Render_Target, // 0 (the window) on GL
		width, height: i32,
		validation_errors: int, // at open, to report only this test's
	}

	// The device of the test running now (tests run on one thread).
	g_test_gpu: ^Test_Gpu

	test_gpu_open :: proc(width, height: i32, title: cstring = "SR Client test") -> (gpu: Test_Gpu) {
		g_gpu_backend = SR_VULKAN ? .Vulkan : .OpenGL
		when SR_VULKAN {
			glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
			glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
			gpu.window = glfw.CreateWindow(width, height, title, nil, nil)
			glfw.DefaultWindowHints()
			if gpu.window == nil { return }
			if !gpu_vk_init() { glfw.DestroyWindow(gpu.window); return }
			gpu.target = gpu_render_target_create(width, height)
			gpu_vk_set_default_target(gpu.target) // target 0 is the "window", as on GL
			gpu.validation_errors = g_vk_validation_errors
		} else {
			glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
			glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
			glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
			glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
			gpu.window = glfw.CreateWindow(width, height, title, nil, nil)
			if gpu.window == nil { return }
			glfw.MakeContextCurrent(gpu.window)
			gl.load_up_to(4, 5, glfw.gl_set_proc_address)
			gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		}
		gpu.width, gpu.height, gpu.ok = width, height, true
		gpu_set_target(gpu.target, width, height)
		return
	}

	test_gpu_close :: proc(gpu: ^Test_Gpu, t: ^testing.T = nil) {
		if !gpu.ok { return }
		if g_test_gpu == gpu { g_test_gpu = nil }
		resource_cache_fini()
		when SR_VULKAN {
			gpu_render_target_destroy(&gpu.target)
			gpu_frames_fini()
			if t != nil {
				testing.expectf(t, g_vk_validation_errors == gpu.validation_errors, "%d Vulkan validation errors", g_vk_validation_errors - gpu.validation_errors)
			}
			gpu_vk_fini()
		}
		glfw.DestroyWindow(gpu.window)
		gpu^ = {}
	}

	// Resizes the device's target, as resizing the window resizes GL's default
	// framebuffer. Draw state then covers the new size.
	test_gpu_resize :: proc(width, height: i32) {
		gpu := g_test_gpu
		if gpu == nil { return }
		glfw.SetWindowSize(gpu.window, width, height)
		when SR_VULKAN {
			gpu_render_target_destroy(&gpu.target)
			gpu.target = gpu_render_target_create(width, height)
			gpu_vk_set_default_target(gpu.target)
		}
		gpu.width, gpu.height = width, height
		test_gpu_use_target(0, width, height)
	}

	// GL: no error is pending (glGetError). Vulkan reports problems through
	// validation instead, which test_gpu_close checks.
	test_gpu_no_error :: proc() -> bool {
		when SR_VULKAN { return true } else { return gl.GetError() == gl.NO_ERROR }
	}

	// The target the test draws into now: its own (test_gpu_target) or the device's.
	test_gpu_current_target :: proc() -> Gpu_Render_Target {
		return g_test_gpu_target
	}

	@(private = "file")
	g_test_gpu_target: Gpu_Render_Target

	// Back to the device's own target (the GL window), at its size.
	test_gpu_use_device_target :: proc() {
		if g_test_gpu != nil { test_gpu_use_target(g_test_gpu.target, g_test_gpu.width, g_test_gpu.height) }
	}

	// Draws go to `target` (0: the device's) from now on, w x h.
	test_gpu_use_target :: proc(target: Gpu_Render_Target, width, height: i32) {
		g_test_gpu_target = target
		gpu_set_target(target, width, height)
	}

	// RGB8 pixels of the rectangle (x, y from the bottom-left, as glReadPixels)
	// of the current target, rows bottom-up. Queued interface draws land first.
	test_read_rgb :: proc(x, y, width, height: i32, pixels: rawptr) {
		test_read(x, y, width, height, pixels, 3)
	}

	test_read_rgba :: proc(x, y, width, height: i32, pixels: rawptr) {
		test_read(x, y, width, height, pixels, 4)
	}

	@(private = "file")
	test_read :: proc(x, y, width, height: i32, pixels: rawptr, channels: int) {
		ui_flush()
		when SR_VULKAN {
			// Vulkan reads whole targets: read it, then cut the rectangle out.
			tw, th := test_target_size()
			full := make([]u8, int(tw) * int(th) * 3, context.temp_allocator)
			gpu_read_color_rgb(g_test_gpu_target, tw, th, full)
			out := ([^]u8)(pixels)
			for row in 0 ..< int(height) {
				for col in 0 ..< int(width) {
					sx, sy := int(x) + col, int(y) + row
					o := (row * int(width) + col) * channels
					if sx < 0 || sy < 0 || sx >= int(tw) || sy >= int(th) { continue }
					i := (sy * int(tw) + sx) * 3
					out[o], out[o + 1], out[o + 2] = full[i], full[i + 1], full[i + 2]
					if channels == 4 { out[o + 3] = 255 }
				}
			}
		} else {
			gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
			gl.ReadPixels(x, y, width, height, channels == 4 ? gl.RGBA : gl.RGB, gl.UNSIGNED_BYTE, pixels)
			gl.PixelStorei(gl.PACK_ALIGNMENT, 4)
		}
	}

	// Size of the current target (Vulkan): the test's own, or the device's.
	@(private = "file")
	test_target_size :: proc() -> (width, height: i32) {
		when SR_VULKAN {
			if g_test_gpu_target == 0 || g_test_gpu != nil && g_test_gpu_target == g_test_gpu.target {
				if g_test_gpu != nil { return g_test_gpu.width, g_test_gpu.height }
			}
			if size, ok := g_test_target_sizes[g_test_gpu_target]; ok { return size.x, size.y }
		}
		return 0, 0
	}

	@(private = "file")
	g_test_target_sizes: map[Gpu_Render_Target][2]i32

	// An offscreen colour+depth target for tests that render at several sizes.
	test_gpu_target :: proc(width, height: i32) -> Gpu_Render_Target {
		target := gpu_render_target_create(width, height)
		if g_test_target_sizes == nil { g_test_target_sizes = make(map[Gpu_Render_Target][2]i32) }
		g_test_target_sizes[target] = {width, height}
		return target
	}

	test_gpu_target_destroy :: proc(target: ^Gpu_Render_Target) {
		delete_key(&g_test_target_sizes, target^)
		if len(g_test_target_sizes) == 0 { delete(g_test_target_sizes); g_test_target_sizes = nil }
		if g_test_gpu_target == target^ { g_test_gpu_target = g_test_gpu != nil ? g_test_gpu.target : 0 }
		gpu_render_target_destroy(target)
	}
}
