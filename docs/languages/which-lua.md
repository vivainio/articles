---
icon: lucide/orbit
---

# Which Lua? The language, its runtimes, and its surroundings

*First version: October 18, 2026.*

Someone says their application uses Lua. That tells you something about the
syntax, tables, closures, and the likely presence of an embedded interpreter.
It leaves several practical questions unanswered. Which version? Which
implementation? Who provides the libraries? Can scripts load native modules?
Does the editor understand the host's objects?

Lua is an unusually interesting language to examine through these questions.
The original implementation continues to evolve under a small team's control.
LuaJIT provides another runtime with its own compatibility commitments. Roblox
developed Luau into a language with static analysis and different syntax.
Other projects add types or macros while generating ordinary Lua.

The result is an ecosystem whose boundaries follow the applications embedding
it as much as the language itself. Forks are part of that story, but versions,
governance, tooling, and the host application explain more of everyday life.

## The original Lua has its own way of working

Lua's development process can surprise someone accustomed to finding an issue
tracker, opening a pull request, and waiting for review.

There is an official [GitHub mirror](https://github.com/lua/lua), but it is
updated irregularly and explicitly asks people not to send pull requests.
Bug reports and suggestions belong on the Lua mailing list. The
[FAQ](https://www.lua.org/faq.html) describes Lua as “open-source software but
it is not openly developed.” It also explains that the team welcomes tested
solutions as discussion material, then writes its own implementation when it
decides to address a problem. Third-party code is not incorporated verbatim.

That distinction matters. The source is available and discussion is public;
ownership of the implementation and its design remains concentrated. Looking
only at GitHub activity gives an incomplete picture of maintenance, and a
patch arriving on the mailing list does not enter a conventional merge queue.

This process also gives the chapter a useful question: what does a language
gain from concentrated authorship, and what becomes harder for contributors?
Consistency and participation are both relevant, without assuming that one
development process explains every later branch of the ecosystem.

## Mainline Lua has moved on

The current release at the time of writing is **Lua 5.5.1**, released on
August 3, 2026. Lua 5.5 arrived in December 2025 with global variable
declarations, named vararg tables, more compact arrays, and incremental major
garbage collection. Earlier milestones include Lua 5.3's integers and bitwise
operators, and Lua 5.4's const and to-be-closed variables.
[Official version history](https://www.lua.org/versions.html)

The numbering needs explanation. Lua does not use semantic versioning:
5.4 to 5.5 is a language-version change, with possible API and source
incompatibilities and no ABI compatibility. Native modules and applications
embedding Lua need recompilation. Patch releases within a version have a
different compatibility promise. Precompiled bytecode is also tied to a
version. [Lua's numbering scheme](https://www.lua.org/versions.html)

For an embedded language, that upgrade crosses a boundary. An application
owns its runtime and may have years of scripts, plugins, and native bindings
depending on its existing behavior. Replacing the interpreter is only one
part of moving the application forward.

This makes “old Lua” an ambiguous description. It can mean an unsupported
upstream release, or the language baseline of an actively maintained runtime.
Those situations require different judgments.

## LuaJIT: performance with a lasting baseline

[LuaJIT](https://luajit.org/extensions.html) implements Lua 5.1 compatibility
and adds facilities such as its foreign function interface, bit operations,
and selected features from later Lua versions. It is a separate implementation
with a just-in-time compiler, rather than a switch that enables compilation
in the current mainline Lua interpreter.

Its FFI is an especially consequential extension: scripts can declare C types
and call C functions without writing a conventional Lua C binding for every
operation. Code that depends on it consequently depends on more than the
common Lua language surface. [LuaJIT extensions](https://luajit.org/extensions.html)

LuaJIT's release model is another source of confusion. The project currently
describes itself as actively maintained, recommends the **2.1 branch for
production**, and uses rolling releases whose version includes a commit
timestamp. Its status page identifies the repository hosted by luajit.org as
the authoritative origin. A familiar old version number is insufficient
evidence that development has stopped. [LuaJIT status](https://luajit.org/status.html)

There are therefore two independent axes: how recently a runtime was maintained,
and which language version it implements. A runtime can receive fixes and
platform work while retaining a long-standing compatibility baseline.

## Luau grew out of Roblox's requirements

Roblox began using Lua 5.1 around 2006, accumulating changes for its sandbox
and libraries. Its own history dates the deliberate effort to build Luau to
**2019**. By November that year, Roblox was already reporting that the new
implementation had become the default for most platforms and configurations.
Luau went open source on **November 3, 2021**.
[Why Luau?](https://luau.org/why/),
[origins and evolution](https://luau.org/news/2022-11-04-luau-origins-and-evolution/),
[November 2019 recap](https://luau.org/news/2019-11-11-luau-recap-november-2019/),
[open-source announcement](https://luau.org/news/2021-11-03-luau-goes-open-source/)

“Forked in 2019” is useful shorthand, but it compresses years of earlier
adaptation into one event. It can also suggest more shared implementation
than remains: the Luau team says a large part of the codebase was written
from scratch. [Implementation background](https://luau.org/why/)

Roblox's explanation is concrete. Its codebases had grown, performance
requirements had increased, and the lack of type checking had become painful.
Upgrading upstream Lua would break features already in widespread use.
LuaJIT did not meet its portability and ease-of-change requirements or solve
the analysis problem. Luau was an answer to that combination of constraints.
[Why Luau?](https://luau.org/why/)

The changes accumulated over time; the following describes today's language,
not a list of features delivered at its initial launch.

### Types and syntax

Luau adds optional type annotations and a gradual type system, including
table types, unions, intersections, generics, and type inference. It also adds
`continue`, compound assignment, if expressions, generalized iteration, and
string interpolation. [Luau syntax](https://luau.org/syntax/)

For example, this is Luau rather than portable Lua:

```lua
local function greeting(name: string): string
    return `Hello, {name}`
end

local total = 0
for _, value in {10, 20, 30} do
    total += value
end

local label = if total > 50 then "large" else "small"
```

The example combines annotations, interpolation, iteration directly over a
table, compound assignment, and an expression that selects a value. The
annotations supply information to development tools; they do not turn every
function boundary into a runtime validation boundary.

### A different implementation and sandbox

Luau's performance work spans its compiler, bytecode interpreter, specialized
built-ins, and native code generation. “Lua with types” misses much of that
work. It also gives no useful basis for a universal speed ranking: execution
mode, platform, and workload matter.
[How Luau is made fast](https://luau.org/performance/)

Compatibility has limits in both directions. Luau preserves a Lua 5.1 baseline
while deliberately omitting facilities for sandboxing, including direct file
loading and exposed bytecode. It does not implement the full sequence of
later mainline Lua features. The project's
[compatibility matrix](https://luau.org/compatibility/) is more useful than a
blanket assertion that Luau runs all Lua code.

Its development process is different too. Luau has a public
[implementation repository](https://github.com/luau-lang/luau) and a public
[RFC process](https://github.com/luau-lang/rfcs) for language evolution.
That provides another way to study governance alongside the technical changes.

## Adding a language without replacing the runtime

Some projects change what developers write while keeping Lua as the execution
target. Calling them all forks hides an important distinction.

[Teal](https://github.com/teal-language/tl) is a typed dialect whose compiler
generates Lua. Its documented runtime support includes Lua 5.1 through 5.4 and
LuaJIT. Type checking happens before execution, and the generated program runs
on an existing Lua implementation. This offers a different adoption path from
switching to a new VM.

[Fennel](https://github.com/bakpakin/Fennel) is a Lisp that compiles to Lua,
with compile-time macros and access to Lua libraries. Developers can ship
generated Lua without a Fennel runtime dependency. Here the attraction is a
different way to express and transform programs while using the surrounding
Lua environment.

These are distinct choices:

| Project or approach | What changes? | What executes the program? |
| --- | --- | --- |
| Mainline Lua | The language and its reference implementation evolve together | The selected Lua version |
| LuaJIT | Implementation, performance behavior, and extensions | LuaJIT |
| Luau | Language, analysis tools, implementation, and sandbox facilities | Luau |
| Teal | Typed source compiled into Lua | A supported Lua runtime |
| Fennel | Lisp syntax and macros compiled into Lua | A compatible Lua runtime |

The table is a map of relationships, not a compatibility guarantee between
every pair of entries.

## Tooling can add types while the source stays Lua

A new language is not required to improve the editing experience.
[Lua Language Server](https://luals.github.io/) provides completion,
diagnostics, type analysis, and annotations for parameters, returns, and
classes. Definition files can describe libraries and host APIs.

That produces another useful distinction: types expressed in comments for a
tool, types expressed in a dialect that compiles to Lua, and types integrated
into a language such as Luau. Similar-looking editor assistance can sit on top
of very different execution and build arrangements.

[LuaRocks](https://luarocks.org/) supplies a package manager and registry for
Lua modules. But a package manager cannot erase the runtime boundary: a module
may depend on a particular Lua version, a native library, or facilities supplied
by one host. Finding a package and being able to use it inside an embedded
application are separate steps.

## The host is part of the programming environment

The key practical question is often who owns the process. In a standalone
program, you can select the interpreter, install modules, and control the
filesystem. Inside another application, those decisions may already belong
to the application author.

The host chooses which functions to expose, how scripts enter the system,
what objects they manipulate, and which operations are permitted. That
environment becomes part of what developers mean when they say “Lua,” even
when the functions they use are absent from Lua's standard library.

This is particularly easy to confuse with Luau and Roblox. Luau is an
embeddable language with its own compiler and VM. Roblox supplies an
application platform around it. Another Luau embedder does not automatically
acquire Roblox's services, objects, or execution model.
[Luau repository](https://github.com/luau-lang/luau)

For the developer, a useful description of a Lua environment therefore needs
four pieces: the language version or dialect, the runtime implementation,
the host APIs and restrictions, and the tools used to develop and distribute
code. “We use Lua” is the opening sentence of that description.

## Several directions at once

My reading of this landscape is that Lua's small size makes adaptation
practical, while embedding puts different users under different pressures.
Mainline language design, compatibility with existing applications, runtime
performance, sandboxing, and analysis of large codebases pull in different
directions.

That does not establish that the original team's contribution model caused
the alternatives. Luau's published history, for example, supplies specific
engineering motivations. Governance is worth examining on its own merits
without making it a universal explanation.

The interesting question for Lua's future is how these environments remain
useful to one another: what source can be shared, which libraries travel,
and how clearly projects communicate their boundaries. The language is small;
the decisions around it are substantial.
