//go:build ignore

// gen_icons erzeugt die PWA-Icons in static/icons/ (wird nicht ins Binary
// gebaut, nur bei Bedarf: go generate ./internal/web).
//
// Motiv: eine in zwei Hälften geteilte Münze – weiß auf Spliit-Grün.
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

// shape liefert die Farbe am Punkt (x, y) ∈ [0,1)², oder ok=false für transparent.
type shape func(x, y float64) (c color.NRGBA, ok bool)

// icon zeichnet das Motiv. rounded: abgerundetes Quadrat (sonst
// randlos), scale: Radius der Münze relativ zur Kantenlänge.
func icon(rounded bool, scale float64) shape {
	return func(x, y float64) (color.NRGBA, bool) {
		if rounded && !inRoundedSquare(x, y, 0.22) {
			return color.NRGBA{}, false
		}
		// Zwei Hälften einer Münze, auseinandergeschoben: links etwas
		// höher, rechts etwas tiefer, dazwischen ein Spalt.
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

// render rastert shape mit 4×4-Supersampling.
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
	// Maskable: randlos, Motiv innerhalb der Sicherheitszone (Radius 40 %).
	write("maskable-512.png", render(512, icon(false, 0.26)))
	// iOS maskiert selbst und mag keine Transparenz.
	write("apple-touch-icon.png", render(180, icon(false, 0.30)))
}
