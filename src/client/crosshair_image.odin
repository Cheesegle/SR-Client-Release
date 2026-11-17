package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import gl "vendor:OpenGL"
import curl "vendor:curl"


// Image crosshair (Krunker's crosshairSho 4 + crosshairImage): a web link,
// e.g. Discord's "Copy Link", or a path to a PNG/JPG on this PC. Web images
// download once on a background thread and are kept in cache/ so later starts
// work offline. Until an image is ready the Precision crosshair is drawn.

CROSSHAIR_IMAGE_CACHE_DIR :: "cache"
CROSSHAIR_IMAGE_MAX_BYTES :: 8 * 1024 * 1024

Crosshair_Image_State :: enum { NONE, LOADING, READY, FAILED }

Crosshair_Image_Job :: struct {
	url:  string, // what is downloaded (Discord WebP links are asked for PNG)
	data: [dynamic]byte,
	ok:   bool,
	done: bool, // set last, atomically, by the download thread
	thread: ^thread.Thread,
}

Crosshair_Image :: struct {
	url:     string, // the setting this state belongs to
	state:   Crosshair_Image_State,
	texture: Gpu_Texture,
	job:     ^Crosshair_Image_Job,
}

g_crosshair_image: Crosshair_Image
g_hitmarker_image: Crosshair_Image // the same loader, for the hitmarker image

// Discord serves "format=webp" previews, which the image loader cannot read;
// the same link with "format=png" returns a PNG.
crosshair_image_fetch_url :: proc(url: string, allocator := context.allocator) -> string {
	lower := strings.to_lower(url, context.temp_allocator)
	if strings.contains(lower, "discord") && strings.contains(lower, "format=webp") {
		replaced, _ := strings.replace_all(url, "format=webp", "format=png", allocator)
		return replaced
	}
	return strings.clone(url, allocator)
}

crosshair_image_is_web :: proc(url: string) -> bool {
	lower := strings.to_lower(url, context.temp_allocator)
	return strings.has_prefix(lower, "http://") || strings.has_prefix(lower, "https://")
}

crosshair_image_cache_path :: proc(url: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/crosshair-%016x.img", CROSSHAIR_IMAGE_CACHE_DIR, hash.fnv64a(transmute([]byte)url), allocator = allocator)
}

// A local path the user pasted; "file:///C:/x.png" style links work too.
crosshair_image_local_path :: proc(url: string) -> string {
	path := strings.trim_space(url)
	if strings.has_prefix(strings.to_lower(path, context.temp_allocator), "file:///") { path = path[len("file:///"):] }
	return strings.trim(path, "\"")
}

// The texture to draw for this setting, or 0 while loading or after a failure.
crosshair_image_texture :: proc(url: string, image: ^Crosshair_Image = nil) -> Gpu_Texture {
	image := image != nil ? image : &g_crosshair_image
	crosshair_image_poll(image)
	if len(url) == 0 { return 0 }
	if url != image.url {
		if image.job != nil { return 0 } // Finish the running download first.
		delete(image.url)
		image.url, image.texture, image.state = strings.clone(url), 0, .NONE
	}
	if image.state == .NONE { crosshair_image_start(image) }
	return image.state == .READY ? image.texture : 0
}

@(private = "file")
crosshair_image_start :: proc(image: ^Crosshair_Image) {
	if !crosshair_image_is_web(image.url) {
		crosshair_image_finish(image, crosshair_image_local_path(image.url))
		return
	}
	cache := crosshair_image_cache_path(image.url)
	if os.exists(cache) {
		crosshair_image_finish(image, cache)
		return
	}
	job := new(Crosshair_Image_Job)
	job.url = crosshair_image_fetch_url(image.url)
	job.thread = thread.create_and_start_with_poly_data(job, crosshair_image_download)
	if job.thread == nil {
		delete(job.url)
		free(job)
		image.state = .FAILED
		return
	}
	image.job, image.state = job, .LOADING
}

@(private = "file")
crosshair_image_poll :: proc(image: ^Crosshair_Image) {
	job := image.job
	if job == nil || !sync.atomic_load(&job.done) { return }
	thread.join(job.thread)
	thread.destroy(job.thread)
	if job.ok && image.state == .LOADING {
		cache := crosshair_image_cache_path(image.url)
		_ = os.make_directory_all(CROSSHAIR_IMAGE_CACHE_DIR)
		if os.write_entire_file(cache, job.data[:]) == nil { crosshair_image_finish(image, cache) } else { image.state = .FAILED }
	} else if image.state == .LOADING {
		image.state = .FAILED
		fmt.eprintln("[Crosshair] Could not download the crosshair image.")
	}
	delete(job.data)
	delete(job.url)
	free(job)
	image.job = nil
}

@(private = "file")
crosshair_image_finish :: proc(image: ^Crosshair_Image, path: string) {
	texture := load_texture(path)
	if texture == 0 {
		image.state = .FAILED
		fmt.eprintln("[Crosshair] Not a PNG/JPG image or unreadable:", path)
		if strings.has_prefix(path, CROSSHAIR_IMAGE_CACHE_DIR) { _ = os.remove(path) }
		return
	}
	// Smooth scaling, like the HUD's ammo icon.
	gpu_texture_set_filter(texture, .Linear)
	image.texture, image.state = texture, .READY
}

@(private = "file")
crosshair_image_write :: proc "c" (buffer: [^]byte, size, count: c.size_t, output: rawptr) -> c.size_t {
	context = runtime.default_context()
	total := int(size * count)
	job := cast(^Crosshair_Image_Job)output
	if job == nil || total <= 0 { return 0 }
	if len(job.data)+total > CROSSHAIR_IMAGE_MAX_BYTES { return 0 } // Aborts the transfer.
	append(&job.data, ..buffer[:total])
	return c.size_t(total)
}

@(private = "file")
crosshair_image_download :: proc(job: ^Crosshair_Image_Job) {
	defer sync.atomic_store(&job.done, true)
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { return }
	defer curl.global_cleanup()
	handle := curl.easy_init()
	if handle == nil { return }
	defer curl.easy_cleanup(handle)
	url := strings.clone_to_cstring(job.url)
	defer delete(url)
	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(8000))
	curl.easy_setopt(handle, .TIMEOUT_MS, c.long(20000))
	curl.easy_setopt(handle, .USERAGENT, cstring("Mozilla/5.0 (SR Client)"))
	curl.easy_setopt(handle, .WRITEFUNCTION, curl.write_callback(crosshair_image_write))
	curl.easy_setopt(handle, .WRITEDATA, rawptr(job))
	code := curl.easy_perform(handle)
	status: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	job.ok = code == .E_OK && status >= 200 && status < 300 && len(job.data) > 0
}

