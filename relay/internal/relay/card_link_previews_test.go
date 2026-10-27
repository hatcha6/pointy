package relay

import (
	"bytes"
	"context"
	"image"
	_ "image/png"
	"testing"
)

func TestLinkPreviewsReadTheWebShelfAndItsArt(t *testing.T) {
	h := newOrderHarness(t)
	ctx := context.Background()
	shelf, err := h.server.PreviewCatalog(ctx)
	if err != nil {
		t.Fatal(err)
	}
	itunes, ok := shelf.Brands["itunes"]
	if !ok || len(shelf.Brands) != 2 || itunes.Name == "" || itunes.Category == "" {
		t.Fatalf("the web shelf: %+v", shelf)
	}
	if shelf.Categories[itunes.Category] == "" {
		t.Fatalf("category %q unnamed: %+v", itunes.Category, shelf.Categories)
	}
	art, err := h.server.PreviewArt(ctx, itunes.Art)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := image.Decode(bytes.NewReader(art)); err != nil {
		t.Fatalf("art does not decode: %v", err)
	}
	if _, err := h.server.PreviewArt(ctx, "https://elsewhere.example/logo.png"); err == nil {
		t.Fatal("an image from elsewhere was fetched")
	}
}

func TestARelayThatSellsNoCardsPreviewsNoBrand(t *testing.T) {
	shelf, err := HTTPServer{}.PreviewCatalog(context.Background())
	if err != nil || len(shelf.Brands) != 0 {
		t.Fatalf("%+v %v", shelf, err)
	}
}
