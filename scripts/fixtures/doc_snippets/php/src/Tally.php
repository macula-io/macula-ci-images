<?php

declare(strict_types=1);

namespace FixtureCounter;

/**
 * A tally of one kind of thing, so the docs have something to count.
 */
final class Tally
{
    private int $count = 0;

    public function __construct(private readonly string $label)
    {
    }

    /**
     * A new tally, in the shape a quick start opens with.
     */
    public static function new(string $label): self
    {
        return new self($label);
    }

    /**
     * Count one more, and answer the new count.
     */
    public function bump(): int
    {
        return ++$this->count;
    }

    public function count(): int
    {
        return $this->count;
    }

    public function label(): string
    {
        return $this->label;
    }

    /**
     * The call the docs warn against: it drops the count and every holder of
     * the tally keeps a stale one. Here it is a counter-example, not a service.
     */
    public static function reset(): void
    {
        throw new \LogicException('reset drops counts');
    }
}
