# Extending the counter

A function of your own:

```ts
import { Tally } from "fixture-counter";

export async function bumpTwice(tally: Tally): Promise<number> {
  await tally.bump();
  await tally.bump();
  return tally.count;
}
```
