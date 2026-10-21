/** A counter, so the doc snippets self-test has a published API to call. */
export class Tally {
  constructor(public readonly name: string, public count = 0) {}

  /** Adds `by`. */
  async bump(by = 1): Promise<Tally> {
    this.count += by;
    return this;
  }
}

/** A tally at zero. */
export function create(name: string): Tally {
  return new Tally(name);
}
