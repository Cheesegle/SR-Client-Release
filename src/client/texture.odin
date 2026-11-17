package main

import "core:fmt"
import "core:math"
import "core:strings"
import stbi "vendor:stb/image"
import shared "../shared"

Texture :: struct {
	id:     Gpu_Texture,
	width:  i32,
	height: i32,
}

Texture_Manager :: struct {
	textures: map[u32]Gpu_Texture, // prefab texture index -> texture
	fallback: Gpu_Texture,
}

g_impact_texture: Gpu_Texture

texture_manager_init :: proc() -> Texture_Manager {
	tm: Texture_Manager
	tm.textures = make(map[u32]Gpu_Texture)

	// These indices are the same prefab texture indices used by the original
	// SR Client client. Keep the list in index order; map JSON stores only the
	// numeric index in its "t" field.
	texture_names := [?]string{
		"wall", "dirt", "floor", "grid", "grey", "default", "roof", "flag",
		"grass_1", "check", "lines", "brick", "link", "liquid", "grain", "fabric", "tile",
		"metal", "sand", "snow",
	}

	for name, idx in texture_names {
		// Slot 5 is the live DEFAULT material and deliberately has no image.
		if name == "default" {
			continue
		}
		suffix := "_0"
		if idx == 8 {
			// The browser registry points grass at grass_1.png.
			suffix = ""
		}
		path := strings.concatenate({"assets/textures/", name, suffix, ".png"})
		tex, ok := texture_load_from_file(path)
		if !ok {
			fmt.eprintf("Failed to load texture %d: %s\n", idx, path)
			continue
		}
		tm.textures[u32(idx)] = tex.id
		fmt.printf("Loaded texture %d: %s (%dx%d)\n", idx, path, tex.width, tex.height)
	}

	if wall, ok := tm.textures[0]; ok {
		tm.fallback = wall
	}
	return tm
}

texture_manager_get :: proc(tm: ^Texture_Manager, idx: u32) -> Gpu_Texture {
	if handle, ok := tm.textures[idx]; ok {
		return handle
	}
	return tm.fallback
}

upload_rgba_texture :: proc(pixels: []u8, width, height: i32) -> Gpu_Texture {
	return gpu_texture_create({width = width, height = height, format = .RGBA8, mipmaps = true, sampler = GPU_SAMPLER_WORLD}, pixels)
}

impact_texture_get :: proc() -> Gpu_Texture {
	if g_impact_texture != 0 {
		return g_impact_texture
	}

	size :: 64
	pixels := make([]u8, size * size * 4)
	defer delete(pixels)

	for y := 0; y < size; y += 1 {
		for x := 0; x < size; x += 1 {
			dx := (f32(x) + 0.5) / (f32(size) * 0.5) - 1.0
			dy := (f32(y) + 0.5) / (f32(size) * 0.5) - 1.0
			radius := math.sqrt(dx * dx + dy * dy)
			angle := math.atan2(dy, dx)
			edge := 0.88 + 0.05 * math.sin(angle * 7.0) + 0.025 * math.sin(angle * 13.0 + 0.7)

			shade: u8
			alpha: u8
			if radius < edge {
				fade := clamp((edge - radius) / 0.08, 0.0, 1.0)
				if radius > edge - 0.18 {
					shade = 82
				} else {
					shade = 18
				}
				alpha = u8(235.0 * fade)
			}

			idx := (y * size + x) * 4
			pixels[idx + 0] = shade
			pixels[idx + 1] = u8(f32(shade) * 0.9)
			pixels[idx + 2] = u8(f32(shade) * 0.78)
			pixels[idx + 3] = alpha
		}
	}

	g_impact_texture = upload_rgba_texture(pixels, size, size)
	return g_impact_texture
}

texture_load_from_file :: proc(filename: string) -> (tex: Texture, ok: bool) {
	c_path := strings.clone_to_cstring(shared.mod_resolve(filename))
	defer delete(c_path)

	stbi.set_flip_vertically_on_load(1)

	w, h, channels: i32
	data := stbi.load(c_path, &w, &h, &channels, 4)
	shared.asset_trace(filename, data != nil)
	if data == nil {
		return tex, false
	}
	defer stbi.image_free(data)

	tex.width = w
	tex.height = h
	tex.id = upload_rgba_texture(data[:int(w) * int(h) * 4], w, h)
	return tex, tex.id != 0
}
