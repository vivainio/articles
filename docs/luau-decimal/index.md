---
icon: lucide/calculator
---

# A decimal type for Luau

I wanted to know what it would take to add a `decimal` type to
[Luau](https://luau.org/), and whether the result could be good enough to
propose upstream. So I built one in a fork, as a prototype that I could argue
about with evidence instead of opinions.

These pieces are the long-form version of that argument. A short RFC for the
Luau team will point here; the articles hold the detail that does not belong in
an RFC.

!!! note "Status"
    Work in progress. The implementation is a draft pull request in my fork
    ([vivainio/luau#1](https://github.com/vivainio/luau/pull/1)), nothing has
    been proposed to the Luau team yet, and every article says what is verified
    and what is not.

## What exists

- A `decimal` value type with literals (`19.99d`), the usual operators, a
  `decimal` library, and static types in both Luau type checkers.
- Semantics copied from .NET's `System.Decimal`, with one deliberate
  deviation: a 64-bit mantissa, so about 19 digits instead of 28.
- A [demo suite](https://github.com/vivainio/luau/tree/decimal-type/demos/decimal)
  of 13 runnable scripts with committed expected output, which doubles as the
  specification of what the implementation does today.

## Articles

- [Why money in Luau needs a decimal](motivation.md) — the scenario, what an
  embedder can do today (measured), and the narrow case for the core.
- [Checked against .NET](checked-against-dotnet.md) — 72 cases run through
  both implementations, what matched, and an explanation for each of the 13
  differences.
- [Why a 64-bit mantissa](why-64-bits.md) — the value layout, the alternatives
  and what each costs, what the choice gives up, and a correction to my own
  first argument.
- [Performance at a glance](performance.md) — every speed and memory number
  in the series on one page, interpreter and native code generation.
- [How decimals feel next to number, integer and vector](ergonomics.md) — an
  operation-by-operation comparison, the mixing rules, the error messages, the
  editor experience, and the costs you can feel.
- [What it took to build: a walkthrough](implementation-walkthrough.md) — the
  implementation layer by layer, where it lines up with `integer`, and the ten
  things the template did not predict.

## A taste

```lua
local total = 19.99d * 3d                 -- 59.97
print(0.1d + 0.2d == 0.3d)                -- true
print(decimal.round(total * 0.24d, 2))    -- 14.39
```

The first line is exact because `19.99d` is a decimal literal and not a binary
approximation of one. That is the whole pitch; the rest is making sure the
details hold up, and [the first article](motivation.md) says what the pitch is
for.
