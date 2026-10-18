# Performance at a glance

*2026-10-18*

Every number about speed and memory in this series is on this page, measured
the same way, so that it can be read in one go and challenged in one place.
The other articles link here instead of carrying their own tables.

The short version:

- **Adding two decimals takes about 4 ns: 2.8 times a double addition in the
  interpreter, and about 6 times with native code generation.** That is after
  three rounds of work (see "What changed since the first measurement"); the
  first measurement of the same addition was 17 ns.
- **Native code generation helps `number` a lot and helps decimals not at all.**
  Compiled code calls a shared helper for decimal arithmetic instead of using the
  interpreter's fast path, so the gap to `number` is wider there.
- **Against the alternatives an embedder has today, the core type is 14 to 18
  times faster and uses a third to an eighth of the memory,** because a core
  decimal lives in the value slot and the alternatives allocate a heap object for
  every result. Against the real host library, `mlua-decimal`, it is about 44
  times faster (see [the comparison](core-vs-host-library.md)).
- **Division is the slowest common operation** at about 125 ns. Rounding to a
  given scale is about 50 ns, and adding two decimals with different scales about
  15 ns. Everything else is 15 ns or less.

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
| core `decimal` | 4.2 ns | 4.2 ns |
| host-registered userdata | 70.2 ns | 69.9 ns |
| pure-Luau table | 76.5 ns | 56.9 ns |

Read it row by row.

**`number`.** A double addition is a single instruction that native code
generation turns into a register add. That is why it is 2 times faster with
codegen than without.

**Core `decimal`.** In the interpreter, an addition of two decimals with the same
scale checks the tags and scales, adds the two 90-bit magnitudes as 128-bit
integers (or subtracts the smaller from the larger when the signs differ), checks
the range, and stores the result, working directly on the packed form of the
slot. Compiled code does not have a decimal-specific path; it calls the same
general arithmetic function the interpreter falls back to, which tries the same
fast check first. That is why the compiled column is no faster. Real code
generation support would put the check and the add inline.

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
| core decimal vs `number` | 2.8 times slower | 6 times slower |
| host userdata vs core decimal | 17 times slower | 17 times slower |
| pure Luau vs core decimal | 18 times slower | 14 times slower |

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
| `decimal`: `x += 0.01d` (same scale) | 4.2 ns | 4.1 ns |
| `decimal`: `x + y`, scales 1 and 2 | 15.1 ns | 13.5 ns |
| `decimal.add(x, y)` (library call) | 15.1 ns | 14.7 ns |
| `decimal`: `x < y` | 3.5 ns | 3.2 ns |
| `decimal`: `x == y` (scales 0 and 1) | 9.1 ns | 8.4 ns |
| `decimal`: `round(x * 1.01d, 2)` | 50.7 ns | 44.8 ns |
| `decimal`: `x += y / 3d` | 122.9 ns | 121.7 ns |
| `decimal`: sum an array, per element | 4.2 ns | 4.2 ns |

What the rows say:

- **Same-scale arithmetic and ordering are fast.** The common case in money code
  is operands that already share a scale (cents plus cents), and that is the fast
  path: 3 to 5 ns.
- **Different scales cost about three to four times more**, 13 to 15 ns, because
  the operands have to be aligned, added in 256 bits and rounded back.
- **The library call costs the same as a different-scale operator** (15 ns) and
  three times a same-scale one, because it goes through the C function interface
  and checks its arguments. Prefer `a + b` to `decimal.add(a, b)`.
- **Equality across scales** (`1` against `1.0`) is about 9 ns because the
  operands have to be compared numerically; with equal scales it is a single
  128-bit compare in the interpreter, which I did not time separately.
- **Rounding is tens of nanoseconds.** The `round(..., 2)` row is a
  multiplication, a rounding and a comparison together, and comes to about 50 ns.
- **Division is the expensive one**, about 125 ns for a division plus an addition.
  The quotient is computed in 256 bits and the largest scale that fits has to be
  found, which takes one or two 256-bit divisions plus the removal of trailing
  zeros.
- **Arrays are cheap.** Summing a million decimals costs about 4 ns per element,
  about the cost of the addition itself. The values are stored inline in the
  array, so there is nothing else to touch.

## What changed since the first measurement

This page has been through four versions, and the numbers moved enough that the
history is part of the result.

| version | same-scale addition | different scales | division plus addition |
|---|---:|---:|---:|
| first prototype: 64-bit mantissa, every operation through the general function | 17 ns | 17 ns | 200 ns |
| **plus** interpreter fast paths and a faster division, still 64-bit | 2.7 ns | 9 ns | 135 ns |
| 90-bit mantissa, 256-bit arithmetic | 4.9 ns | 28 ns | 286 ns |
| **now**: the same, optimised | 4.2 ns | 15 ns | 123 ns |

**The fast paths** (second row) were an interpreter fast path for `+`, `-` and `*`
on two decimals with the same scale, and for `<`, `<=`, `>` and `>=`: an integer
operation with a range check, taken only when the result is exact. The same check
runs first in the general arithmetic function, so compiled code and library calls
get it too, and division finds its scale from the digit counts instead of
searching down from the largest. When I wrote the first version of this page I
said the common case could be a few nanoseconds with a fast path, and that was an
estimate. It turned out to be about right.

**The widening** (third row) cost a factor of about 2 on the common operations and
a factor of 2 to 3 on the slow ones. The case for paying it is in [Why a 90-bit
mantissa](why-90-bits.md): 27 digits instead of 19, and an 18-decimal token holds
up to a billion instead of 9.2.

**The optimisation** (last row) won most of it back. The interpreter now works on the
packed sign and magnitude directly instead of converting to a signed 128-bit
mantissa and back, the rounding step returns immediately for a value that is already
in range, and division does fewer 256-bit divisions (it aims for the right scale
from the digit counts, skips the attempt at a finer scale when the quotient is too
big to allow one, and strips trailing zeros with short divisions in chunks). A
same-scale addition is 4.2 ns (2.7 before widening), different scales 15 ns (9), and
division is now faster than it was at 64 bits: 123 ns against 135.

What did not change across any of these steps is a result, except where the wider
mantissa deliberately changes one (more digits). I checked that at every step: the
13 demos produce byte-identical output in both modes, the 75 cases against .NET
produce the expected differences, and a differential fuzzer compares millions of
random operations against an independent implementation built on Python's
`decimal` module (3.8 million cases after the optimisation, with a fresh seed, and
no mismatches).

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
