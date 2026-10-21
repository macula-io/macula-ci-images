// Package counter is a counter, so the doc snippets self-test has a published
// API to call.
package counter

import "context"

// Tally counts one thing.
type Tally struct {
	Name  string
	Count int
}

// New starts a tally at zero.
func New(name string) *Tally { return &Tally{Name: name} }

// Bump adds one.
func (t *Tally) Bump(ctx context.Context) error {
	t.Count++
	return ctx.Err()
}
