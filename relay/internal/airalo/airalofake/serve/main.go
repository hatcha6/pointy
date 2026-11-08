// Command serve runs the fake Airalo Partner API on a port, for driving the relay
// and the app end to end: go run ./internal/airalo/airalofake/serve -addr :8097.
package main

import (
	"flag"
	"log"
	"net/http"

	"pointy/relay/internal/airalo/airalofake"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8097", "the address to listen on")
	flag.Parse()
	log.Printf("fake Airalo on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, airalofake.New().Handler()))
}
