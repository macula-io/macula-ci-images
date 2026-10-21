# fixture-counter

A counter, so the self-test has a published API to call.

```ts
import {
  Tally,
  create,
} from "fixture-counter";

const tally: Tally = create("apples");
await tally.bump();
console.log(tally.count, { realm });
```

A later block can use what the prose made, and list alternatives:

```ts
const again = await existing.bump(2);
const again = await existing.bump(3);
```

The same from JavaScript:

```js
import { create } from "fixture-counter";

create("pears").bump().then((t) => console.log(t.count));
```

<!-- doc_snippets: skip a counter-example: reset was removed in 0.2 -->
```ts
tally.reset();
```

```sh
npm install fixture-counter
```
