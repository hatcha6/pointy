package reloadly

import (
	"context"
	"net/url"
	"strconv"
)

const (
	// pageSize is what every list asks for. Reloadly caps it per endpoint (gift
	// products 200, gift reports 50, top-up reports 500, operators and billers
	// 1000) and says what it used in pageable.pageSize, so the loops below trust
	// "last" and "totalPages", never the size they asked for.
	pageSize = 200
	// maxPages stops a server that ignores "page" from looping for ever.
	maxPages = 500
)

// pageOf is the envelope of every paged list. Pages are numbered from 1: page=0
// answers the same rows as page=1 (so a loop that starts at 0 reads the first
// page twice and, counting totalPages pages, never reaches the last one).
type pageOf[T any] struct {
	Content       []T   `json:"content"`
	TotalPages    int   `json:"totalPages"`
	TotalElements int   `json:"totalElements"`
	Last          *bool `json:"last"`
}

// listAll reads every page of a list. key names a row (its id); a row seen
// twice is dropped, and a page of nothing but rows already seen ends the loop.
func listAll[T any](ctx context.Context, c *Client, r request, key func(*T) string) ([]T, error) {
	var out []T
	seen := map[string]bool{}
	for page := 1; page <= maxPages; page++ {
		pageRequest := r
		pageRequest.query = cloneQuery(r.query)
		pageRequest.query.Set("size", strconv.Itoa(pageSize))
		pageRequest.query.Set("page", strconv.Itoa(page))
		raw, err := c.do(ctx, pageRequest)
		if err != nil {
			return nil, err
		}
		var envelope pageOf[T]
		if err := decode(pageRequest, raw, &envelope); err != nil {
			return nil, err
		}
		fresh := 0
		for i := range envelope.Content {
			row := &envelope.Content[i]
			if id := key(row); id != "" {
				if seen[id] {
					continue
				}
				seen[id] = true
			}
			out = append(out, *row)
			fresh++
		}
		last := envelope.Last != nil && *envelope.Last
		if len(envelope.Content) == 0 || fresh == 0 || last || (envelope.TotalPages > 0 && page >= envelope.TotalPages) {
			break
		}
	}
	return out, nil
}

func cloneQuery(query url.Values) url.Values {
	out := make(url.Values, len(query)+2)
	for key, values := range query {
		out[key] = append([]string(nil), values...)
	}
	return out
}
