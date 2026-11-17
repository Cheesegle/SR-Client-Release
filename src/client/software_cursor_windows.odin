#+build windows

package main

import win "core:sys/windows"

foreign import user32 "system:User32.lib"
foreign import gdi32 "system:Gdi32.lib"

@(default_calling_convention = "system")
foreign user32 {
	DrawIconEx :: proc(hdc: win.HDC, x, y: win.INT, icon: win.HICON, width, height: win.INT, step: win.UINT, flicker_brush: win.HBRUSH, flags: win.UINT) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign gdi32 {
	GdiFlush :: proc() -> win.BOOL ---
}

DI_NORMAL :: 0x0003

// The user's arrow cursor (their scheme and pointer size) as straight-alpha
// RGBA rows, bottom row first, plus its hotspot in pixels from the top left.
system_arrow_cursor_rgba :: proc(allocator := context.allocator) -> (rgba: []u8, width, height, hot_x, hot_y: i32, ok: bool) {
	arrow := win.LoadCursorW(nil, win.LPCWSTR(win._IDC_ARROW))
	if arrow == nil { return }
	info := win.ICONINFOEXW{cbSize = size_of(win.ICONINFOEXW)}
	if !win.GetIconInfoExW(win.HICON(arrow), &info) { return }
	defer {
		if info.hbmMask != nil { win.DeleteObject(win.HGDIOBJ(info.hbmMask)) }
		if info.hbmColor != nil { win.DeleteObject(win.HGDIOBJ(info.hbmColor)) }
	}
	bitmap: win.BITMAP
	if info.hbmColor != nil {
		if win.GetObjectW(win.HANDLE(info.hbmColor), size_of(bitmap), &bitmap) == 0 { return }
		width, height = bitmap.bmWidth, bitmap.bmHeight
	} else {
		// Monochrome cursors stack the AND and XOR masks in one bitmap.
		if info.hbmMask == nil || win.GetObjectW(win.HANDLE(info.hbmMask), size_of(bitmap), &bitmap) == 0 { return }
		width, height = bitmap.bmWidth, bitmap.bmHeight / 2
	}
	if width <= 0 || height <= 0 || width > 512 || height > 512 { return }

	on_black := draw_cursor_over(win.HICON(arrow), width, height, 0x00, context.temp_allocator) or_return
	on_white := draw_cursor_over(win.HICON(arrow), width, height, 0xff, context.temp_allocator) or_return
	rgba = software_cursor_pixels_from_backgrounds(on_black, on_white, width, height, allocator)
	if rgba == nil { return }
	return rgba, width, height, i32(info.xHotspot), i32(info.yHotspot), true
}

// Draws the cursor into a top-down 32-bit DIB filled with one grey level and
// returns a copy of its BGRA pixels.
@(private = "file")
draw_cursor_over :: proc(icon: win.HICON, width, height: i32, background: u8, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	dc := win.CreateCompatibleDC(nil)
	if dc == nil { return }
	defer win.DeleteDC(dc)
	header := win.BITMAPINFO{bmiHeader = {
		biSize = size_of(win.BITMAPINFOHEADER), biWidth = width, biHeight = -height,
		biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB,
	}}
	bits: rawptr
	dib := win.CreateDIBSection(dc, &header, win.DIB_RGB_COLORS, &bits, nil, 0)
	if dib == nil || bits == nil { return }
	defer win.DeleteObject(win.HGDIOBJ(dib))
	previous := win.SelectObject(dc, win.HGDIOBJ(dib))
	defer win.SelectObject(dc, previous)
	size := int(width) * int(height) * 4
	source := (cast([^]u8)bits)[:size]
	for i in 0..<size { source[i] = background }
	GdiFlush()
	if !DrawIconEx(dc, 0, 0, icon, width, height, 0, nil, DI_NORMAL) { return }
	GdiFlush()
	pixels = make([]u8, size, allocator)
	copy(pixels, source)
	return pixels, true
}
