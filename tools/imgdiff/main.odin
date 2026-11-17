package imgdiff

// Compares images pixel by pixel (GL vs Vulkan parity checks).
//
//   imgdiff a.png b.png [--crop left,top,right,bottom] [--diff out.png]
//   imgdiff dir_a dir_b [--crop ...]     every PNG present in both folders
//
// For each pair it prints the largest channel difference, the mean, and the
// share of pixels whose largest channel difference is over 2 and over 16.
// --crop drops borders (pixels) first, for window screenshots. --diff writes
// the per-pixel difference, amplified 8x. Exit code 1 when any pair is over
// --max-over16 percent (default 0.5) or sizes differ.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"

Options :: struct {
	crop:       [4]int,
	diff_path:  string,
	max_over16: f64,
}

Result :: struct {
	max_diff:      int,
	mean:          f64,
	over2, over16: f64, // percent of pixels
	ok:            bool,
}

compare :: proc(path_a, path_b: string, options: Options) -> (r: Result) {
	wa, ha, wb, hb, ca, cb: i32
	a := stbi.load(strings.clone_to_cstring(path_a, context.temp_allocator), &wa, &ha, &ca, 3)
	b := stbi.load(strings.clone_to_cstring(path_b, context.temp_allocator), &wb, &hb, &cb, 3)
	defer { if a != nil { stbi.image_free(a) }; if b != nil { stbi.image_free(b) } }
	if a == nil || b == nil {
		fmt.eprintfln("cannot read %s", a == nil ? path_a : path_b)
		return
	}
	if wa != wb || ha != hb {
		fmt.eprintfln("%s: sizes differ (%dx%d vs %dx%d)", filepath.base(path_a), wa, ha, wb, hb)
		return
	}
	x0, y0 := options.crop[0], options.crop[1]
	x1, y1 := int(wa) - options.crop[2], int(ha) - options.crop[3]
	if x1 <= x0 || y1 <= y0 { fmt.eprintln("the crop leaves nothing"); return }
	diff: []u8
	if options.diff_path != "" { diff = make([]u8, (x1 - x0) * (y1 - y0) * 3, context.temp_allocator) }
	total: f64
	over2, over16: int
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			i := (y * int(wa) + x) * 3
			largest := 0
			for c in 0 ..< 3 {
				d := abs(int(a[i + c]) - int(b[i + c]))
				largest = max(largest, d)
				total += f64(d)
				if diff != nil { diff[((y - y0) * (x1 - x0) + (x - x0)) * 3 + c] = u8(min(d * 8, 255)) }
			}
			r.max_diff = max(r.max_diff, largest)
			if largest > 2 { over2 += 1 }
			if largest > 16 { over16 += 1 }
		}
	}
	n := f64((x1 - x0) * (y1 - y0))
	r.mean = total / (n * 3)
	r.over2, r.over16 = 100 * f64(over2) / n, 100 * f64(over16) / n
	r.ok = r.over16 <= options.max_over16
	if diff != nil {
		path := strings.clone_to_cstring(options.diff_path, context.temp_allocator)
		stbi.write_png(path, i32(x1 - x0), i32(y1 - y0), 3, raw_data(diff), i32(x1 - x0) * 3)
	}
	return
}

report :: proc(name: string, r: Result) {
	fmt.printfln("%-40s max %3d  mean %.3f  >2 %.3f%%  >16 %.3f%%%s", name, r.max_diff, r.mean, r.over2, r.over16, r.ok ? "" : "  FAIL")
}

main :: proc() {
	args := os.args[1:]
	options := Options{max_over16 = 0.5}
	paths := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--crop":
			if i + 1 >= len(args) { fmt.eprintln("--crop needs left,top,right,bottom"); os.exit(2) }
			i += 1
			parts := strings.split(args[i], ",", context.temp_allocator)
			if len(parts) != 4 { fmt.eprintln("--crop needs left,top,right,bottom"); os.exit(2) }
			for p, k in parts { options.crop[k], _ = strconv.parse_int(p) }
		case "--diff":
			if i + 1 >= len(args) { fmt.eprintln("--diff needs a path"); os.exit(2) }
			i += 1
			options.diff_path = args[i]
		case "--max-over16":
			if i + 1 >= len(args) { fmt.eprintln("--max-over16 needs a percentage"); os.exit(2) }
			i += 1
			options.max_over16, _ = strconv.parse_f64(args[i])
		case:
			append(&paths, args[i])
		}
	}
	if len(paths) != 2 {
		fmt.eprintln("usage: imgdiff a.png b.png | dir_a dir_b [--crop l,t,r,b] [--diff out.png] [--max-over16 pct]")
		os.exit(2)
	}
	failed := false
	if os.is_dir(paths[0]) {
		pattern, _ := filepath.join({paths[0], "*.png"}, context.temp_allocator)
		matches, _ := filepath.glob(pattern, context.temp_allocator)
		compared := 0
		for match in matches {
			name := filepath.base(match)
			other, _ := filepath.join({paths[1], name}, context.temp_allocator)
			if !os.exists(other) { continue }
			r := compare(match, other, {crop = options.crop, max_over16 = options.max_over16})
			report(name, r)
			failed ||= !r.ok
			compared += 1
		}
		if compared == 0 { fmt.eprintln("no PNG is in both folders"); os.exit(1) }
	} else {
		r := compare(paths[0], paths[1], options)
		report(filepath.base(paths[0]), r)
		failed = !r.ok
	}
	os.exit(failed ? 1 : 0)
}
