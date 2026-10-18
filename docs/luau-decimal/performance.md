# Performance at a glance

*2026-10-18*

Every number about speed and memory in this series is on this page, measured
the same way, so that it can be read in one go and challenged in one place.
The other articles link here instead of carrying their own tables.

The short version:

- **Adding two decimals takes about 2.7 ns: 1.6 times a double addition in the
  interpreter, and about 4 times with native code generation.** That is after
  I added an interpreter fast path (see "What changed since the first
  measurement"); before it, the same addition took 17 ns.
- **Native code generation helps `number` a lot and helps decimals only a
  little.** Compiled code calls a shared helper for decimal arithmetic instead
  of using the interpreter's fast path, so the gap to `number` is wider there.
- **Against the alternatives an embedder has today, the core type is 20 to 30
  times faster and uses a third to an eighth of the memory,** because a core
  decimal lives in the value slot and the alternatives allocate a heap object
  for every result.
- **Division is the slowest common operation** at about 130 ns. Rounding to a
  given scale is about 40 ns. Everything else is under 15 ns.

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
| `number` | 1.7 ns | 0.7 ns |
| core `decimal` | 2.6 ns | 2.9 ns |
| host-registered userdata | 70.1 ns | 70.6 ns |
| pure-Luau table | 79.3 ns | 56.8 ns |

Read it row by row.

**`number`.** A double addition is a single instruction that native code
generation turns into a register add. That is why it is 2.4 times faster with
codegen than without.

**Core `decimal`.** In the interpreter, an addition of two decimals with the
same scale is a check of the tags and scales, an `int64` add with an overflow
check, and a store. Compiled code does not have a decimal-specific path; it
calls the same general arithmetic function the interpreter falls back to, which
tries the same fast check first. That is why the compiled column is not faster
(it is a function call, and 2.9 ns is what a call and the check cost). Real
code generation support would put the check and the add inline.

**Host-registered userdata.** The same in both modes, for a different reason:
the cost is a call into a C function and an allocation, neither of which
compiled Luau code can make cheaper. It is also the closest proxy I have for
what a core decimal would cost if it were a garbage-collected object instead of
living in the value slot, since it does the same arithmetic and pays for one
allocation per result.

**Pure-Luau table.** Compiled code helps (about 1.4 times) because the
metamethod bodies are ordinary Luau. It still allocates a table per result.

The ratios that matter:

| | interpreter | native code generation |
|---|---:|---:|
| core decimal vs `number` | 1.6 times slower | 4 times slower |
| host userdata vs core decimal | 27 times slower | 25 times slower |
| pure Luau vs core decimal | 30 times slower | 20 times slower |

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

A core decimal is the slot and nothing else. The userdata adds a 32-byte
heap object, and the table a 112-byte one with two hash fields. Beyond the
bytes, every allocation is work for the collector; I did not measure collector
pauses, which depend on the whole program.

## Core operations

The same measurement for the operations a program actually uses, from
`demos/decimal/benchmark.luau`. Time is per operation; the first row is a
double, for scale.

| operation | interpreter | native code generation |
|---|---:|---:|
| `number`: `x += 0.01` | 1.5 ns | 1.2 ns |
| `decimal`: `x += 0.01d` (same scale) | 2.7 ns | 2.9 ns |
| `decimal`: `x + y`, scales 1 and 2 | 9.0 ns | 7.8 ns |
| `decimal.add(x, y)` (library call) | 13.8 ns | 9.0 ns |
| `decimal`: `x < y` | 3.1 ns | 2.4 ns |
| `decimal`: `x == y` (scales 0 and 1) | 7.6 ns | 6.7 ns |
| `decimal`: `round(x * 1.01d, 2)` | 48.0 ns | 41.0 ns |
| `decimal`: `x += y / 3d` | 135.6 ns | 131.8 ns |
| `decimal`: sum an array, per element | 2.7 ns | 3.2 ns |

What the rows say:

- **Same-scale arithmetic and ordering are fast.** The common case in money
  code is operands that already share a scale (cents plus cents), and that is
  the fast path: about 3 ns.
- **Different scales cost about three times more**, 8 to 9 ns, because the
  operands have to be aligned, added in 128 bits and rounded back. Still small.
- **The library call is more expensive than the operator** (9 to 14 ns against
  3) because it goes through the C function interface and checks its arguments.
  Prefer `a + b` to `decimal.add(a, b)`.
- **Equality across scales** (`1` against `1.0`) is about 7 ns because the
  operands have to be compared numerically; with equal scales it is a single
  integer compare in the interpreter, which I did not time separately.
- **Rounding is tens of nanoseconds.** The `round(..., 2)` row is a
  multiplication, a rounding and a comparison together, and comes to about
  40 ns.
- **Division is the expensive one**, about 130 ns for a division plus an
  addition. The quotient is computed in 128 bits and the largest scale that
  fits has to be found, which takes a few divisions.
- **Arrays are cheap.** Summing a million decimals costs under 3 ns per
  element, about the cost of the addition itself. The values are stored inline
  in the array, so there is nothing else to touch.

## What changed since the first measurement

This page was first written with different numbers: a decimal addition took
17 ns (about 9 times a double in the interpreter, about 21 times with
codegen), a comparison 6 ns, division 200 ns. Those were real measurements of
a prototype that sent every decimal operation through the general arithmetic
function. When I first wrote this page I said the common case could be a few
nanoseconds with a fast path, and that was an estimate. Looking at why the
native code generation column did not move led to the work on fast paths, and
the estimate turned out to be about right.

What I changed:

- **An interpreter fast path** for `+`, `-` and `*` on two decimals with the
  same scale, and for `<`, `<=`, `>` and `>=`: an `int64` operation with an
  overflow check, taken only when the result is exact. Everything else (different
  scales, a result that needs rounding, overflow) takes the general path, as
  before.
- **The same check at the start of the general function**, so that compiled code
  and library calls get it too.
- **Division finds the scale from the digit counts** instead of starting at the
  largest and stepping down, which took the division row from about 200 ns to
  about 130.

What did not change is any result. The fast paths are taken only when the
answer is the exact answer, and I checked that three ways: the 13 demos still
produce byte-identical output in both modes, the 72 cases against .NET still
produce the same 13 differences, and a differential test compares 20,000 random
divisions against an independent implementation of the rule
(`demos/decimal/reference/division-check.py`) with no mismatches.

It is a good illustration of why I wanted the benchmark in the first place:
the first version of this page said the design was 9 to 21 times slower than a
double, and that was true of the prototype and wrong about the design.

## What this does and does not say

It says a decimal that lives in the value slot is more than an order of
magnitude cheaper than one that allocates, and that a plain add on same-scale
decimals can be within a small constant factor of a double add, in an
interpreter, without any code generation work.

It does not say the prototype is as fast as it can be in compiled code, where
it still calls out, or that every operation is cheap: division and rounding are
tens to hundreds of nanoseconds.

It also does not say anything about large programs. These are loops of millions
of operations on a quiet machine. A pricing rule that runs once per request
spends its time elsewhere, and so does most money code.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
./demos/decimal/run-benchmarks.sh
python3 demos/decimal/reference/division-check.py
```

The benchmark script builds the C++ host baseline on the first run (it needs a
C++ compiler and the static libraries from the build above) and prints the three
tables above. The scripts it runs are in `demos/decimal/baseline/` and
`demos/decimal/benchmark.luau`.

*Numbers from one Apple M3 running the `decimal-type` branch of my fork on
2026-10-18. Your machine will differ; the ratios should hold up better than the
absolute times.*
