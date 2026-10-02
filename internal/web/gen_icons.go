//go:build ignore

// gen_icons generates the PWA icons in static/icons/ (not built into the
// binary, only run on demand: go generate ./internal/web).
//
// Motif: a coin split into two halves, white on Spliit green.
package main

import (
	"image"
	"image/color"
	"image/png"
	"log"
	"math"
	"os"
	"path/filepath"
)

var (
	green = color.NRGBA{0x04, 0x77, 0x56, 0xff}
	white = color.NRGBA{0xff, 0xff, 0xff, 0xff}
)

// shape returns the color at point (x, y) ∈ [0,1)², or ok=false for transparent.
type shape func(x, y float64) (c color.NRGBA, ok bool)

// icon draws the motif. rounded: rounded square (otherwise full bleed),
// scale: radius of the coin relative to the edge length.
func icon(rounded bool, scale float64) shape {
	return func(x, y float64) (color.NRGBA, bool) {
		if rounded && !inRoundedSquare(x, y, 0.22) {
			return color.NRGBA{}, false
		}
		// Two halves of a coin, pushed apart: the left one slightly
		// higher, the right one slightly lower, with a gap in between.
		gap := scale * 0.14
		shift := scale * 0.12
		dx := x - 0.5
		cy := 0.5 + shift
		if dx < 0 {
			cy = 0.5 - shift
		}
		if math.Abs(dx) > gap/2 && math.Hypot(dx, y-cy) < scale {
			return white, true
		}
		return green, true
	}
}

func inRoundedSquare(x, y, radius float64) bool {
	cx := math.Max(math.Max(radius-x, x-(1-radius)), 0)
	cy := math.Max(math.Max(radius-y, y-(1-radius)), 0)
	return cx*cx+cy*cy <= radius*radius
}

// render rasterizes shape with 4×4 supersampling.
func render(size int, s shape) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	const n = 4
	for py := 0; py < size; py++ {
		for px := 0; px < size; px++ {
			var r, g, b, a float64
			for sy := 0; sy < n; sy++ {
				for sx := 0; sx < n; sx++ {
					x := (float64(px) + (float64(sx)+0.5)/n) / float64(size)
					y := (float64(py) + (float64(sy)+0.5)/n) / float64(size)
					if c, ok := s(x, y); ok {
						r += float64(c.R)
						g += float64(c.G)
						b += float64(c.B)
						a++
					}
				}
			}
			if a == 0 {
				continue
			}
			img.SetNRGBA(px, py, color.NRGBA{
				uint8(r/a + 0.5), uint8(g/a + 0.5), uint8(b/a + 0.5), uint8(a/(n*n)*255 + 0.5),
			})
		}
	}
	return img
}

func write(name string, img image.Image) {
	f, err := os.Create(filepath.Join("static", "icons", name))
	if err != nil {
		log.Fatal(err)
	}
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(f, img); err != nil {
		log.Fatal(err)
	}
	if err := f.Close(); err != nil {
		log.Fatal(err)
	}
}

func main() {
	if err := os.MkdirAll(filepath.Join("static", "icons"), 0o755); err != nil {
		log.Fatal(err)
	}
	write("icon-192.png", render(192, icon(true, 0.30)))
	write("icon-512.png", render(512, icon(true, 0.30)))
	write("favicon-32.png", render(32, icon(true, 0.34)))
	// Maskable: full bleed, motif within the safe zone (radius 40 %).
	write("maskable-512.png", render(512, icon(false, 0.26)))
	// iOS applies its own mask and does not like transparency.
	write("apple-touch-icon.png", render(180, icon(false, 0.30)))
}
