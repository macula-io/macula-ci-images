# Extending the counter

A function of your own, calling the package:

```go
func bumpTwice(ctx context.Context, t *counter.Tally) error {
	if err := t.Bump(ctx); err != nil {
		return err
	}
	return t.Bump(ctx)
}
```

A whole program:

```go
package main

import (
	"context"
	"fmt"

	"example.org/fixturecounter/counter"
)

func main() {
	t := counter.New("figs")
	_ = t.Bump(context.Background())
	fmt.Println(t.Count)
}
```
