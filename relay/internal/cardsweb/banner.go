package cardsweb

import (
	"bytes"
	_ "embed"
	"image"
	"image/color"
	"image/jpeg"
	_ "image/png"
	"math"
	"sync"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// A link preview's picture: 1200×630, the size WhatsApp, Telegram, iMessage,
// Facebook and X all show large. A brand's card art sits in the middle on its
// own colours, the way the app's brand page shows it, with «دفتر كروت»'s mark
// in the corner. No words are drawn: the title beside the picture says them,
// in Arabic every app already shapes.

const (
	bannerWidth  = 1200
	bannerHeight = 630
	// The card keeps the art's 8:5 and the app's corner (20 on a 340 card).
	cardWidth   = 704
	cardHeight  = 440
	cardRadius  = 41
	shadowBlur  = 14
	shadowDrop  = 18
	markSize    = 72
	markMargin  = 40
	siteMark    = 300
	jpegQuality = 88
)

//go:embed assets/mark.png
var markPNG []byte

// marks are the app's mark at the two sizes a banner uses, scaled once.
var marks = sync.OnceValue(func() map[int]image.Image {
	source, _, err := image.Decode(bytes.NewReader(markPNG))
	if err != nil {
		panic("cardsweb: the embedded mark does not decode: " + err.Error())
	}
	out := map[int]image.Image{}
	for _, size := range []int{markSize, siteMark} {
		scaled := image.NewRGBA(image.Rect(0, 0, size, size))
		draw.CatmullRom.Scale(scaled, scaled.Bounds(), source, source.Bounds(), draw.Src, nil)
		out[size] = scaled
	}
	return out
})

// palette is a gradient white stays readable on, as the app's ArtPalette.
type palette struct{ light, dark color.RGBA }

// sitePalette is the app's own teal.
var sitePalette = palette{light: rgb(0x0F766E), dark: rgb(0x064E3B)}

// drawnPalette is the app's DrawnCard.palette, for a brand with no art.
func drawnPalette(category string) palette {
	switch category {
	case "telecom", "intl_topup":
		return sitePalette
	case "internet":
		return palette{rgb(0x1D4ED8), rgb(0x1E3A8A)}
	case "gaming":
		return palette{rgb(0x7E22CE), rgb(0x3B0764)}
	case "tv":
		return palette{rgb(0xB42318), rgb(0x55160C)}
	}
	return palette{rgb(0xC98A3B), rgb(0x7A4B12)}
}

// renderSiteBanner is the shelf's own picture: the mark on the app's teal.
func renderSiteBanner() ([]byte, error) {
	canvas := background(sitePalette)
	mark := marks()[siteMark]
	at := image.Pt((bannerWidth-siteMark)/2, (bannerHeight-siteMark)/2)
	draw.Draw(canvas, mark.Bounds().Add(at), mark, image.Point{}, draw.Over)
	return encode(canvas)
}

// renderBrandBanner is a brand's picture from its art; nil art draws its
// category's colours with the mark where the card would be.
func renderBrandBanner(art image.Image, category string) ([]byte, error) {
	if art == nil {
		canvas := background(drawnPalette(category))
		mark := marks()[siteMark]
		at := image.Pt((bannerWidth-siteMark)/2, (bannerHeight-siteMark)/2)
		draw.Draw(canvas, mark.Bounds().Add(at), mark, image.Point{}, draw.Over)
		return encode(canvas)
	}
	colours, ok := artPalette(art)
	if !ok {
		colours = drawnPalette(category)
	}
	canvas := background(colours)
	card := image.Rect(0, 0, cardWidth, cardHeight).Add(image.Pt(
		(bannerWidth-cardWidth)/2, (bannerHeight-cardHeight)/2))
	shadow(canvas, card)
	scaled := image.NewRGBA(image.Rect(0, 0, cardWidth, cardHeight))
	draw.CatmullRom.Scale(scaled, scaled.Bounds(), art, art.Bounds(), draw.Src, nil)
	draw.DrawMask(canvas, card, scaled, image.Point{}, cardMask(), image.Point{}, draw.Over)
	// The mark at the top right: where an Arabic page starts.
	mark := marks()[markSize]
	at := image.Pt(bannerWidth-markMargin-markSize, markMargin)
	draw.Draw(canvas, mark.Bounds().Add(at), mark, image.Point{}, draw.Over)
	return encode(canvas)
}

// background is the palette's gradient from the top right (the start of an
// Arabic page) to the bottom left, lit softly behind the card.
func background(colours palette) *image.RGBA {
	canvas := image.NewRGBA(image.Rect(0, 0, bannerWidth, bannerHeight))
	const w, h = float64(bannerWidth), float64(bannerHeight)
	span := w*w + h*h
	glow := 0.62 * w
	light, dark := colours.light, colours.dark
	for y := 0; y < bannerHeight; y++ {
		row := canvas.Pix[y*canvas.Stride:]
		fy := float64(y) + 0.5
		for x := 0; x < bannerWidth; x++ {
			fx := float64(x) + 0.5
			t := ((w-fx)*w + fy*h) / span
			r := lerp(light.R, dark.R, t)
			g := lerp(light.G, dark.G, t)
			b := lerp(light.B, dark.B, t)
			dx, dy := fx-w/2, fy-h/2
			if d := math.Sqrt(dx*dx+dy*dy) / glow; d < 1 {
				lift := 0.14 * (1 - d) * (1 - d)
				r += (255 - r) * lift
				g += (255 - g) * lift
				b += (255 - b) * lift
			}
			i := x * 4
			row[i], row[i+1], row[i+2], row[i+3] = uint8(r+0.5), uint8(g+0.5), uint8(b+0.5), 255
		}
	}
	return canvas
}

// The card's shape and its shadow are the same for every brand: made once.
var (
	cardMask   = sync.OnceValue(func() *image.Alpha { return roundedMask(cardWidth, cardHeight, cardRadius, 0) })
	shadowPad  = shadowBlur * 3
	shadowMask = sync.OnceValue(func() *image.Alpha {
		mask := roundedMask(cardWidth+2*shadowPad, cardHeight+2*shadowPad, cardRadius, shadowPad)
		blur(mask, shadowBlur)
		for i := range mask.Pix {
			mask.Pix[i] = uint8(float64(mask.Pix[i]) * 0.42)
		}
		return mask
	})
)

// shadow lays the card's soft shadow on canvas, under where card will go.
func shadow(canvas *image.RGBA, card image.Rectangle) {
	mask := shadowMask()
	area := mask.Bounds().Add(card.Min.Sub(image.Pt(shadowPad, shadowPad-shadowDrop)))
	draw.DrawMask(canvas, area, image.NewUniform(color.RGBA{0, 0, 0, 255}), image.Point{}, mask, image.Point{}, draw.Over)
}

// roundedMask is a w×h mask holding a rounded rectangle inset by inset on
// every side, its corners anti-aliased.
func roundedMask(w, h, radius, inset int) *image.Alpha {
	mask := image.NewAlpha(image.Rect(0, 0, w, h))
	left, top := float64(inset), float64(inset)
	right, bottom := float64(w-inset), float64(h-inset)
	r := float64(radius)
	for y := inset; y < h-inset; y++ {
		fy := float64(y) + 0.5
		for x := inset; x < w-inset; x++ {
			fx := float64(x) + 0.5
			cx := math.Max(left+r, math.Min(fx, right-r))
			cy := math.Max(top+r, math.Min(fy, bottom-r))
			dist := math.Hypot(fx-cx, fy-cy)
			coverage := math.Max(0, math.Min(1, r-dist+0.5))
			mask.Pix[y*mask.Stride+x] = uint8(coverage*255 + 0.5)
		}
	}
	return mask
}

// blur softens mask three box passes each way: close to a Gaussian, in time
// that does not grow with the radius.
func blur(mask *image.Alpha, radius int) {
	w, h := mask.Rect.Dx(), mask.Rect.Dy()
	line := make([]int, max(w, h))
	for range 3 {
		for y := 0; y < h; y++ {
			boxPass(mask.Pix[y*mask.Stride:], 1, w, radius, line)
		}
		for x := 0; x < w; x++ {
			boxPass(mask.Pix[x:], mask.Stride, h, radius, line)
		}
	}
}

// boxPass averages n values step apart in pix over a 2·radius+1 window.
func boxPass(pix []uint8, step, n, radius int, line []int) {
	for i := 0; i < n; i++ {
		line[i] = int(pix[i*step])
	}
	window := 2*radius + 1
	sum := 0
	at := func(i int) int {
		if i < 0 || i >= n {
			return 0
		}
		return line[i]
	}
	for i := -radius; i <= radius; i++ {
		sum += at(i)
	}
	for i := 0; i < n; i++ {
		pix[i*step] = uint8(sum / window)
		sum += at(i+radius+1) - at(i-radius)
	}
}

// artPalette is the app's ArtPalette.from(dominantColor(art)): the art's
// most telling colour, kept dark enough under white.
func artPalette(art image.Image) (palette, bool) {
	dominant, ok := dominantColor(art)
	if !ok {
		return palette{}, false
	}
	hue, saturation, lightness := toHSL(dominant)
	lightness = math.Max(0.22, math.Min(0.42, lightness))
	saturation = math.Min(0.85, saturation)
	return palette{
		light: fromHSL(hue, saturation, lightness),
		dark:  fromHSL(hue, saturation, lightness*0.55),
	}, true
}

// dominantColor is the app's ArtPalette.dominantColor: pixels grouped by
// hue, near-white and near-black counting for nothing, the fullest and most
// colourful group winning; art with no colour gives its average.
func dominantColor(art image.Image) ([3]float64, bool) {
	const hues = 24
	var weight [hues]float64
	var sums [hues][3]float64
	var total [3]float64
	n := 0
	bounds := art.Bounds()
	for y := bounds.Min.Y; y < bounds.Max.Y; y += 4 {
		for x := bounds.Min.X; x < bounds.Max.X; x += 4 {
			c := pixel(art, x, y)
			if c.A < 128 {
				continue
			}
			rgb := [3]float64{float64(c.R) / 255, float64(c.G) / 255, float64(c.B) / 255}
			for i := range rgb {
				total[i] += rgb[i]
			}
			n++
			hue, saturation, value := toHSV(rgb)
			if saturation < 0.2 || value < 0.18 {
				continue
			}
			bucket := int(hue/360*hues) % hues
			w := saturation * value
			weight[bucket] += w
			for i := range rgb {
				sums[bucket][i] += rgb[i] * w
			}
		}
	}
	if n == 0 {
		return [3]float64{}, false
	}
	best := 0
	for i := 1; i < hues; i++ {
		if weight[i] > weight[best] {
			best = i
		}
	}
	if weight[best] < float64(n)*0.04 {
		return [3]float64{total[0] / float64(n), total[1] / float64(n), total[2] / float64(n)}, true
	}
	w := weight[best]
	return [3]float64{sums[best][0] / w, sums[best][1] / w, sums[best][2] / w}, true
}

// pixel is art's colour at x, y, read straight from the decoded pixels where
// it can be (a PNG's usual shapes), without a conversion's allocation.
func pixel(art image.Image, x, y int) color.NRGBA {
	switch img := art.(type) {
	case *image.NRGBA:
		return img.NRGBAAt(x, y)
	case *image.RGBA:
		c := img.RGBAAt(x, y)
		if c.A == 255 || c.A == 0 {
			return color.NRGBA{c.R, c.G, c.B, c.A}
		}
	}
	return color.NRGBAModel.Convert(art.At(x, y)).(color.NRGBA)
}

func toHSV(c [3]float64) (hue, saturation, value float64) {
	high := math.Max(c[0], math.Max(c[1], c[2]))
	low := math.Min(c[0], math.Min(c[1], c[2]))
	hue = hueOf(c, high, high-low)
	if high > 0 {
		saturation = (high - low) / high
	}
	return hue, saturation, high
}

func toHSL(c [3]float64) (hue, saturation, lightness float64) {
	high := math.Max(c[0], math.Max(c[1], c[2]))
	low := math.Min(c[0], math.Min(c[1], c[2]))
	chroma := high - low
	lightness = (high + low) / 2
	if lightness > 0 && lightness < 1 {
		saturation = chroma / (1 - math.Abs(2*lightness-1))
	}
	return hueOf(c, high, chroma), saturation, lightness
}

func hueOf(c [3]float64, high, chroma float64) float64 {
	if chroma == 0 {
		return 0
	}
	var hue float64
	switch high {
	case c[0]:
		hue = math.Mod((c[1]-c[2])/chroma, 6)
	case c[1]:
		hue = (c[2]-c[0])/chroma + 2
	default:
		hue = (c[0]-c[1])/chroma + 4
	}
	hue *= 60
	if hue < 0 {
		hue += 360
	}
	return hue
}

func fromHSL(hue, saturation, lightness float64) color.RGBA {
	chroma := (1 - math.Abs(2*lightness-1)) * saturation
	second := chroma * (1 - math.Abs(math.Mod(hue/60, 2)-1))
	var r, g, b float64
	switch {
	case hue < 60:
		r, g = chroma, second
	case hue < 120:
		r, g = second, chroma
	case hue < 180:
		g, b = chroma, second
	case hue < 240:
		g, b = second, chroma
	case hue < 300:
		r, b = second, chroma
	default:
		r, b = chroma, second
	}
	m := lightness - chroma/2
	return color.RGBA{uint8((r+m)*255 + 0.5), uint8((g+m)*255 + 0.5), uint8((b+m)*255 + 0.5), 255}
}

func encode(canvas image.Image) ([]byte, error) {
	var out bytes.Buffer
	if err := jpeg.Encode(&out, canvas, &jpeg.Options{Quality: jpegQuality}); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func lerp(a, b uint8, t float64) float64 { return float64(a) + (float64(b)-float64(a))*t }

func rgb(hex uint32) color.RGBA {
	return color.RGBA{uint8(hex >> 16), uint8(hex >> 8), uint8(hex), 255}
}
