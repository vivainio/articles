# Why a 90-bit mantissa

*2026-10-18*

.NET's `decimal` has 28 or 29 significant digits. The Luau prototype has 27, and
28 up to 1.24 × 10²⁷. That small gap is the result of a decision with a history,
and the history is worth telling because the first version of the argument was
wrong. This article is the account: what fits in a Luau value, what that allows,
what each width costs, and what the 90-bit choice gives up compared with .NET.

## The short version

A decimal here is a 90-bit mantissa, a sign and a scale from 0 to 28, packed into
the VM's ordinary 16-byte value slot, with no heap allocation. That is the widest
mantissa that fits. I started with a 64-bit mantissa, wrote that it was the only
layout that fits (it is not), built the arithmetic that a wider one needs, fuzzed
it against Python, and switched. The price is some speed (an addition went from
about 2.7 ns to about 4.2 ns) and a 256-bit arithmetic core.

## What a Luau value looks like

Every Luau value is a `TValue`. In this tree it is 16 bytes (I checked with
`sizeof`, not from memory):

```text
offset  0 ........ 7    8 ........ 11    12 ....... 15
        Value (8 bytes)  extra[1] (4)     tt (type tag, 4)
```

`Value` is a union of a double, a 64-bit integer, a pointer and a few other
things. `extra` exists for a single reason: a vector with three `float`
components needs 12 bytes, and `extra` is where the third one lives. The
`LUA_VECTOR_SIZE` configuration is 3 by default, which gives `extra` one `int`.
So the usable payload of a value type is **12 bytes**, and the type tag is
separate.

The existing value types sit inside that budget:

| Type | Payload |
|---|---|
| `number` | 8-byte double |
| `integer` | 8-byte `int64` |
| `vector` (3 floats) | 12 bytes, all of it |
| `boolean`, light userdata | 1 or 8 bytes |
| everything else (`string`, `table`, `buffer`, …) | an 8-byte pointer to a garbage-collected object |

Anything that does not fit in 12 bytes has to be a pointer to a heap object. That
is what `buffer` is, and what vectors become when Luau is built with
double-precision components.

## What .NET's decimal needs

`System.Decimal` is a 96-bit mantissa, a sign, and a scale from 0 to 28. The scale
needs 5 bits and the sign 1, so the minimum is 96 + 1 + 5 = 102 bits. The payload
is 96 bits. **An exact copy of .NET's layout does not fit** in the default build.

(With `LUA_VECTOR_SIZE` set to 4, `extra` has two `int`s and it would fit, but
then every value in the VM is 24 bytes; I checked that too. That is not a
configuration I can assume.)

## What fits instead

The 96 bits of payload can hold the sign and the scale if the mantissa gives up 6
bits:

```text
 90 bits mantissa + 5 bits scale + 1 bit sign = 96 bits = 12 bytes
 low 64 bits of the mantissa           -> Value::l
 high 26 bits, scale (5), sign (1)     -> extra[0]
```

A 90-bit mantissa goes up to 2⁹⁰ − 1 = 1,237,940,039,285,380,274,899,124,223.
That is 28 digits, but only up to 1.24 × 10²⁷, so **27 digits always fit** and a
28-digit number fits if it is small enough. Zero is never negative, so equal
values with the same scale have identical bits.

## How I got here

The first version used a 64-bit mantissa. The reason was the arithmetic, not the
storage. Multiplying two 63-bit mantissas gives up to 126 bits, which fits the
compiler's `__int128` exactly, so every operation was: widen, compute exactly,
round to fit, narrow. The whole library was a few hundred lines.

When I wrote that decision down, I said a 64-bit mantissa was "the only layout
that stays a value type". That was wrong, and the arithmetic above is the real
reason, not the slot. Counting the bits for this article is what showed it: 90
bits fit.

What a 90-bit mantissa needs is exactly what the 64-bit design avoided. Two 90-bit
mantissas multiply to 180 bits. Aligning scales multiplies by up to 10²⁸, which is
94 bits. Division scales the numerator by a power of ten before dividing. So
exact intermediates need more than 128 bits: a 256-bit unsigned integer with
add, subtract, compare, multiply, division with remainder, powers of ten and a
digit count.

I built that as a separate piece first (`VM/src/lwide.h`, about 300 lines) and
tested it before touching the representation:

- **Portable.** Eight 32-bit limbs, so every intermediate fits in a `uint64_t`
  and nothing needs a compiler extension. Division is Knuth's algorithm D.
- **Fuzzed against Python's integers.** 2.7 million cases with random,
  boundary-limb and realistic operands (a mantissa times a power of ten, a
  scaled numerator over a mantissa), plus the classic corner cases of algorithm D.
- **The fuzzer was mutation-tested.** Four deliberately broken versions (no
  add-back step in the division, no second-limb check on the quotient estimate, a
  broken borrow, a broken carry) were all caught, including the rarest path,
  which a fuzzer of uniformly random numbers would never reach.
- **Cheap enough.** Addition 0.6 ns, a 90×90-bit multiply 2.5 ns, a 160÷90-bit
  division 27 ns.

Then I ported the decimal arithmetic to it, widened the representation through
the parser, compiler, bytecode and VM, and tested everything.

## What changed in the rules

Going back to the arithmetic rules with a wider intermediate made them simpler and
exposed two things the 64-bit version got wrong.

- **No special cases for large scale gaps.** With 256 bits, addition aligns the
  scales exactly (a 90-bit number times 10²⁸ is 184 bits) and never needs to drop
  digits early.
- **One rounding, not two.** A result is rounded half-even once, to the finest
  scale at which the mantissa fits. The old code could round, find the result
  one digit too large, and round again.
- **An integer part that does not fit is an overflow.** The old code could round
  a number slightly above the maximum to the nearest ten and return that. A
  decimal never silently loses digits left of the point.
- **A quotient that rounds to zero is plain `0`.** I found this one by fuzzing
  and checked it against .NET, which returns scale 0 (`1e-28 / 3` prints `0`).
  A zero dividend keeps the preferred scale, as before.

## What each width gives you

| Decimal places | Largest amount, 64-bit | **90-bit (this)** | .NET (96-bit) |
|---|---|---|---|
| 2 (cents) | 92,233,720,368,547,758.07 | **12,379,400,392,853,802,748,991,242.23** | 792,281,625,142,643,375,935,439,503.35 |
| 4 | 922,337,203,685,477.5807 | **123,794,003,928,538,027,489,912.4223** | 7,922,816,251,426,433,759,354,395.0335 |
| 8 (satoshi) | 92,233,720,368.54775807 | **12,379,400,392,853,802,748.99124223** | 792,281,625,142,643,375,935.43950335 |
| 18 (wei) | 9.223372036854775807 | **1,237,940,039.285380274899124223** | 79,228,162,514.264337593543950335 |

For ordinary money any of these is more than enough. The last row is where the
64-bit version failed: a token with 18 decimals, the Ethereum convention, could
not hold more than about 9.2 units. At 90 bits it holds over a billion, which
covers most supplies; at .NET's width, about 79 billion. The range is 64 times
smaller than .NET's (2⁹⁰ against 2⁹⁶) and that is the main thing left to give
up.

## What the widening cost

**Speed.** Measured on an Apple M3 (the [performance page](performance.md) has
all the tables):

| | 64-bit | 90-bit, first | 90-bit, optimised |
|---|---:|---:|---:|
| same-scale addition, interpreter | 2.7 ns | 4.9 ns | 4.2 ns |
| same-scale addition, native code generation | 2.9 ns | 6.4 ns | 4.2 ns |
| addition with different scales | 9 ns | 28 ns | 15 ns |
| `round(x * 1.01d, 2)` | 48 ns | 82 ns | 51 ns |
| division plus addition | 135 ns | 286 ns | 123 ns |
| comparison (same scale) | 3.1 ns | 3.1 ns | 3.5 ns |

The first 90-bit version was about twice as slow as the 64-bit one on the common
operations, in the 256-bit core and in converting the split mantissa to and from
a signed integer on every read and write. An optimisation pass (working on the
packed sign and magnitude directly, an early exit in the rounding step, fewer
divisions) got most of it back: the common case is within a factor of 1.5 of the
64-bit version, and division is faster than it was.

**Code.** The library file went from 789 to 842 lines and gained a 295-line
helper. The special cases for results that would not fit in 128 bits are gone,
which is most of what the extra helper replaced.

**Portability.** The arithmetic is portable. What is not is the type that carries
a mantissa through the parser, compiler and bytecode: `DecimalMantissa` is a
typedef for `__int128`, which MSVC does not have, and the interpreter's fast path
uses an overflow-checking multiply that is a GCC and Clang builtin. Both are
small and local (one typedef and a handful of operators in one header, and one
function), so supporting MSVC is a contained job. I have not done it.

**Memory.** Unchanged: 16 bytes per value, nothing else.

## How I know it is right

- **Differential test of every operation.** `decimal-fuzz.py` runs the operators
  and the library functions in Luau, in the interpreter and with native code
  generation, and compares them with a reference built on Python's `decimal`
  module and integers: add, subtract, multiply, divide, remainder, negate, abs,
  all comparisons, min and max, rounding in all five modes, floor, ceil, trunc,
  sign, scale, `tonumber`, `tostring`, mixing with integers, and parsing valid
  and invalid text. A run of 3.8 million cases with a fresh seed found no
  mismatches. (Earlier runs found 248, all one rule I had misremembered, which
  is how the zero-quotient rule above was found.)
- **The fuzzer is sensitive.** Changing half-even rounding to half-up in one
  function made 738 of 235,500 cases fail.
- **The existing tests.** All 6,019 pass under both type solvers, the 13 demos
  produce byte-identical output in both modes, and the [.NET
  comparison](checked-against-dotnet.md) is down to 11 differing lines out of
  75, nearly all of them the 28th digit.

## The alternatives, once more

| Option | Digits | Allocates | Arithmetic you must write | Verdict |
|---|---|---|---|---|
| Inline 64-bit mantissa | 18–19 | no | `__int128` | the first version |
| **Inline 90-bit mantissa** | 27–28 | no | 256-bit helper (done, fuzzed) | **chosen** |
| Exact .NET layout (96 + sign + scale) | 28–29 | no, but only if `TValue` grows | 192/256-bit | needs `LUA_VECTOR_SIZE` 4, so 24-byte values everywhere |
| GC-allocated object, 128-bit | 28–29 or more | **every result** | as above, plus the heap | how `buffer` works |
| Hybrid: inline when small, boxed when large | up to 29 | only large values | both of the above, plus a normal form | most complex |
| Library only (userdata or table with metatable) | any | every value | none in core, but slow | what exists today |

The GC row is still the one people reach for first, and the
[performance page](performance.md) has a proxy for it: the host-registered
userdata, which pays one allocation per result, is 17 times slower than the
inline decimal for the same addition and uses 3 times the memory.

## Where this leaves the decision

- 90 bits is the widest mantissa that stays a value type in the default build. It
  gives up one digit and a factor of 64 in range against .NET, and nothing else
  that a program can observe.
- Nothing visible to a Luau program depends on the width. Literals, operators,
  `create`, `tostring` and `round` look the same at any width. The one place the
  width shows is the C API (`lua_pushdecimal` takes a sign and two halves of the
  magnitude), which should be treated as unstable until this is settled.
- If a use case needs more than 28 digits, the next step is a different
  representation, not a wider inline one, and I would want to see that use case
  before building it.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
python3 demos/decimal/reference/wide-fuzz.py       # the 256-bit helper against Python integers
python3 demos/decimal/reference/decimal-fuzz.py    # every decimal operation against Python's decimal module
./luau demos/decimal/09-limits.luau                # the limits in this article
```

*Pinned to the `decimal-type` branch of my fork at the time of writing.*
