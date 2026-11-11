package cardsweb

import (
	"bytes"
	"embed"
	"image"
	"regexp"
	"strings"
	"sync"

	"golang.org/x/image/draw"
)

// An eSIM link's picture: the eSIM card as the app paints it, with the
// destination's flag where the app puts it, on the eSIM shelf's deep teal. A
// region or the world keeps the card's globe.
//
// The card and the flags are drawn by the app itself, so a preview looks like
// what the link opens (cards/tool/esim_link_art_test.dart writes them).

//go:embed assets/esim/card.png
var esimCardPNG []byte

//go:embed assets/esim/flags/*.png
var esimFlags embed.FS

// esimPalette is the app's eSIM gradient.
var esimPalette = palette{light: rgb(0x0F766E), dark: rgb(0x06302F)}

// The flag's disc on the card, as the app's EsimCardArt lays it out for an
// Arabic page: centred on the card's height, breaking out of its left edge,
// inside the card's own white ring.
const (
	esimFlagSize    = 416
	esimFlagCentreX = 160
)

var esimCountryCode = regexp.MustCompile(`^[a-z]{2}$`)

var esimCard = sync.OnceValue(func() image.Image {
	card, _, err := image.Decode(bytes.NewReader(esimCardPNG))
	if err != nil {
		panic("cardsweb: the embedded eSIM card does not decode: " + err.Error())
	}
	return card
})

// esimFlag is country's flag as a disc; nil for a region, or a code with none.
func esimFlag(country string) image.Image {
	code := strings.ToLower(strings.TrimSpace(country))
	if !esimCountryCode.MatchString(code) {
		return nil
	}
	data, err := esimFlags.ReadFile("assets/esim/flags/" + code + ".png")
	if err != nil {
		return nil
	}
	flag, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	return flag
}

// renderESIMBanner is the picture of an eSIM for country; empty draws the
// card with its globe (a region, the world, the shelf itself).
func renderESIMBanner(country string) ([]byte, error) {
	canvas := background(esimPalette)
	card := image.Rect(0, 0, cardWidth, cardHeight).Add(image.Pt(
		(bannerWidth-cardWidth)/2, (bannerHeight-cardHeight)/2))
	shadow(canvas, card)
	face := image.NewRGBA(image.Rect(0, 0, cardWidth, cardHeight))
	template := esimCard()
	draw.CatmullRom.Scale(face, face.Bounds(), template, template.Bounds(), draw.Src, nil)
	if flag := esimFlag(country); flag != nil {
		at := image.Rect(0, 0, esimFlagSize, esimFlagSize).Add(image.Pt(
			esimFlagCentreX-esimFlagSize/2, (cardHeight-esimFlagSize)/2))
		draw.CatmullRom.Scale(face, at, flag, flag.Bounds(), draw.Over, nil)
	}
	draw.DrawMask(canvas, card, face, image.Point{}, cardMask(), image.Point{}, draw.Over)
	mark := marks()[markSize]
	at := image.Pt(bannerWidth-markMargin-markSize, markMargin)
	draw.Draw(canvas, mark.Bounds().Add(at), mark, image.Point{}, draw.Over)
	return encode(canvas)
}

// esimPictureName is what an eSIM picture's address calls country: its code,
// or "world" for a region and the shelf.
func esimPictureName(country string) string {
	if code := strings.ToLower(strings.TrimSpace(country)); esimCountryCode.MatchString(code) {
		return code
	}
	return "world"
}

// esimBanner is the picture for an eSIM of country ("" or "world": the
// globe), drawn once and kept: there are only as many as there are flags.
func (p *previews) esimBanner(country string) *banner {
	name := esimPictureName(country)
	code := name
	if name == "world" {
		code = ""
	}
	p.mu.Lock()
	b := p.banners["esim:"+name]
	if b == nil || b.failed() {
		b = &banner{id: bannerID("esim", name), done: make(chan struct{})}
		b.render = func() ([]byte, error) { return renderESIMBanner(code) }
		p.banners["esim:"+name] = b
	}
	p.mu.Unlock()
	select {
	case <-b.done:
	default:
		go p.drawNow(b)
	}
	return b
}

// esimPicture is the address of country's picture.
func (p *previews) esimPicture(country string) string {
	return "og/esim/" + esimPictureName(country) + "." + p.esimBanner(country).id + ".jpg"
}
