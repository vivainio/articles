# Performance at a glance

*2026-10-18*

Every number about speed and memory in this series is on this page, measured
the same way, so that it can be read in one go and challenged in one place.
The other articles link here instead of carrying their own tables.

The short version:

- **Adding two decimals takes about 5 ns: 3.3 times a double addition in the
  interpreter, and about 9 times with native code generation.** That is after two
  rounds of work (see "What changed since the first measurement"); the first
  measurement of the same addition was 17 ns.
- **Native code generation helps `number` a lot and helps decimals not at all.**
  Compiled code calls a shared helper for decimal arithmetic instead of using the
  interpreter's fast path, so the gap to `number` is wider there.
- **Against the alternatives an embedder has today, the core type is 9 to 15
  times faster and uses a third to an eighth of the memory,** because a core
  decimal lives in the value slot and the alternatives allocate a heap object for
  every result.
- **Division is the slowest common operation** at about 285 ns. Rounding to a
  given scale is about 80 ns, and adding two decimals with different scales about
  28 ns. Everything else is 15 ns or less.

## How it was measured

- Apple M3, macOS, release build of the `decimal-type` branch of my fork.
- Wall-clock time from `os.clock()`, median of 5 runs, after a short warm-up.
- "Interpreter" is `luau script.luau`. "Native code generation" is
  `luau --codegen script.luau`, which compiles every function to machine code
  before running it.
- The host-registered userdata baseline is a small C++ program built against
  the same VM (`demos/decimal/baseline/host.cpp`), run in both modes.
- All of it is one script, `demos/decimal/run-benchmarks.sh`, and the output of
  that script is what is pasted below. These are microbenchmarks of small
  loops: treat differences under about 20 % as noise, and note that the compiled
  time of a double addition moves between roughly 0.7 and 1.5 ns from run to
  run depending on the shape of the loop.

## One addition, four ways

A loop of additions of `0.01`: with doubles, with the core decimal, with a
decimal registered by the host as a userdata, and with a decimal written in
Luau as a table with a metatable.

| | interpreter | native code generation |
|---|---:|---:|
| `number` | 1.5 ns | 0.7 ns |
| core `decimal` | 4.9 ns | 6.4 ns |
| host-registered userdata | 72.0 ns | 70.6 ns |
| pure-Luau table | 75.0 ns | 56.4 ns |

Read it row by row.

**`number`.** A double addition is a single instruction that native code
generation turns into a register add. That is why it is 2 times faster with
codegen than without.

**Core `decimal`.** In the interpreter, an addition of two decimals with the same
scale checks the tags and scales, unpacks two 90-bit mantissas from their slots,
adds them as 128-bit integers, checks the range, and packs the result. Compiled
code does not have a decimal-specific path; it calls the same general arithmetic
function the interpreter falls back to, which tries the same fast check first.
That is why the compiled column is not faster (it is a function call on top of
the same work). Real code generation support would put the check and the add
inline.

**Host-registered userdata.** The same in both modes, for a different reason:
the cost is a call into a C function and an allocation, neither of which
compiled Luau code can make cheaper. It is also the closest proxy I have for
what a core decimal would cost if it were a garbage-collected object instead of
living in the value slot, since it does the same kind of arithmetic and pays for
one allocation per result.

**Pure-Luau table.** Compiled code helps (about 1.3 times) because the
metamethod bodies are ordinary Luau. It still allocates a table per result.

The ratios that matter:

| | interpreter | native code generation |
|---|---:|---:|
| core decimal vs `number` | 3.3 times slower | 9 times slower |
| host userdata vs core decimal | 15 times slower | 11 times slower |
| pure Luau vs core decimal | 15 times slower | 9 times slower |

The first row is the cost of choosing a decimal over a double, and it is wider
with codegen because only the double gets faster. The other two rows are the
case for the core type over the alternatives.

## Memory

A million values held in an array, measured as growth in
`collectgarbage("count")`, so each figure includes the 16-byte slot in the array:

| | bytes per value |
|---|---:|
| core `decimal` | 16 |
| host-registered userdata | 48 |
| pure-Luau table | 128 |

A core decimal is the slot and nothing else, even with a 90-bit mantissa. The
userdata adds a 32-byte heap object, and the table a 112-byte one with two hash
fields. Beyond the bytes, every allocation is work for the collector; I did not
measure collector pauses, which depend on the whole program.

## Core operations

The same measurement for the operations a program actually uses, from
`demos/decimal/benchmark.luau`. Time is per operation; the first row is a
double, for scale.

| operation | interpreter | native code generation |
|---|---:|---:|
| `number`: `x += 0.01` | 1.5 ns | 0.7 ns |
| `decimal`: `x += 0.01d` (same scale) | 4.9 ns | 6.3 ns |
| `decimal`: `x + y`, scales 1 and 2 | 28.4 ns | 26.9 ns |
| `decimal.add(x, y)` (library call) | 15.2 ns | 14.6 ns |
| `decimal`: `x < y` | 3.1 ns | 4.3 ns |
| `decimal`: `x == y` (scales 0 and 1) | 8.8 ns | 8.3 ns |
| `decimal`: `round(x * 1.01d, 2)` | 82.3 ns | 77.0 ns |
| `decimal`: `x += y / 3d` | 285.7 ns | 284.0 ns |
| `decimal`: sum an array, per element | 4.7 ns | 6.3 ns |

What the rows say:

- **Same-scale arithmetic and ordering are fast.** The common case in money code
  is operands that already share a scale (cents plus cents), and that is the fast
  path: 3 to 6 ns.
- **Different scales cost about six times more**, 27 to 28 ns, because the operands
  have to be aligned, added in 256 bits and rounded back.
- **The library call is cheaper than a different-scale operator** (15 ns) and
  three times a same-scale one, because it goes through the C function interface
  and checks its arguments. Prefer `a + b` to `decimal.add(a, b)`.
- **Equality across scales** (`1` against `1.0`) is about 9 ns because the
  operands have to be compared numerically; with equal scales it is a single
  128-bit compare in the interpreter, which I did not time separately.
- **Rounding is tens of nanoseconds.** The `round(..., 2)` row is a
  multiplication, a rounding and a comparison together, and comes to about 80 ns.
- **Division is the expensive one**, about 285 ns for a division plus an addition.
  The quotient is computed in 256 bits and the largest scale that fits has to be
  found, which takes a few 256-bit divisions.
- **Arrays are cheap.** Summing a million decimals costs under 7 ns per element,
  about the cost of the addition itself. The values are stored inline in the
  array, so there is nothing else to touch.

## What changed since the first measurement

This page has been through three versions, and the numbers moved enough that the
history is part of the result.

| version | same-scale addition | division plus addition |
|---|---:|---:|
| first prototype: 64-bit mantissa, every operation through the general function | 17 ns | 200 ns |
| **plus** interpreter fast paths and a faster division, still 64-bit | 2.7 ns | 135 ns |
| **now**: 90-bit mantissa, 256-bit arithmetic | 4.9 ns | 286 ns |

**The fast paths** (second row) were an interpreter fast path for `+`, `-` and `*`
on two decimals with the same scale, and for `<`, `<=`, `>` and `>=`: an integer
operation with a range check, taken only when the result is exact. The same check
runs first in the general arithmetic function, so compiled code and library calls
get it too, and division finds its scale from the digit counts instead of
searching down from the largest. When I wrote the first version of this page I
said the common case could be a few nanoseconds with a fast path, and that was an
estimate. It turned out to be about right.

**The widening** (third row) costs a factor of about 2 on the common operations and
a factor of 2 to 3 on the slow ones. The 256-bit arithmetic is the main cost
for different-scale addition, rounding and division. Packing and unpacking a mantissa
that is split across a 64-bit and a 26-bit field is the main cost for same-scale
addition. Neither has been optimised; both are obvious places to start. The case
for paying it is in [Why a 90-bit mantissa](why-90-bits.md): 27 digits instead of
19, and an 18-decimal token holds up to a billion instead of 9.2.

What did not change across any of these steps is a result, except where the wider
mantissa deliberately changes one (more digits). I checked that at every step: the
13 demos produce byte-identical output in both modes, the 75 cases against .NET
produce the expected differences, and a differential fuzzer compares millions of
random operations against an independent implementation built on Python's
`decimal` module.

It is a good illustration of why I wanted the benchmark in the first place: the
first version of this page said the design was 9 to 21 times slower than a double,
and that was true of the prototype and wrong about the design.

## What this does and does not say

It says a decimal that lives in the value slot is an order of magnitude cheaper
than one that allocates, and that a plain add on same-scale decimals is within a
small constant factor of a double add, in an interpreter, without any code
generation work.

It does not say the prototype is as fast as it can be in compiled code, where it
still calls out, or that every operation is cheap: division and rounding are tens
to hundreds of nanoseconds, and different-scale arithmetic is in between.

It also does not say anything about large programs. These are loops of millions
of operations on a quiet machine. A pricing rule that runs once per request
spends its time elsewhere, and so does most money code.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
./demos/decimal/run-benchmarks.sh
python3 demos/decimal/reference/decimal-fuzz.py
```

The benchmark script builds the C++ host baseline on the first run (it needs a
C++ compiler and the static libraries from the build above) and prints the three
tables above. The scripts it runs are in `demos/decimal/baseline/` and
`demos/decimal/benchmark.luau`.

*Numbers from one Apple M3 running the `decimal-type` branch of my fork on
2026-10-18. Your machine will differ; the ratios should hold up better than the
absolute times.*
