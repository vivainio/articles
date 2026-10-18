# What it took to build: a walkthrough

*2026-10-18*

This is the article for whoever would have to maintain a `decimal` type: where
the change lands, why it lands there, and what I only learned by running
things. It is organised the way a decimal travels through the system, from the
source text to the value in a register, and then back out through the type
checker.

The method matters, because it is the reason the change is small. Luau's
`integer` type is recent, it is a value type with its own tag, a literal
suffix and a library, and it went through every stage a new type goes
through. So I did not design a decimal type from scratch. I grepped for
`LUA_TINTEGER`, `PrimitiveType::Integer`, `AstExprConstantInteger` and the
rest, and treated every hit as a question: does a decimal need this too?

## The size of it

Against upstream at the point I forked:

| Area | Files | Lines added |
|---|---:|---:|
| VM (`VM/`) | 15 | 1,027 |
| Analysis (the type checker) | 22 | 242 |
| Parser and AST (`Ast/`) | 6 | 159 |
| Bytecode | 5 | 76 |
| Compiler | 5 | 67 |
| Common, build | 2 | 2 |
| **Source total** | **55** | **1,573** (16 removed) |
| Tests | 9 | 576 |
| Demo suite | 33 | 2,237 |

Two numbers say more than the total. One file, the new `ldeclib.cpp`, is 760 of
those lines. And the median change across the 55 files is **10 lines**: 30
files changed by 10 lines or fewer, 43 by 20 or fewer, and only two others
(the parser at 99 and the VM's arithmetic slow path at 92) are over 50. A type
that touches 55 files sounds invasive. Almost all of it is one `case` in a
`switch` that was already enumerating the types.

## Where it lines up with `integer`

### The tag and the value (`VM/include/lua.h`, `VM/src/lobject.h`)

The tag goes in the `lua_Type` enum, next to `LUA_TINTEGER`:

```c
LUA_TINTEGER,
LUA_TDECIMAL, // int64 mantissa in Value::l, int32 exponent in TValue::extra[0]
```

and a value is written with a macro that mirrors `setlvalue`:

```c
#define setdecvalue(obj, m, e) \
    { \
        TValue* i_o = (obj); \
        i_o->value.l = (m); \
        i_o->extra[0] = (e); \
        i_o->tt = LUA_TDECIMAL; \
    }
```

The mantissa reuses the field `integer` already uses, and the exponent goes in
`extra`, the slot that holds a vector's third component. The enum comment says
that changing its order has consequences ("grep ORDER TYPE"), and it does:
inserting a tag shifts the numeric value of every type after it, which an
embedder that hard-codes `lua_type` results would notice. `integer` did exactly
the same thing when it arrived, so there is a precedent, but it is a line item
for the changelog.

### Source text to AST (6 files, the same six)

`Ast.h`, `Ast.cpp`, `Cst.h`, `Cst.cpp`, `Parser.cpp` and `PrettyPrinter.cpp`.
`integer` touched exactly these, and so does decimal: a node class
(`AstExprConstantDecimal`), a CST node so the pretty printer can reproduce the
original spelling, a visitor hook, and a branch in `Parser::parseNumber`.

The lexer needed no change, which I did not expect. It already reads a number
followed by letters as one token and leaves the interpretation to the parser,
so `19.99d` arrives as a `Number` lexeme. The parser branch is where the one
real subtlety of the syntax lives:

```cpp
else if (scratchData.back() == 'd' && !(scratchData.size() > 1 && scratchData[0] == '0' && (scratchData[1] == 'x' || scratchData[1] == 'X')))
{
    // decimal literal, e.g. 1.25d (note that 0x1d is a hexadecimal number and not a decimal)
```

`d` is a hex digit, so a suffix that is also a digit is ambiguous exactly where
a number starts with `0x`. `integer`'s `i` does not have this problem. A test
pins it down (`0x1d` is 29).

### Compiler and bytecode (10 files)

A constant has to be remembered by the compiler (`ConstantFolding.h/.cpp`),
named by `typeof` folding (`BuiltinFolding.cpp`), emitted (`Compiler.cpp`),
stored in the bytecode builder and the bytecode graph, printed by the dumper
(`BytecodeDump.cpp`), and read back by the VM loader (`lvmload.cpp`). The wire
format gets a new constant kind:

```cpp
case LBC_CONSTANT_DECIMAL:
{
    bool isNegative = read<uint8_t>(data, size, offset);
    uint64_t magnitude = readVarInt64(data, size, offset);
    bool isNegativeExp = read<uint8_t>(data, size, offset);
    int exp = int(readVarInt(data, size, offset));
    setdecvalue(&p->k[j], isNegative ? (int64_t)(~magnitude + 1) : (int64_t)magnitude, isNegativeExp ? -exp : exp);
    break;
}
```

which is `LBC_CONSTANT_INTEGER` with a second sign-and-varint for the exponent.
Two decimals that are equal but have different scales (`1.5d` and `1.50d`) are
different constants on purpose, because the scale is part of the value's text.
The compiler's constant folder, however, must treat them as equal for `==`;
that is item 8 in the list below.

### The type checker (22 files)

This is the widest part and the most mechanical. A primitive type touches:
the type definition and its `BuiltinTypes` instance (`Type.h`, `Type.cpp`), the
global `decimal` type binding (`GlobalTypes.cpp`), printing (`ToString.cpp`,
`TypeAttach.cpp`), the normaliser, which has a field per primitive and a dozen
places that union, intersect, negate and enumerate them (`Normalize.h/.cpp`,
43 added lines), `type(x) == "decimal"` refinement in both solvers
(`ConstraintGenerator.cpp`, `TypeInfer.cpp`, `TypeStateMap.cpp`), the literal's
type in both solvers, the visitors that must not crash on a new node
(`NonStrictTypeChecker.cpp`, `DataFlowGraph.cpp`, `AstJsonEncoder.cpp`,
`Linter.cpp`), and exposure to user-defined type functions
(`TypeFunctionRuntime.*`). Each is a few lines.

## Where `integer` touched more than decimal did

A partial list of the files `integer` changed that decimal has not (found by
searching the tree for its tag, type and node names), mostly in places I have
not done and would need to for a complete job:

| Where | What `integer` has | Decimal today |
|---|---|---|
| `CodeGen/` (9 files) | native code generation: type checks, loads and stores of the tag, constant propagation, X64 and A64 lowering, builtin fast paths | **nothing.** Unknown tags fall back to the VM, which is why `--codegen` output matches the interpreter |
| `Compiler/src/Types.cpp`, `Types.h` | bytecode type tags for `integer` annotations | not needed: no bytecode type tag exists for decimal, so annotations compile as unknown |
| `Compiler/src/Builtins.cpp`, `VM/src/lbuiltins.cpp` | fast calls for the `integer.*` functions | none |
| `VM/src/lbuflib.cpp` | `buffer.readinteger/writeinteger` | not applicable |
| `VM/src/lstrlib.cpp` | `%d` formatting | decimals are refused by `string.format` |
| `Bytecode/src/Sccp.cpp` | constant propagation compares integer constants | unknown, so never folded |
| `Compiler/include/luacode.h`, `lcode.cpp` | embedder API to define integer compile-time constants | none |

CodeGen is the one that matters. It is the largest block of `integer` work and
the one place where decimal would need a real design: the register-level
representation is a 64-bit payload plus a separate exponent, and the IR has no
notion of a two-field value. I did not attempt it. The consequence is exactly
the performance profile in the [64-bit article](why-64-bits.md): correct
everywhere, fast nowhere.

## Where decimal had to go further

`integer` is a deliberately thin type: equality is the only operator, and
arithmetic is the library. Decimal has operators, and that is where the
template ran out.

- **Arithmetic in the VM (`lvmutils.cpp`, 92 lines).** `integer` has none. The
  slow path for `+ - * / %` and the ordering comparisons gets a block for
  decimals, which is guarded by `LUAU_UNLIKELY(ttisdecimal(rb) || ttisdecimal(rc))`
  so that the number and vector paths pay one predictable branch:

  ```cpp
  if (LUAU_UNLIKELY(ttisdecimal(rb) || ttisdecimal(rc)))
  {
      int64_t mb, mc, m = 0;
      int eb, ec, e = 0;

      if (decimalOperand(rb, &mb, &eb) && decimalOperand(rc, &mc, &ec))
  ```

  `decimalOperand` also accepts an `integer`, which is the whole of "decimals
  mix with integers".
- **The library (`ldeclib.cpp`, 760 lines against `lintlib.cpp`'s 614).** About
  half is a numeric core (`reducewide`, `addaligned`, `luai_decdiv`) and the
  rest is the usual argument checking and registration. The core is the part
  that deserves a reviewer's time; the [first article](checked-against-dotnet.md)
  is the evidence for it.
- **Typing the operators.** There is no `__add` on a primitive to look at, so
  the operators are declared as metamethods on a metatable attached to the
  `decimal` primitive, the same mechanism strings use. That needed
  `makeDecimalMetatable` in `BuiltinDefinitions.cpp`, and a branch in
  `getMetatable` so that a primitive other than `string` can have one.
- **Comparisons between unrelated types.** The checker's rule is that
  you may compare two things only if their types overlap. `decimal` and
  `integer` do not overlap, but ordering them is legal, so both solvers needed
  an exception (`isDecimalIntegerOrdering` in `TypeChecker2.cpp`, and a skipped
  unification in `TypeInfer.cpp`).

## What the template did not tell me

Copying a template finds the places that look like the template. These are the
things that did not, in the order I hit them. Each one is a test now.

1. **A crash in the type checker setup.** The builtin type arena is frozen
   after construction, and writing the decimal metatable into it from
   `registerBuiltinGlobals` was a memory-protection fault (exit code 138, no
   output) that only appeared in the unit tests, which freeze the arena. The
   string metatable is built in a specific window in `GlobalTypes.cpp` where the
   arena is temporarily unfrozen; decimal's has to be built in the same window.
2. **`Exceeded constant limit`.** The compiler has fast paths that put a
   constant operand directly in the instruction (`ADDK`, `JUMPXEQK`).
   `integer` and vectors opt out of them because supporting them would need new
   opcodes. I did not, and `x + 0.1d` failed to compile with a message about
   constants. One extra condition, copied from the integer line next to it.
3. **Six existing tests broke, all for the same reason.** Some tests print the
   normalised form of a negated type: "everything except a function" is a list
   of primitives. A new primitive joins every one of those lists. The same thing
   happened when `integer` was added (the tests have two expectations, one with
   and one without it). The failures were correct; the expectations changed.
4. **A regression test counts bytecode constants.** `LBCConstantRegressionTest`
   pins every `LBC_CONSTANT_*` value so they cannot drift. It should have failed
   when I added one, and it did.
5. **The linter did not know the type.** `type(x) == "decimal"` produced
   `Unknown type 'decimal' (expected primitive type)`. `integer` has the same
   warning today.
6. **Ordering decimal against integer was rejected in two places**, once in each
   solver, as described above.
7. **A test checks that every global has type information, and vice versa.**
   The `Types` conformance test walks the real globals and the declared ones
   and failed with "_G.decimal missing from type information" as soon as the
   library existed. A useful guard: a new library cannot ship without its
   declarations.
8. **Equality of constants must ignore scale.** Once scale was preserved, a
   folder that compared mantissa and exponent would fold `1.50d == 1.5d` to
   `false` for literals while the run-time answer is `true`. I fixed it with the
   scale change, before it could show up as a difference; it is covered by an
   assertion that runs both ways.
9. **`table.find` returned `nil` for a decimal that was in the table.** Types
   with a fast path in `luaH_rawfind` each have a case; mine fell into the
   generic one, which compares pointers. It now compares numerically. (This one
   is in the [ergonomics article](ergonomics.md): I found it by comparing four
   types side by side.)
10. **Definitions depend on a flag.** The `integer` type only exists when
   `LuauIntegerType2` is on. The decimal library declarations mention `integer`
   in their parameter types, so they have to be generated with and without it,
   and the tests that use both need the flag set before the fixture builds the
   globals.

Ten surprises. One was a crash, one a confusing error, one a silent wrong
answer; the rest were failures of tests that already existed. The existing suite
did most of the work, and the demo suite and the cross-type comparison caught
the two the suite had no opinion about (the linter and `table.find`).

## What a reviewer should read

If you only have an hour, read these, in this order:

1. `VM/src/ldeclib.cpp`, the first 300 lines (`reducewide`, `addaligned`,
   `luai_decdiv`). Everything else is plumbing.
2. `VM/src/lvmutils.cpp`, the decimal block in `luaV_doarithimpl` and the two
   ordering functions.
3. `Analysis/src/GlobalTypes.cpp` and `makeDecimalMetatable` in
   `BuiltinDefinitions.cpp`, for how the operators are typed.
4. The diff of `Ast/src/Parser.cpp`, for the literal rules.

For the remaining 50-odd files, the diff is the review: it is a list of
`case`s next to the same `case` for `integer`.

## What it costs to own

- **Merge conflicts.** Upstream syncs weekly. My change touches many of the same
  files as `integer`'s, in small hunks next to `integer`'s own, so the
  conflicts will be real but mechanical. The one that will not be mechanical is `LBC_CONSTANT_DECIMAL`:
  if upstream adds a constant kind, we both want the next number.
- **The ABI note** above (type numbering) and the unstable
  `lua_pushdecimal(L, int64_t mantissa, int exponent)`.
- **CodeGen,** whenever someone wants decimals to be fast.
- **A 760-line library** whose arithmetic needs `__int128`, which MSVC does not
  have.

## Reproducing

```bash
git clone https://github.com/vivainio/luau && cd luau
git diff --stat 9d7748a4..origin/decimal-type -- VM Ast Bytecode Common Compiler Analysis
# the bug list is the history of the tests: tests/conformance/decimal.luau,
# tests/Parser.test.cpp, tests/Compiler.test.cpp, tests/TypeInfer.primitives.test.cpp
```

*The numbers in this article come from `git diff --numstat` against the commit
I forked at (`9d7748a4`), measured on the `decimal-type` branch at the time of
writing. The "integer touched" file list is from searching the tree for
`integer`'s tag, type and node names, so it may miss a file that mentions
integers only in a string or a comment.*
