# Why money in Luau needs a decimal

*2026-10-18*

Luau is a scripting language that other programs embed. People reach for it
when an application needs behaviour that can change without a redeploy, can be
sandboxed, and is cheap to run: rules, formulas, configuration with logic in
it. I would like the option to use it for some scenarios that involve money:
pricing rules, fees, invoice and tax calculations, settlement logic, the kind
of code where the answer has to be the number a person would get with a
pencil.

For those scenarios a floating-point `number` cannot be the type of an amount.
That is not a controversial statement. This article is about the other half of
the question: **if Luau has no decimal type, what does an embedder do, and how
much does the answer cost compared with having one in the core?** I built the
alternatives and measured them, so the comparison is not a matter of taste.

## Why the double is out

Luau's `number` is an IEEE-754 double. The demo suite has a whole file of the
standard consequences ([`03-floating-point`](https://github.com/vivainio/luau/blob/decimal-type/demos/decimal/03-floating-point.luau));
the short list:

```text
0.1 + 0.2                       0.30000000000000004     and  == 0.3  is false
adding 0.1 ten times            0.99999999999999989     and  == 1     is false
adding one cent 1000 times      9.9999999999998312      and  == 10    is false
1.15 * 100                      114.99999999999999
string.format('%.2f', 2.675)    2.67      but   floor(2.675 * 100 + 0.5) / 100  is  2.68
```

Every one of these is "correct" for a double and wrong for an invoice. The last
line is the one that matters most in practice: the two common ways to round to
cents give different answers for the same input, so a rule written by one
person and checked by another can disagree with itself.

The usual advice is to store integer cents. That helps with addition and breaks
down elsewhere. A 24 % tax on 5,997 cents is 1,439.28 cents, so you need a
rounding rule anyway, and now you also need to remember which variables are
cents. A unit price of 0.333 does not fit in whole cents at all. A script that
has to work in a currency with three decimals, or with a fraction of a cent in
an intermediate step, has to carry a scale around by hand, which is the thing a
decimal type exists to do.

## What an embedder can do today

Luau lets a host define new types in two ways, and both work. I built both so
that I would be comparing against something real.

**1. Write it in Luau.** A table with a metatable, `__add`, `__eq`, `__lt` and
`__tostring`. About 80 lines
([`pure-luau.luau`](https://github.com/vivainio/luau/blob/decimal-type/demos/decimal/baseline/pure-luau.luau)),
type-checks cleanly under `--!strict`, needs no host support at all.

**2. Register a userdata type from the host.** A C++ `struct` with a metatable
of C functions. About 215 lines
([`host.cpp`](https://github.com/vivainio/luau/blob/decimal-type/demos/decimal/baseline/host.cpp)),
including a minimal `collectgarbage` because that is the host's job. It does
the arithmetic in 128 bits, like the core version does. I deliberately wrote it
to a small spec (add, subtract, multiply, compare, print, parse); it is a
baseline for measuring, not a library.

Then the same loop in each, additions of `0.01`, with plain `number` for scale:

| | per addition, interpreter | with native code generation | memory per stored value | what `typeof` says |
|---|---:|---:|---:|---|
| `number` (for scale) | 1.5 ns | 0.7 ns | 16 bytes | `number` |
| Core `decimal` | 4.2 ns | 4.2 ns | 16 bytes | `decimal` |
| Embedded userdata | 70 ns | 70 ns | 48 bytes | `userdata` |
| Pure Luau | 76 ns | 57 ns | 128 bytes | `table` |

(Apple M3, median of five runs. Memory is measured as growth in
`collectgarbage("count")` for a million values held in an array, so it includes
the 16-byte slot. Everything about these numbers, including what native code
generation does and does not change, is on the
[performance page](performance.md).)

Both approximations pay for an allocation per result: the userdata costs 32
bytes of object on top of the slot, the table 112. The core type pays nothing,
because the value lives in the slot. That is the difference between 4 ns and
about 70 (14 to 18 times), and between 16 bytes and 48 or 128. For a pricing rule that runs once
per request, none of this matters. For a script that runs over a million order
lines it is the difference between a cheap rule and a visible cost.

## What the approximations get wrong

The speed gap is the least interesting finding. These are the others, shown in
[`limits-pure.luau`](https://github.com/vivainio/luau/blob/decimal-type/demos/decimal/baseline/limits-pure.luau):

```text
parse('9007199254740993')  (2^53 + 1)          9007199254740992        <- silently wrong
core: 9007199254740993d                        9007199254740993
parse('0.1234567890123456789')                 0.1234567890123456768   <- silently wrong
core: 0.1234567890123456789d                   0.1234567890123456789
type(d)                                        table
d.m (the representation is public)             15
after d.m = 999                                99.9                    <- anyone can edit it
t[parse('1.5')] looked up with an equal value  nil                     <- tables key by identity
D.parse('1') + 1                               attempt to index number with 's'
```

**A pure-Luau decimal is a decimal built from doubles.** Its mantissa is a
`number`, exact only up to 2^53, about 15 digits. Beyond that it is wrong
without saying so, in a library whose entire purpose is not being wrong. The
fix is to build the mantissa out of the `integer` type's library functions
(`integer.add`, `integer.mul`). That is possible; I expect it to be slower
still and I did not build it.

**A table is not a value.** It has fields, they can be assigned, two equal
decimals are two different tables, and a table used as a key compares by
identity. `type` and `typeof` both say `table`, so code that wants to know
whether it was handed an amount has to look for the metatable. Mistakes surface
as `attempt to index number with 's'`, which names a field that nobody typed.

**The host-embedded version fixes the representation problems** (it is a real
integer mantissa, `typeof` is `userdata`, nothing is editable), and that is
the version I would build if I owned one application. But it brings its own:

- **There is no literal.** Every constant is a call, `Decimal.parse("19.99")`,
  instead of `19.99d`. Scripts that are mostly constants (price lists, rules)
  read like parsing code.
- **The type checker sees `userdata`** unless the host also declares an extern
  type with every operator, and ships that definition to every tool that
  checks the script: the analyzer, the editor, the CI. Each host does this
  differently.
- **Every host has its own decimal,** with its own rounding mode, its own
  scale rules and its own digits. A script that adds up a bill on one platform
  is not guaranteed to give the same answer on another, which is the exact
  property you wanted from a decimal in the first place.
- **No constant folding, no bytecode support,** and nothing the compiler or
  native code generation can specialise, because to them it is an opaque
  userdata.
- **Mixing with the language's own types is hand-written.** A host can make its
  decimal accept an `integer` operand, and its extern-type declaration has to
  say so, but each host does that work again and the type checker learns it
  only from the declaration.

## The case for the core, stated narrowly

An embedder can get a working decimal in an afternoon. I did, twice. So the
case for putting it in the core is not that it is impossible otherwise. It is
that these are things only the core can provide:

1. **One definition.** The same script gives the same answer in every
   application that embeds Luau, and "decimal" means one documented thing,
   checked against a reference ([.NET](checked-against-dotnet.md)).
2. **A literal and a type.** `19.99d` in source, `decimal` in annotations,
   `type(x) == "decimal"` that refines, and operators that the type checker
   understands without a per-host declaration file.
3. **A value, not an object.** No allocation per result: a fourteenth to an
   eighteenth of the time and a third to an eighth of the memory in the
   measurements above.
4. **Natural interplay with the types around it:** mixing with `integer`,
   sorting, comparison, constant folding, bytecode constants.

The natural objection is that the core should stay small. I agree with the
instinct, and it is why the implementation is organised the way it is: 57 files
touched, median change of ten lines, a new library file and a 300-line integer
helper, and almost all of the rest a `case` next to the one `integer` already has
([the walkthrough](implementation-walkthrough.md) has the detail). A new
primitive is not free, but the price is mostly paid once.

## What would change my mind

- If the Luau team would rather not carry a numeric type, the better ask is
  probably smaller: a way for hosts to attach a literal suffix and an operator
  table to a userdata type, so that `19.99d` could be defined by the embedder.
  That solves the literal and the typing, though not the single definition or
  the allocation.
- If there is no real demand beyond mine, the embedded version is a perfectly
  good answer for one host. The core type is worth it when there are several
  hosts and several people writing scripts.
- If a decimal this narrow (27 to 28 digits, see
  [the 90-bit article](why-90-bits.md)) is not enough, the design question
  moves to the representation and not to whether the type should exist.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau config=release

./luau demos/decimal/baseline/bench-pure.luau
./luau demos/decimal/baseline/bench-core.luau
./luau demos/decimal/baseline/limits-pure.luau

c++ -std=c++17 -O2 -I VM/include -I Compiler/include -I Common/include \
    demos/decimal/baseline/host.cpp \
    build/release/libluaucompiler.a build/release/libluaubytecode.a build/release/libluauast.a \
    build/release/libluauvm.a build/release/libluaucommon.a -o /tmp/decimal-host
/tmp/decimal-host demos/decimal/baseline/bench-userdata.luau
```

The memory figures are in `memory-core.luau`, `memory-pure.luau` and
`memory-userdata.luau` in the same directory.

*Measured on an Apple M3 with the release build of the `decimal-type` branch.
The host baseline truncates instead of rounding and has no division; it
exists to be timed and compared, and I would not ship it. A real host library,
[`mlua-decimal`](core-vs-host-library.md), is compared in its own article.*
