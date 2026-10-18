# Why a 64-bit mantissa

*2026-10-18*

.NET's `decimal` has 28 or 29 significant digits. The Luau prototype has 18 or
19. That is the largest deliberate difference between them, so it deserves a
proper account of what decided it and what it costs. This article is that
account, including one thing I got wrong the first time I wrote it down.

## The short version

A decimal in this prototype is a signed 64-bit integer and a scale, stored
inline in the VM's 16-byte value slot, with no heap allocation. I chose it
because it keeps the arithmetic simple enough to be correct and the type
cheap enough to use in loops. I did **not** choose it because it is the only
thing that fits: a mantissa of up to about 90 bits would also fit inline. What
stops me from going there is the arithmetic, not the storage.

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
`LUA_VECTOR_SIZE` configuration is 3 by default, which gives `extra` one
`int`. So the usable payload of a value type is **12 bytes**, and the type tag
is separate.

The existing value types sit inside that budget:

| Type | Payload |
|---|---|
| `number` | 8-byte double |
| `integer` | 8-byte `int64` |
| `vector` (3 floats) | 12 bytes, all of it |
| `boolean`, light userdata | 1 or 8 bytes |
| everything else (`string`, `table`, `buffer`, …) | an 8-byte pointer to a garbage-collected object |

Anything that does not fit in 12 bytes has to be a pointer to a heap object.
That is what `buffer` is, and what vectors become when Luau is built with
double-precision components.

## What .NET's decimal needs

`System.Decimal` is a 96-bit unsigned mantissa, a sign, and a scale from 0 to
28. The scale needs 5 bits and the sign 1, so the minimum is 96 + 1 + 5 = 102
bits. The payload is 96 bits. The 96-bit mantissa alone uses all 12 bytes and
leaves nothing for the sign or the scale, so **an exact copy of .NET's layout
does not fit** in the default build.

That is a true statement, and it is the one my draft pull request leaned on.
The conclusion I drew from it was wrong.

## What I got wrong

The first version of my argument said that a 64-bit mantissa "is the only
layout that stays a value type". It is not. If the mantissa is allowed to be
slightly smaller than .NET's, the whole value fits in 96 bits:

```text
 1 bit sign + 5 bits scale + 90 bits mantissa = 96 bits = 12 bytes
 low 64 bits of the mantissa  -> Value
 high 26 bits + sign + scale  -> extra[0]
```

A 90-bit mantissa goes up to 1.24 × 10²⁷, so **27 digits always fit**. That is
one or two digits short of .NET and nine more than the 64-bit design. The
storage question has an inline answer in between the two.

(With `LUA_VECTOR_SIZE` set to 4, `extra` has two `int`s and the whole of .NET's
layout would fit, but then every value in the VM is 24 bytes; I checked that
too. That is not a configuration I can assume.)

## So why not 90 bits?

Because of what the arithmetic needs, not because of where the bits live.

Multiplying two 63-bit mantissas gives a result of up to 126 bits. That fits in
the compiler's `__int128` exactly, so every operation in the prototype is: widen,
compute exactly, round to fit, narrow. Addition aligns scales with a multiply by
a power of ten, division is one `__int128` divide with a remainder. The whole
library, with every function and its argument checking, is about 760 lines
of C++, and the interesting part is a single function that rounds a 128-bit
value down to 63 bits.

Two 90-bit mantissas multiply to 180 bits, which does not fit in 128. A 90-bit
decimal needs:

- a 256-bit intermediate for multiplication, and for the scaling in addition,
- a 256-by-128-bit division for `/`, with correct remainder and rounding,
- all of it written by hand, because there is no 256-bit integer type, and
  `__int128` itself is a GCC and Clang extension that MSVC lacks (a portability
  problem the 64-bit version already has, which would become much bigger),
- the packing and unpacking of the split mantissa on every read and write.

None of that is hard in isolation, and .NET's own implementation needs the
same kind of wider intermediate for its 96-bit mantissas. It is simply a lot
more code to get right and to maintain than a type that leans on one compiler
extension.

There are also three smaller reasons:

1. **Equality, hashing and comparison stay trivial.** A mantissa in one machine
   word means the common comparisons are one or two integer compares, and the
   VM already does exactly that for `integer`.
2. **It mirrors `integer`.** The VM, the bytecode, the compiler, the analyzer and
   native code generation all already know how to carry a 64-bit payload. Each
   stage of this prototype (VM, operators, literals, types) was a small change
   because there was a template.
3. **A narrower mantissa makes the failure mode simpler to explain.** Everything
   that does not fit is rounded at a fixed digit count or raises one error.

## The alternatives, and their costs

| Option | Digits | Allocates | Arithmetic you must write | Verdict |
|---|---|---|---|---|
| **Inline 64-bit mantissa** (this prototype) | 18–19 | no | `__int128` is enough | chosen |
| Inline 90-bit mantissa | 27 | no | 256-bit multiply, 256÷128 division | the realistic upgrade |
| Exact .NET layout (96 + sign + scale) | 28–29 | no, but only if `TValue` grows | 192/256-bit | needs `LUA_VECTOR_SIZE` 4, so 24-byte values everywhere |
| GC-allocated object, 128-bit | 28–29 or more | **every result** | as above, plus the heap | how `buffer` works |
| Hybrid: inline when small, boxed when large | up to 29 | only large values | both of the above, plus a normal form so that equal values compare equal | most complex of all |
| Library only (userdata or table with metatable) | any | every value | none in core, but slow | what exists today |

The GC option deserves a note on what it costs a VM like this one, because it
is the one people reach for first. Every arithmetic result would be an
allocation. The type needs marking, sweeping, freeing and memory-category
accounting in the collector. Equality and hashing have to compare contents
instead of one word. And it closes the door on the register-level fast paths
that native code generation gives `number` and `integer`. I have not
implemented it, so I have not measured it; the claim here is about design, and
each item on that list is something `buffer` also needed (the `buffer` tag is
referenced from 18 source files, about as many as `integer` and `vector`).

## What the 64-bit choice costs today

Digits and range are the obvious losses. Here they are in money terms, using
the exact limits the demo suite prints:

| Decimal places | Largest amount, 64-bit | Largest amount, 90-bit |
|---|---|---|
| 2 (cents) | 92,233,720,368,547,758.07 | 12,379,400,392,853,802,748,991,242.23 |
| 4 | 922,337,203,685,477.5807 | 123,794,003,928,538,027,489,912.4223 |
| 8 (satoshi) | 92,233,720,368.54775807 | 12,379,400,392,853,802,748.99124223 |
| 18 (wei) | **9.223372036854775807** | 1,237,940,039.285380274899124223 |

For ordinary money the 64-bit limits are not a practical constraint: 92
quadrillion with two decimals is roughly a thousand times the world's annual
economic output. The last row is where it bites. A token with 18 decimals, the
common convention on Ethereum, cannot hold more than about 9.2 tokens in this
type. A 90-bit mantissa would take amounts up to about 1.2 billion, which
covers most supplies. If that use case matters, 64 bits is the wrong number.

There is also a subtler cost. When a result needs more digits than fit, it is
rounded, which is deterministic but silent. The .NET comparison article shows
the sharpest example: `(1/3)*3` comes back as exactly `1` here and as
`0.9999999999999999999999999999` in .NET, because the 19-digit product is
rounded to 18 digits. Fewer digits can hide a property of the arithmetic
instead of only showing less of it.

## What it costs to use

I measured the interpreter on an Apple M3 (single machine, two runs, the
numbers agree to a few percent). Every decimal operation is currently a call
into the same slow path that handles vectors and metamethods, not a dedicated
opcode, and native code generation does not specialise it yet.

| Operation, 10 million iterations | Time | Per operation |
|---|---|---|
| `number`: `x += 0.01` | 15 ms | about 1.5 ns |
| `decimal`: `x += 0.01d` | 204 ms | about 20 ns |
| `decimal`: `x < y` | 59 ms | about 6 ns |
| `decimal`: `x == y` | 15 ms | about 1.5 ns |
| `decimal.add(x, y)` as a library call | 278 ms | about 28 ns |
| `decimal`: `round(x * 1.01d, 2)` (1 million iterations) | 46 ms | about 46 ns |
| `decimal`: `x += y / 3d` (1 million iterations) | 204 ms | about 200 ns |

So adding decimals is about 13 times slower than adding doubles, with no
allocation and no garbage. Division is the expensive one because it is a
128-bit divide inside a loop that looks for the largest scale that fits. None of
this is a reason to avoid decimals for money, where correctness dominates and
operations are rare; it would matter for a hot numeric loop, which is not what
this type is for. The numbers are a floor for what the inline design can cost,
and a ceiling for what it will cost once the common cases get opcodes.

The array case is worth noting: a table of one million decimals summed in a
loop takes 19 ms, because the values are stored inline in the table and the
sum never allocates.

## Where this leaves the decision

- The 64-bit mantissa is a defensible first step: small, correct, and the
  semantics transfer from .NET unchanged. It is a poor fit for 18-decimal
  token amounts.
- The honest upgrade path is a 90-bit inline mantissa, not a heap object. It
  keeps every property the 64-bit version has (value type, no allocation, fits
  the slot) and costs a multiword arithmetic core.
- Nothing visible to a Luau program depends on the width. Literals, operators,
  `create`, `tostring` and `round` look the same at any width. The one place the
  width shows is the C API, `lua_pushdecimal(L, int64_t mantissa, int exponent)`,
  which should be treated as unstable.

The question I would put to the Luau team is not "is 64 bits enough", it is
"if this type is wanted, is the 90-bit core worth building up front, or do we
start small and widen later". The articles make the case for either; the demo
suite is the evidence.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
./luau demos/decimal/09-limits.luau      # the limits in this article
```

The layout figures come from compiling a few lines against `lobject.h` (24
bytes per value in the `LUA_VECTOR_SIZE` 4 build, 16 in the default one); the
timings come from `demos/decimal/benchmark.luau`, which you can run with and
without `--codegen`.

*Pinned to the `decimal-type` branch of my fork at the time of writing.*
