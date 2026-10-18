# Checked against .NET

*2026-10-18 · draft*

If a new numeric type claims to behave "like .NET's `decimal`", the claim
should be tested, not asserted. .NET is installed on my machine, so I did the
obvious thing: wrote the same 72 cases twice, once in C# against
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
| Division, including the scale of the result and division by zero | 25 |
| Rounding with every mode, `floor`, `ceil`, `trunc`, `abs` | 15 |
| Addition, subtraction, multiplication and their scale rules | 12 |
| Parsing strings and converting doubles | 8 |
| Remainder | 6 |
| `min` and `max` on equal values with different scales | 3 |
| Overflow, scale, equality | 3 |
| **Total** | **72** |

## The result: 59 of 72 identical

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
- **Remainder** takes the sign of the dividend, and its scale is the larger of
  the operands' scales.
- **Rounding.** Half-even is the default (`Math.Round(2.5) = 2`), and
  `AwayFromZero`, `ToZero` and `ToNegativeInfinity` agree on the inputs in the harness (one or two per mode, so this is a spot check, not a proof).
  Rounding to more places than the value has leaves it alone.
- **Zero keeps its scale** (`0.00 + 1.5 = 1.50`) and there is no negative zero
  (`-0.00` prints `0.00`).
- **Division by zero raises** in both.

Only one *semantic* difference turned up, and it was a bug of mine: `min` of
`1.50` and `1.5` returned the first argument where .NET returns the second.
.NET's `Math.Max(x, y)` keeps `x` on ties and `Math.Min(x, y)` takes `y`. That
is fixed and has a regression test.

## The 13 differences

All of them have a reason, and none is a surprise once you know the one design
decision behind them: the value is a 64-bit integer mantissa and a scale, which
leaves about 19 significant digits where .NET's 96-bit mantissa has 28 or 29.

### Fewer digits (8 lines)

| Case | .NET | Luau |
|---|---|---|
| `1/3` | `0.3333333333333333333333333333` | `0.3333333333333333333` |
| `2/3` | `0.6666666666666666666666666667` | `0.6666666666666666667` |
| `-1/3` | `-0.3333333333333333333333333333` | `-0.3333333333333333333` |
| `100/3` | `33.333333333333333333333333333` | `33.33333333333333333` |
| `0.5/3` | `0.1666666666666666666666666667` | `0.1666666666666666667` |
| `1.000/3` | `0.3333333333333333333333333333` | `0.3333333333333333333` |
| parse a 31-digit string | `0.1234567890123456789012345679` | `0.1234567890123456789` |
| `1/3*3` | `0.9999999999999999999999999999` | `1.000000000000000000` |

The last row is the most instructive. In .NET, `(1/3)*3` visibly fails to
return to 1, which is what a base-10 third looks like. Here the 19-digit
product `0.9999999999999999999` does not fit in a 63-bit mantissa, so it is
rounded to 18 digits and lands on `1`. Less precision accidentally hides a
real property of the arithmetic. That is the cost of the design, stated as
plainly as I can.

### Smaller range (3 lines)

| Case | .NET | Luau |
|---|---|---|
| `9223372036854775807 * 10` | `92233720368547758070` | error: `decimal overflow` |
| `92233720368547758.07 + 0.01` | `92233720368547758.08` | `92233720368547758.1` |
| `1/0` | `DivideByZeroException` | error: `decimal division by zero` |

The first two are the same story: the exact result needs more than 63 bits.
Luau rounds the low digits when it can (lowering the scale) and raises when it
cannot (an integer larger than about 9.2e18 has no scale to give up). The
third row is only a difference in the error text.

### Converting doubles (2 lines)

| Case | .NET | Luau |
|---|---|---|
| `(decimal)(1.0/3.0)` | `0.333333333333333` | `0.3333333333333333` |
| `(decimal)1e-30` | `0` | `0.0000000000000000000000000000` |

.NET rounds a double to 15 significant digits when converting, so
`(decimal)0.1` is `0.1` but the conversion also quietly throws away the 16th
and 17th digits of anything else. `decimal.create` uses the shortest string
that round-trips the double, which keeps all the information a double
actually has. I think that is the better behavior, and I kept it on purpose;
it is the one place where the type does not copy .NET.

The second row is a cosmetic difference: underflow to zero keeps scale 28 here
and scale 0 there.

## What I take from this

1. **The semantics transfer.** Scale preservation, the division rule,
   rounding modes and tie-breaking are the parts that are tedious to get
   right, and they match. A user who knows `System.Decimal` can predict this
   type, with a precision caveat.
2. **The deviations are all about size.** Every remaining difference is the
   64-bit mantissa or the double-conversion choice. There is no behavior in
   the list that needs a separate explanation.
3. **Comparison against a reference beats reading the spec.** My own
   description of .NET's division rule was a guess when I wrote it down. The
   check is cheap enough to keep as part of the test suite.

The next article explains why the mantissa is 64 bits and what the
alternatives would have cost.

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
