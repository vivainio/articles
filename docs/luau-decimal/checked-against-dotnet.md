# Checked against .NET

*2026-10-18*

If a new numeric type claims to behave "like .NET's `decimal`", the claim
should be tested, not asserted. .NET is installed on my machine, so I did the
obvious thing: wrote the same 75 cases twice, once in C# against
`System.Decimal` and once in Luau against the new type, and compared the
output line by line.

The harness is part of the
[demo suite](https://github.com/vivainio/luau/tree/decimal-type/demos/decimal/dotnet).
It needs only the `dotnet` SDK and the `luau` binary, and the set of
differences it is allowed to find is committed next to it, so any change in
behavior shows up as a failing diff.

## What was compared

| Area (grouped by case label) | Cases |
|---|---|
| Division, including the scale of the result, underflow to zero and division by zero | 28 |
| Rounding with every mode, `floor`, `ceil`, `trunc`, `abs` | 15 |
| Addition, subtraction, multiplication and their scale rules | 12 |
| Parsing strings and converting doubles | 8 |
| Remainder | 6 |
| `min` and `max` on equal values with different scales | 3 |
| Overflow, scale, equality | 3 |
| **Total** | **75** |

These are hand-picked cases, chosen to hit the rules that are easy to get wrong.
For breadth there is a second check that does not need .NET: a fuzzer that runs
millions of random operations and compares them with Python's `decimal` module.
That one is described in [Why a 90-bit mantissa](why-90-bits.md). The .NET harness
answers a different question, which is whether the *rules* are the .NET ones.

## The result: 64 of 75 identical

Everything that is about *semantics* matched, including the parts I was least
sure about when I started:

- **Division keeps the "preferred scale".** `6/2` is `3`, `1.00/2` is `0.50`,
  `7.50/2.5` is `3.0`, `0.00/5` is `0.00`, `12.5/0.25` is `50`. I had
  implemented that from memory of how IEEE-style decimals work, and only the
  comparison could tell me it was what .NET does. It was.
- **Scale rules for `+`, `-` and `*`.** `1.50 + 1.5 = 3.00`, `1.5 * 2 = 3.0`,
  `1.50 * 2.0 = 3.000`, `0 * 123.456 = 0.000`.
- **Equality ignores scale, printing does not.** `1.50 == 1.5` is true and the
  two print differently, in both.
- **Remainder** takes the sign of the dividend, and its scale is the larger of the
  operands' scales.
- **Rounding.** Half-even is the default (`Math.Round(2.5) = 2`), and
  `AwayFromZero`, `ToZero` and `ToNegativeInfinity` agree on the inputs in the
  harness (one or two per mode, so this is a spot check, not a proof).
- **Zero keeps its scale** (`0.00 + 1.5 = 1.50`) and there is no negative zero
  (`-0.00` prints `0.00`).
- **Large values.** `9223372036854775807 * 10` and `92233720368547758.07 + 0.01`
  are exact in both. They were overflow and a lost digit in the 64-bit version of
  the prototype; a 90-bit mantissa makes them agree.
- **Long text.** Parsing `0.1234567890123456789012345678901` gives
  `0.1234567890123456789012345679` in both, rounded half-even to 28 digits.
- **Division by zero raises** in both.

Two *semantic* differences turned up over the course of this work, and both were
bugs of mine:

1. `min` of `1.50` and `1.5` returned the first argument where .NET returns the
   second. .NET's `Math.Max(x, y)` keeps `x` on ties and `Math.Min(x, y)` takes `y`.
2. A quotient that rounds to zero is plain `0` in .NET (`1e-28 / 3` prints `0`),
   not `0.00` at the preferred scale and not a zero with 28 decimals. I had assumed
   the preferred-scale rule applied to zero too. The random fuzzer found the
   disagreement with my own reference first; running the case on .NET settled which
   side was right.

Both are fixed and have regression tests.

## The 11 differences

All of them have a reason, and none is a surprise once you know the decision
behind them: the value is a 90-bit mantissa and a scale, which is 27 digits always
and 28 up to 1.24 × 10²⁷, where .NET's 96-bit mantissa has 28 or 29.

### The 28th digit (7 lines)

| Case | .NET | Luau |
|---|---|---|
| `1/3` | `0.3333333333333333333333333333` | `0.333333333333333333333333333` |
| `2/3` | `0.6666666666666666666666666667` | `0.666666666666666666666666667` |
| `-1/3` | `-0.3333333333333333333333333333` | `-0.333333333333333333333333333` |
| `100/3` | `33.333333333333333333333333333` | `33.3333333333333333333333333` |
| `0.5/3` | `0.1666666666666666666666666667` | `0.166666666666666666666666667` |
| `1.000/3` | `0.3333333333333333333333333333` | `0.333333333333333333333333333` |
| `1/3*3` | `0.9999999999999999999999999999` | `0.999999999999999999999999999` |

A quotient like a third has 28 digits in .NET and 27 here, because
`0.3333333333333333333333333333` as a mantissa is 3.3 × 10²⁷, above the largest
90-bit mantissa (1.24 × 10²⁷). The last row is worth noting: `(1/3)*3` does not
come back to `1` in either, which is what a base-10 third looks like. In the 64-bit
version it did come back to `1`, because the 19-digit product was rounded. Less
precision had been hiding a real property of the arithmetic; at 90 bits it no
longer does.

### Range (1 line)

| Case | .NET | Luau |
|---|---|---|
| `0.5 / 79228162514264337593543950335` | `0` | error |

The divisor is 2⁹⁶ − 1, the largest .NET decimal, and it has 29 digits, so it does
not exist here: `decimal.fromstring` returns `nil` for it. The largest value is
1,237,940,039,285,380,274,899,124,223, 64 times smaller than .NET's.

### Error text (1 line)

| Case | .NET | Luau |
|---|---|---|
| `1/0` | `DivideByZeroException` | error: `decimal division by zero` |

### Converting doubles (2 lines)

| Case | .NET | Luau |
|---|---|---|
| `(decimal)(1.0/3.0)` | `0.333333333333333` | `0.3333333333333333` |
| `(decimal)1e-30` | `0` | `0.0000000000000000000000000000` |

.NET rounds a double to 15 significant digits when converting, so
`(decimal)0.1` is `0.1` but the conversion also quietly throws away the 16th and
17th digits of anything else. `decimal.create` uses the shortest string that
round-trips the double, which keeps all the information a double actually has. I
think that is the better behavior, and I kept it on purpose; it is the one place
where the type does not copy .NET.

The second row is a cosmetic difference: underflow to zero keeps scale 28 here and
scale 0 there.

## What I take from this

1. **The semantics transfer.** Scale preservation, the division rule, rounding
   modes, tie-breaking and underflow are the parts that are tedious to get right,
   and they match. A user who knows `System.Decimal` can predict this type, with a
   one-digit and a range caveat.
2. **The deviations are all about size or about the double conversion.** The 28th
   digit and the 64-times-smaller range come from the 90-bit mantissa, and the
   other three lines are an error message and the double conversion. Nothing needs
   a separate explanation.
3. **Comparison against a reference beats reading the spec.** My own description of
   .NET's division rule was a guess when I wrote it down, and so was my belief
   about what a quotient that underflows looks like. The check is cheap enough to
   keep as part of the test suite.

The next article, [Why a 90-bit mantissa](why-90-bits.md), explains where the width
comes from and what the alternatives would have cost.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
./demos/decimal/dotnet/compare.sh --full     # both outputs, side by side
./demos/decimal/dotnet/compare.sh            # check against the expected differences
```

*Pinned to the `decimal-type` branch of my fork at the time of writing;
verified with .NET SDK 10.0.401.*
