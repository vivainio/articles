# Performance at a glance

*2026-10-18*

Every number about speed and memory in this series is on this page, measured
the same way, so that it can be read in one go and challenged in one place.
The other articles link here instead of carrying their own tables.

The short version:

- **Adding two decimals takes about 17 ns, roughly 9 times a double in the
  interpreter and 21 times a double with native code generation.** It is
  slower than a double because it is a function call and 128-bit arithmetic,
  not a single instruction.
- **Native code generation helps `number` a lot and does not help decimals at
  all.** That is a limitation of the prototype (decimals have no code
  generation support), and it widens the gap to `number`.
- **Against the alternatives an embedder has today, the core type is 3.5 to 4.5
  times faster and uses a third to an eighth of the memory,** because a core
  decimal lives in the value slot and the alternatives allocate a heap object
  for every result.
- **Division is the expensive operation** at about 200 ns. Everything else is
  between 5 and 50 ns.

## How it was measured

- Apple M3, macOS, release build of the `decimal-type` branch of my fork.
- Wall-clock time from `os.clock()`, median of 5 runs, after a short warm-up.
- "Interpreter" is `luau script.luau`. "Native code generation" is
  `luau --codegen script.luau`, which compiles every function to machine code
  before running it.
- The host-registered userdata baseline is a small C++ program built against
  the same VM (`demos/decimal/baseline/host.cpp`), run in both modes.
- All of it is one script, `demos/decimal/run-benchmarks.sh`, and the output of
  that script is what is pasted below. Microbenchmarks of small loops: treat
  differences under about 20 % as noise, and the shape of a loop matters (see
  the note after the second table).

## One addition, four ways

A loop of additions of `0.01`: with doubles, with the core decimal, with a
decimal registered by the host as a userdata, and with a decimal written in
Luau as a table with a metatable.

| | interpreter | native code generation |
|---|---:|---:|
| `number` | 2.0 ns | 0.8 ns |
| core `decimal` | 17.0 ns | 16.2 ns |
| host-registered userdata | 69.1 ns | 69.9 ns |
| pure-Luau table | 75.1 ns | 56.9 ns |

Read it row by row.

**`number`.** A double addition is a single instruction that native code
generation turns into a register add. That is why it is 2.6 times faster with
codegen than without.

**Core `decimal`.** The same time in both modes, because native code
generation does not know about decimals: the arithmetic goes through the same
slow path as vectors and metamethods, in the interpreter or out of compiled
code. This is the biggest piece of room in the prototype. A decimal add is an
`int64` add with an overflow check when both operands have the same scale, and
the common case could be a few nanoseconds in the interpreter and less than
that compiled. I have not built it, so that is an estimate of the design and
not a result.

**Host-registered userdata.** Also the same in both modes, for a different
reason: the cost is a call into a C function and an allocation, neither of
which compiled Luau code can make cheaper. It is also the closest proxy I have
for what a core decimal would cost if it were a garbage-collected object
instead of living in the value slot, since it does the same arithmetic and
pays for one allocation per result.

**Pure-Luau table.** Compiled code helps (about 1.3 times) because the
metamethod bodies are ordinary Luau. It still allocates a table per result.

The ratios that matter:

| | interpreter | native code generation |
|---|---:|---:|
| core decimal vs `number` | 8.7 times slower | 21 times slower |
| host userdata vs core decimal | 4.1 times slower | 4.3 times slower |
| pure Luau vs core decimal | 4.4 times slower | 3.5 times slower |

The first row is the cost of choosing a decimal over a double, and it is worse
with codegen because only the double gets faster. The other two rows are the
case for the core type over the alternatives, and they are stable across modes.

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
| `number`: `x += 0.01` | 1.5 ns | 1.6 ns |
| `decimal`: `x += 0.01d` | 21.2 ns | 20.6 ns |
| `decimal.add(x, y)` (library call) | 29.5 ns | 25.4 ns |
| `decimal`: `x < y` | 6.1 ns | 5.3 ns |
| `decimal`: `x == y` (scales 0 and 1) | 7.1 ns | 6.7 ns |
| `decimal`: `round(x * 1.01d, 2)` | 49.3 ns | 42.3 ns |
| `decimal`: `x += y / 3d` | 203.7 ns | 202.4 ns |
| `decimal`: sum an array, per element | 18.1 ns | 17.2 ns |

A note on reading this table against the previous one: these loops run inside
a function that is passed the iteration count, which gives native code
generation less to work with than the top-level loops of the first table, so
the double is 1.5 ns here and 0.8 ns there, and the decimal addition is 21 ns
here and 17 ns there. Compare rows within a table, not across them. Within this
table a decimal addition is 13 to 14 times a double addition in both modes.

What the rows say:

- **Comparison is cheap.** `x < y` is 5 to 6 ns. `x == y` is about 7 ns here
  because the two operands have different scales (0 and 1), which sends the
  comparison down the numeric path; when the scales are equal the equality is
  a single integer compare by construction, but I did not time that case
  separately.
- **Rounding is tens of nanoseconds.** The `round(..., 2)` row is a
  multiplication, a rounding and a comparison together, and comes to under
  50 ns.
- **Division is the expensive one.** About 200 ns for a division plus an
  addition. The quotient is a 128-bit divide in a loop that looks for the
  largest scale that fits in the mantissa, and that loop is where the time goes.
  It is the first thing I would optimise: pick the scale from the digit counts
  and divide once.
- **Arrays are cheap.** Summing a million decimals costs 18 ns per element,
  about the cost of the addition itself. The values are stored inline in the
  array, so there is nothing else to touch.

## What this does and does not say

It says a decimal that lives in the value slot is several times cheaper than
one that allocates, and that the prototype is slower than a double by an
amount (9 to 21 times for addition) that is a constant, not a growth rate.

It does not say the prototype is as fast as it can be. It has no interpreter
fast path, no code generation support, and a division that does more work than
it needs to. Those are all things I know how to improve and have not done,
because the point of the prototype was to find out whether the design holds
together, not to win a benchmark. If you read the numbers as "this is the
slowest it will ever be, with the cheapest possible representation", you are
close to right.

It also does not say anything about large programs. These are loops of
millions of operations on a quiet machine. A pricing rule that runs once per
request spends its time elsewhere, and so does most money code.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release
./demos/decimal/run-benchmarks.sh
```

The script builds the C++ host baseline on the first run (it needs a C++
compiler and the static libraries from the build above) and prints the three
tables above. The scripts it runs are in `demos/decimal/baseline/` and
`demos/decimal/benchmark.luau`.

*Numbers from one Apple M3 running the `decimal-type` branch of my fork on
2026-10-18. Your machine will differ; the ratios should hold up better than the
absolute times.*
