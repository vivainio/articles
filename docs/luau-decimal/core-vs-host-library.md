# A core type or a host library?

*2026-10-18*

The [motivation article](motivation.md) compared the core decimal with two things
an embedder can build quickly: a decimal written in Luau and a small userdata. Both
were baselines, written to be measured. There is also a real one:
[`mlua-decimal`](https://github.com/vivainio/mlua-decimal), a crate that exposes an
exact decimal to Luau from the host side. It is a Rust userdata on top of the
`rust_decimal` crate, installed with one call (`mlua_decimal::install(&lua)`), and it
needs no change to the Luau VM. It is the best case for "just do it in the host", so
this article puts it next to the core type on the same questions as the other ones:
how it feels, what it matches in .NET, what it costs, and what the checker sees.

I wrote both, so I am comparing my own work against my own work; the harness and
every number are in the repository so that you do not have to take my word for it.

## What it is

From its README and source (268 lines of Rust):

- A `Decimal` userdata and a global `D`. `D"12.50"` parses a string (a string call,
  no parentheses), `D(3)` converts an integer, and `D.max`, `D.min` and `D.sum(list)`
  work on lists.
- Operators `+ - * / // %`, unary minus and ordering between decimals, through
  metamethods. Methods: `round(digits, mode)`, `floor`, `ceil`, `trunc`, `abs`,
  `sign`, `scale`, `normalize`, `is_integer`, `cmp`, `eq`, `lt`, `le`, `to_number`.
- `rust_decimal` underneath: a 96-bit mantissa, 28 digits, scale preserved
  (`1.10 * 3` is `3.30`).
- A deliberate rule so that "a precision bug is loud": an integer may stand in for
  an operand, a number **with a fraction** may not (`price * 0.1` is an error, write
  `price * D"0.1"`).
- Luau type definitions (`decimal.d.luau`) as a `declare extern type Decimal` with
  every method and operator, checked by `luau-lsp`.
- It builds against Luau, Lua 5.4, Lua 5.1 and LuaJIT.

That last point is a real strength the core type cannot match: the same script runs
on every Lua dialect `mlua` supports, because the type is a library, not a language
feature.

## Writing code with it

```lua
-- core type                          -- mlua-decimal
local total = 19.99d * 3d             local total = D"19.99" * D(3)
local tax = total * 0.24d             local tax = total * D"0.24"
print(decimal.round(tax, 2))          print(tax:round(2))
print(total < 100d)                   print(total < D(100))
print(typeof(total))                  print(typeof(total))            -- "decimal" / "Decimal"
```

The shapes are close. The differences:

| | core type | mlua-decimal |
|---|---|---|
| a constant | `19.99d`, a literal, folded by the compiler | `D"19.99"`, a call each time it runs |
| `type(x)` / `typeof(x)` | `decimal` / `decimal` | `userdata` / `Decimal` |
| mixing with an integer | `d + 1i` (an `integer`) | `d + 1` works: an integer-valued number is accepted |
| mixing with a number with a fraction | error, and a type error | error at run time only; the checker accepts it |
| `d < 5` | error | error |
| `d == 5` | `false`, and a type error under `--!strict` | `false`, and a type error under `--!strict` with the definitions file |
| library calls | `decimal.round(x, 2)` | methods: `x:round(2)` |
| rounding modes | five (half-even default, away from zero, to zero, floor, ceiling) | seven (adds `half_down` and a directed `up`), and negative digits round to tens |
| list helpers | none | `D.sum(list)`, `D.max(...)`, `D.min(...)` |

## What works on it

The same probe I ran against `number`, `integer`, `decimal` and `vector`
([ergonomics](ergonomics.md)), run against the userdata:

| Operation | core `decimal` | mlua-decimal |
|---|:-:|:-:|
| `a + a`, `a - a`, `a * a`, `a / a`, `a % a` | ✓ | ✓ |
| `a // a` | ✗ | ✓ (floored quotient) |
| `a ^ a` | ✗ | ✗ |
| `-a` | ✓ | ✓ |
| `a < a`, `a <= a`, `a == a` | ✓ | ✓ |
| `a + 1` (a plain number) | ✗ (write `1i`) | ✓ if it is an integer value |
| `a + 0.5` | ✗ | ✗ (at run time) |
| `a .. "x"` | ✗ | ✗ |
| `` `{a}` `` and `tostring(a)` | ✓ | ✓ |
| `table.sort({a, a})` | ✓ | ✓ |
| `table.find({a}, a)` | ✓ | ✓ |
| `t[a] = 1` as a table key | ✗ (an error) | accepted, but keyed by identity (`t[a:key()]` is the workaround) |
| `math.max`, `string.format("%s")` | ✗ | ✗ |

One row deserves a note. A userdata as a table key does not raise: it is accepted,
and a lookup with an equal value finds nothing (`t[D"1.5"]` returns `nil` after
`t[D"1.5"] = "first"`), because tables key userdata by identity. The core type raises
instead. Neither is a good answer, but silently returning `nil` is the one that
produces wrong results, and I think the error is the better of the two.

## Against .NET

I ran the same 75 hand-picked cases from the [.NET comparison](checked-against-dotnet.md)
through `mlua-decimal` (translated with `1.5d` becoming `D"1.5"`). The first run
gave 64 identical and 11 different, and the differences were informative enough
that I sent a pull request to the crate with the fixes; it is merged, and the table
below is the before and after.

| Case | .NET | mlua-decimal before | after the pull request |
|---|---|---|---|
| `0.00 + 1.5` | `1.50` | `1.5` | `1.50` |
| `0 * 123.456` | `0.000` | `0` | `0.000` |
| `-0.00` | `0.00` | `-0.00` (a negative zero) | `0.00` |
| `min(1.50, 1.5)` | `1.5` | `1.50` | `1.5` |
| `D(0.1)`, `D(1/3)`, `D(1e-30)` | converts | error, by design | `D.from_float(...)` converts (`D(0.1)` is still an error) |
| `1/2` | `0.5` | `0.50` | `0.50` |
| `10/4` | `2.5` | `2.50` | `2.50` |
| `0.00/5` | `0.00` | `0` | `0` |
| `1/0` | `DivideByZeroException` | an error with different text | the same |

The first four rows are fixed. The crate's README says "the scale is kept", and
`rust_decimal` quietly drops the scale of a result when an operand is zero, so
those were bugs relative to its own promise. The conversion is now available as an
explicit call. What remains is the division scale: the crate follows
`rust_decimal` (`10/4` is `2.50`), .NET removes the trailing zeros down to the
preferred scale (`2.5`), and the crate's tests and docs assert the first, so I left
it for the author to decide. After the change the crate differs from .NET in 6 of
the 75 lines.

**The core type differs from .NET in:** the 28th digit of non-terminating quotients
(27 digits against 28), a range 64 times smaller, the double conversion (2 cases),
and the error text.

Read the two as opposites. `rust_decimal` has the full 28 to 29 digits and the
.NET range, which the core type gives up for the 12-byte value slot. The core type
has the .NET *rule* for division (preferred scale, quotients that underflow are `0`),
which `rust_decimal` does differently. If you need every digit of .NET's range today, the crate is the better
answer. If you need the same answers as .NET on money-shaped inputs, the core type
is closer.

## What it costs

Same machine, same loops. `mlua` vendors its own copy of Luau, built with different
flags: a plain number addition takes 3.5 ns there and 1.5 ns in this repository's
build, so the ratios to the number baseline are the fair comparison and the absolute
times are not.

| Operation | core `decimal` | mlua-decimal | ratio |
|---|---:|---:|---:|
| addition, same scale | 4.2 ns | 184 ns | 44 times |
| addition, different scales | 15 ns | 183 ns | 12 times |
| `x < y` | 3.5 ns | 53 ns | 15 times |
| `x == y` (scales 0 and 1) | 9 ns | 44 ns | 5 times |
| `round(x * 1.01, 2)` | 51 ns | 384 ns | 8 times |
| `x += y / 3` | 123 ns | 399 ns | 3 times |
| sum an array, per element, in a loop | 4.2 ns | 190 ns | 45 times |
| parse `"19.99"` | 24 ns (`decimal.fromstring`) | 214 ns (`D"19.99"`) | 9 times |
| the literal `19.99d` | 1.4 ns (a constant load) | 214 ns | 150 times |
| `tostring(x)` | 38 ns | 131 ns | 3.5 times |
| memory per stored value | 16 bytes | 85 bytes | 5 times |

Against its own number baseline, an addition is about 50 times a double addition for
`mlua-decimal` and about 3 times for the core type.

Most of the 184 ns is not arithmetic. The host-registered userdata baseline from the
motivation article, written in C++ against the same Luau API, does an addition in
about 70 ns, with the same kind of allocation and metamethod dispatch. The extra
110 ns or so is the binding layer: converting the arguments into `mlua` values,
borrowing the userdata, and building the result. I did not profile it, and I would
expect a leaner binding to close part of the gap. The allocation stays: 85 bytes per
value is a Luau userdata and the layer around it.

The table ends on the point that matters to the use case in the
[motivation](motivation.md): a script that handles a million order lines. At 180 ns
an operation that is 0.2 seconds per million additions; at 4 ns it is 4 ms. For one
pricing rule per request, neither is visible.

## What the checker sees

The crate documents this honestly in `docs/type-checking.md`. The checker reads only
Luau source and a definitions file, so the type exists only if the file is given to
`luau-lsp`. With it, under `--!strict`:

- `price == 12.5` and `price < 20` are type errors.
- `price * 0.1` is **not**: arithmetic is declared to accept `number`, and with no way
  to say "integers only" the mistake is found when it runs.
- A value that reaches the script as `any` is unchecked until it is wrapped in
  `D(...)`, which takes `any` on purpose.

With the core type the same mistakes are reported without any file, in both Luau
solvers: `d * 0.1` is a type error because a number is not a decimal, and the
operators are known to the analyzer. The difference is `integer`: the language has a
type that means "an exact whole number", so `d * 0.1` can be refused statically while
`d * 1i` passes. That is a small advantage that only a core type can have, because it
depends on the language already distinguishing the two.

## Where each wins

**`mlua-decimal` wins** when you are a Rust host and you want an exact decimal now.
It works on stock Luau with no fork, it has the full 28 to 29 digits and the .NET
range, it has more rounding modes and list helpers, it ships type definitions and a
documentation site, and it also runs on Lua 5.4, 5.1 and LuaJIT. Those are real
advantages, and none of them depends on the language changing.

**The core type wins** on everything that needs the language to cooperate: a literal
(`19.99d`), a primitive that `typeof` and the checker know without a definitions
file, no allocation per value (16 bytes and a few nanoseconds against 85 bytes and a
few hundred), one definition for every host language (C++, C, Rust, anything that
embeds Luau), constant folding and bytecode constants, mixing with `integer`, and
rules that match .NET's on the cases above.

The honest summary of the choice is the one from the motivation article, now with a
measurement behind it: for one Rust application the crate is a fine answer; for a
language that many hosts embed and many people script, the cost of the host-library
approach is paid in every script and every host.

## What this suggests changing in the core type

Comparing against a careful library is a good way to find what is missing. Four
things I would borrow, none of them large:

1. **`decimal.sum(list)`.** A sum over a list is the most common reduction in money
   code. In the crate `D.sum` is 4 times cheaper per element than a loop (43 ns
   against 190 ns), which says more about the binding than the design; in the core
   type the loop is already 4 ns per element, so the reason to add it is
   readability.
2. **`normalize` and `is_integer`.** Scale preservation is a feature, but converting
   `1.500` to `1.5` is a request people make. It is one function.
3. **More rounding modes.** `half_down`, and a directed "away from zero" (the crate's
   `up`, which always moves away, as opposed to .NET's `AwayFromZero`, which only
   moves away at a tie). Both exist in other decimal libraries.
4. **A decision about integer-valued numbers.** The crate accepts `d + 1` because `1`
   is an integer value, and rejects `d + 0.5`. That is convenient, but it is a check
   at run time that the type system cannot see: `price * 0.1` type-checks and fails
   later. The core type refuses every number and asks for `1i`, which is strict and
   slightly irritating, and which the checker can enforce. I think strict is right
   for money, but it is a choice, and the crate's choice is the friendlier one.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
./demos/decimal/external/run.sh
```

The script builds a small Rust harness that installs the crate (the first run
downloads and compiles `mlua` with a vendored Luau, about a minute) and prints the
benchmarks, the probe and the .NET differences. The scripts it runs are in
`demos/decimal/external/`.

*Measured on an Apple M3 with `mlua-decimal` at its `main` branch on 2026-10-18 and
the `decimal-type` branch of my fork. One machine, one run of the harness; treat
differences under about 20 % as noise.*
