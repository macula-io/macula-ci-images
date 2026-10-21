# fixturecounter

A counter, so the self-test has a published API to call.

```go
import "example.org/fixturecounter/counter"

t := counter.New("apples")
if err := t.Bump(ctx); err != nil { ... }
fmt.Println(t.Count)
```

A block can list alternatives:

```go
t, err := counter.New("pears"), error(nil)
t, err := counter.New("plums"), error(nil)
```

<!-- doc_snippets: skip a counter-example: Reset was removed in 0.2 -->
```go
t.Reset()
```

```sh
go get example.org/fixturecounter
```
