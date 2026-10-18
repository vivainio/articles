# How decimals feel next to number, integer and vector

*2026-10-18*

A new value type is only worth having if people can write ordinary code with
it. This article is about that: how much of the language works on a `decimal`,
where it stops, and whether the stopping points are sensible or accidental. I
compare it with the three value types it will sit beside, `number`, `integer`
and `vector`, using output from the
[demo suite](https://github.com/vivainio/luau/tree/decimal-type/demos/decimal)
and not my memory of how Luau behaves.

## The same code, with and without

Money is the case that motivated all this, so start there. An invoice with four
lines and 24 % VAT, written with plain numbers:

```lua
local lines = { {19.99, 3}, {4.95, 12}, {0.333, 100}, {85, 1.5} }
local net = 0
for _, l in lines do net += l[1] * l[2] end

print(net)            -- 280.17
print(net * 0.24)     -- 67.24080000000001

local function round2(x) return math.floor(x * 100 + 0.5) / 100 end
print(round2(net * 0.24))   -- 67.24, but the double is 67.239999999999995
```

and with decimals:

```lua
local lines = { {19.99d, 3d}, {4.95d, 12d}, {0.333d, 100d}, {85d, 1.5d} }
local net = 0d
for _, l in lines do net += l[1] * l[2] end

print(net)                              -- 280.170
print(net * 0.24d)                      -- 67.24080
print(decimal.round(net * 0.24d, 2))    -- 67.24
```

The code is the same shape. What changed is that the values printed are the
ones a person would write on the invoice, and that the rounding step is a
named operation with a documented rule instead of a formula you have to trust.

That last point is worth a second look, because "round to cents" is the
function everyone writes by hand. Here are two common ways to do it with
doubles, on numbers that sit on a half:

| Input | `floor(x*100 + 0.5)/100` | `string.format("%.2f")` | `decimal.round(x, 2)` | `decimal.round(x, 2, "awayfromzero")` |
|---|---|---|---|---|
| 2.675 | 2.68 | **2.67** | 2.68 | 2.68 |
| 1.005 | **1** | 1.00 | 1.00 | 1.01 |
| 0.285 | 0.28 | 0.28 | 0.28 | 0.29 |

Two methods that are supposed to do the same thing disagree on 2.675, and
neither of them gives the schoolbook 1.01 for 1.005, because the double nearest
to 1.005 is slightly below it. The decimal column is not magic either: the
default is half-even (banker's rounding), so a true half goes to the even
neighbour and 1.005 becomes 1.00. The difference is that the rule is written
down, applies to the value you typed, and can be changed to the schoolbook one
with one argument. That is the ergonomic win in one table: the answer does not
depend on which idiom you happened to reach for.

## What works on each type

I ran the same operations against all four types. A tick means the
operation succeeds, a cross means it raises an error.

| Operation | number | integer | decimal | vector |
|---|:-:|:-:|:-:|:-:|
| `a + a`, `a - a`, `a * a`, `a / a` | ✓ | ✗ | ✓ | ✓ |
| `a // a` | ✓ | ✗ | ✗ | ✓ |
| `a % a` | ✓ | ✗ | ✓ | ✗ |
| `a ^ a` | ✓ | ✗ | ✗ | ✗ |
| `-a` | ✓ | ✗ | ✓ | ✓ |
| `a < a`, `a <= a` | ✓ | ✗ | ✓ | ✗ |
| `a == a` | ✓ | ✓ | ✓ | ✓ |
| `a + 1` (a plain number) | n/a | ✗ | ✗ | ✗ |
| `a .. "x"` | ✓ | ✗ | ✗ | ✗ |
| `` `{a}` `` and `tostring(a)` | ✓ | ✓ | ✓ | ✓ |
| `t[a] = 1` (as a table key) | ✓ | ✓ | ✗ | ✓ |
| `table.sort({a, a})` | ✓ | ✗ | ✓ | ✗ |
| `table.find({a}, a)` | ✓ | ✓ | ✓ | ✓ |
| `math.max(a, a)` | ✓ | ✗ | ✗ | ✗ |
| `string.format("%s", a)` | ✓ | ✗ | ✗ | ✗ |
| `string.format("%d", a)` | ✓ | ✓ | ✗ | ✗ |

Reading it as a design review:

- **Decimal is much closer to `number` than `integer` is.** `integer`
  supports equality and nothing else; arithmetic is the library
  (`integer.add`). Decimal has every arithmetic operator an amount of money
  needs, plus ordering, and so default `table.sort` just works. For code that
  is going to add up prices, that difference decides whether the type is
  usable at all.
- **Decimal has a different set of gaps from vector, and they are the right
  ones.** Vectors have no ordering and no `%`; decimals do. Decimals have no
  `//` or `^`; there is no sensible decimal answer to `2d ^ 0.5d`, and a
  floor-divide is `decimal.trunc(a / b)` or `decimal.floor`.
- **Four things fail for no reason deeper than "not done yet"**: `..`, `math.*`,
  `%s` and table keys. The first three are small, and I would add them before
  proposing anything. The fourth is hard (see below).

One row has a story. `table.find({a}, a)` was the only operation where decimals
did not just fail, they failed *quietly*: it returned `nil` for a value that
was in the table. The comparison above is how I noticed, and it is fixed. An
unsupported operation should raise, and a supported one should work; "returns
the wrong answer" is the only unacceptable option.

## The mixing rules

Decimals mix with `integer` and never with `number`:

```lua
print(1.5d + 2i)      -- 3.5
print(2i * 0.5d)      -- 1.0
print(1.5d < 2i)      -- true
print(1.5d + 1)       -- error: attempt to perform arithmetic (add) on decimal and number
print(1.5d < 2)       -- error: attempt to compare decimal < number
```

The reasoning is the same as .NET's: an `int` converts to a `decimal` without
loss, a `double` does not. The type system enforces it as well (see below), so
the error shows up in the editor and not at run time.

The rule has one uncomfortable corner. Equality is strict about types, as it is
everywhere in Luau, so:

```lua
print(1d < 1.5d, 1i < 1.5d)    -- true  true     ordering mixes with integers
print(2d == 2i)                -- false          equality does not
print(2d <= 2i and 2d >= 2i)   -- true
```

`<=` and `>=` see `2d` and `2i` as equal and `==` does not. Equality has never
crossed types in Luau (`1 == "1"` is false), and making it do so here would mean
changing the `EQ` opcodes and their native-code versions, so I left it. But
ordering across `decimal` and `integer` is new, which makes this the one place
where I think a reader could be surprised; it should be in the documentation in
bold.

## What the errors say

A new type has to fail legibly. These are the messages from the error catalog
(`12-errors` in the suite), exactly as printed:

```text
decimal + number     attempt to perform arithmetic (add) on decimal and number
decimal < number     attempt to compare decimal < number
decimal .. string    attempt to concatenate decimal with string
decimal // decimal   attempt to perform arithmetic (idiv) on decimal
1d / 0d              decimal division by zero
9223372036854775807d * 2d    decimal overflow
t[1d] = 1            table index is a decimal
decimal.round(1d, 29)        invalid argument #2 to 'round' (number of places out of range [0, 28])
```

They name both operand types, which is the useful part when one of them is a
`number` that came from somewhere else. The weakest message is the last of the
arithmetic ones: `decimal // decimal` says "on decimal", which is accurate and
unhelpful. There is no "did you mean `decimal.trunc(a / b)`", and I would not
add one to the VM; that belongs in documentation.

## In the editor

The type checker treats `decimal` as a primitive, like `integer`, and the
operators are declared as metamethods on it. The behavior in a strict file
(from `13-typing`):

```lua
--!strict
local a: decimal = 1.5d
local i: integer = 2i
local n: number = 2

local ok1: decimal = a + i          -- fine, in either order
local ok2: boolean = i <= a         -- fine
local e1 = a + n                    -- Operator '+' could not be applied to operands of
                                    --   types decimal and number; there is no corresponding
                                    --   overload for __add
local e2: number = a + a            -- Expected this to be 'number', but got 'decimal'
local e3 = a // a                   -- no corresponding overload for __idiv
```

and the refinement works as for any primitive:

```lua
local function describe(x: decimal | number | string): string
    if type(x) == "decimal" then
        return decimal.tostring(x)      -- x is a decimal here
    end
    return tostring(x)
end
```

Both the new and the old type solver pass the same tests. Writing this I found
that the linter flagged `type(x) == "decimal"` as an unknown type name; that was
a bug in the prototype and is fixed. (`integer` has the same warning today; I checked. It is not mine to change, but
it is the kind of thing a new primitive type finds.)

## The costs of the design that you can feel

Four things are visible to an everyday user, and I think they are worth saying
plainly rather than discovering in review.

**Scale is part of what you print.** `2.50d` and `2.5d` are equal and print
differently. That is exactly what you want for an invoice line and a surprise
for someone who expects a number. It follows .NET, and I think it is right, but
it means `tostring(a) == tostring(b)` is not a way to test equality.

**There is no implicit string conversion.** `"total " .. d` fails; interpolation
works, and so does `tostring`. This is consistent with `integer`, and with a
type that has to decide how many digits to show, but `..` is the first thing
anyone will type.

**Decimals cannot be table keys.** Using one raises an error. Supporting it is
possible: the hash would have to ignore the scale, so that `2.50d` and `2.5d`
land in one slot, and key comparison would have to be numeric. But the table
implementation has several specialised lookup paths for each key type, and I
did not want to touch all of them in a prototype or let a table silently hold
two entries for what `==` calls one key. The workaround is `tostring` plus a
convention about scale, or `decimal.round` to a fixed scale first. This is the
limitation I would expect people to push back on.

**Everything numeric in the standard library refuses it.** `math.max`,
`math.floor`, `string.format("%.2f")` and the rest take numbers. The decimal
library has its own `min`, `max`, `floor`, `ceil`, `trunc` and `round`, and
`decimal.tonumber` is the bridge, but code that formats currency with
`string.format` has to convert first. Whether `string.format` should learn
about decimals is a question for the people who own it.

## What it feels like

My honest summary: for the thing it is for, adding up and splitting amounts of
money and printing the result, it is comfortable, and noticeably better than
`integer`, because it has operators. For everything else around that core, it
feels like a library type that grew an operator set, which is roughly what it
is. The gaps are all in the standard library's edges and none are in the type's
core.

What I would do before showing this to anyone who owns Luau:

1. Make `..` and `string.format("%s")` work, or decide that they should not and
   say why.
2. Decide the table-key question deliberately instead of by default.
3. Document the `==` versus `<=` asymmetry, in bold.

The remaining article is the maintainer's view: what it took to build, file by
file.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git checkout decimal-type
make luau luau-analyze config=release
./demos/decimal/run.sh
```

The operation table comes from a small probe that runs each operation in a
`pcall` against each type; the examples are the demos `04-arithmetic`,
`08-mixing`, `10-money`, `11-containers`, `12-errors` and `13-typing`.

*Pinned to the `decimal-type` branch of my fork at the time of writing.*
