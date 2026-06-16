# Packaging Rust CLI Apps to PyPI

*2026-06-16*

I distribute a couple of Rust command-line tools as standalone binaries on
GitHub Releases. That works, but it asks something of the user: download the
right file for their platform, unzip it, put it on `PATH`. People who live in
the Python ecosystem already have a one-liner for installing CLI tools — `pip
install` or `uv tool install` — and they'd rather use it.

The good news: you can ship a Rust binary through PyPI **without writing a single
line of Python or any FFI bindings**. The wheel just carries your compiled
executable and drops it on `PATH` at install time. This is exactly how tools like
`ruff` and `uv` are distributed. The tool that makes it work is
[maturin](https://www.maturin.rs/).

## The key idea: `bindings = "bin"`

maturin is best known for building Python extension modules from Rust (via
PyO3). But it has a second mode, `bindings = "bin"`, that does something much
simpler: it takes your crate's `[[bin]]` target and packages the compiled
executable into a wheel as a script. No PyO3, no `cdylib`, no library API — the
wheel just installs the binary into the environment's `bin/` (or `Scripts/` on
Windows). If you only want to *distribute the executable*, this is all you need.

## Add a `pyproject.toml`

For a binary-only crate, this is the entire Python-side configuration:

```toml
[build-system]
requires = ["maturin>=1.7,<2"]
build-backend = "maturin"

[project]
name = "mytool"
description = "What it does"
requires-python = ">=3.10"
readme = "README.md"
dynamic = ["version"]

[tool.maturin]
bindings = "bin"
```

`dynamic = ["version"]` lets maturin read the version straight from
`Cargo.toml`. `requires-python` barely matters for a binary wheel — there's no
Python code, so the binary runs identically under any interpreter; it only gates
which environments will install it. Your existing `[lib]` and `[[bin]]` stay
untouched. Build and test locally with:

```bash
uvx maturin build --release --out dist
```

## Publishing is easy with the ready-made actions

A binary wheel is platform-specific (it contains a native executable) but
Python-version-agnostic, so the CI matrix is over OS/arch, not Python versions.
Two off-the-shelf GitHub Actions do all the work:

- [`PyO3/maturin-action`](https://github.com/PyO3/maturin-action) builds the
  wheel — just hand it the Rust `target` and `manylinux: auto`.
- [`pypa/gh-action-pypi-publish`](https://github.com/pypa/gh-action-pypi-publish)
  uploads it. Give that job `permissions: id-token: write` and a GitHub
  `environment` and you get token-free **Trusted Publishing** (OIDC).

Both READMEs have copy-pasteable jobs. These slot in *alongside* your existing
GitHub-Release binary jobs — I kept shipping standalone binaries and added PyPI
as a parallel channel.

## The payoff: the right binary, picked automatically

This is the real win over GitHub Releases. There, the user has to know their own
platform and pick the matching download — the right OS, the right arch, gnu vs
musl. With wheels, **the installer does that for them**. They run `pip install
mytool` (or `uv tool install`) on a Mac, a Linux box, or Windows, and the
correct binary is fetched and put on `PATH`. No choosing, no wrong-arch
mistakes — the selection is built into how wheels work.

Updates come for free too: `pip install -U mytool` or `uv tool upgrade mytool`
pulls the latest release, no re-downloading the right file by hand. And with
`uvx` you don't install anything permanently at all — `uvx mytool` downloads the
right wheel into a transient cache, runs the binary, and leaves nothing behind,
perfect for a one-off invocation or trying a tool before committing to it.

The mechanism is just the wheel filename. A wheel like
`mytool-2.0.0-py3-none-manylinux_2_17_x86_64.whl` encodes its target platform in
the tag (derived from the Rust target triple maturin built for). At install
time, `pip`/`uv` compute the set of tags the current machine supports — OS,
arch, and on Linux the glibc version — and download the wheel whose tag matches.
No Python code does this; it falls out of how the packaging tools already work.

So: a ~10-line `pyproject.toml`, two stock actions, and your binaries on GitHub
Releases keep working unchanged — while everyone who thinks in `pip`/`uv` gets a
one-liner.
