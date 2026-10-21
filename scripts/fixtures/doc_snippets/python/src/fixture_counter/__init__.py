"""A counter, so the doc snippets self-test has a published API to call."""

from dataclasses import dataclass


@dataclass
class Tally:
    """Counts one thing."""

    name: str
    count: int = 0

    async def bump(self, by: int = 1) -> "Tally":
        """Adds `by`."""
        self.count += by
        return self


def new(name: str) -> Tally:
    """A tally at zero."""
    return Tally(name)
