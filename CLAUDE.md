# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Personal collection of bash and bashly tools for easing daily Linux command-line
work.

## Commands

- `make help` — list all Makefile targets.
- `make bin/x` — the make way to get one `bin/` entry built and linked: for a
  bashly project this regenerates `bashly/x/x` first if its `bashly.yml`/`src/`
  changed, then (re)links `bin/x`; for a `plain/` script it just links.
  Real file targets with real prerequisites, so re-running with nothing
  changed is a no-op.
- `make all` — the same as `make bin/x`, but for every `bin/` entry at once
  (depends on every `bin/x` target).
- `make bashly/x/x` — (re)generate a single bashly project directly, without
  touching `bin/`.
- `make bashly-build` — regenerate every bashly project at once, without
  touching `bin/` (depends on every `bashly/x/x` target).
- `make build` — currently just depends on `bashly-build`; the place to hang
  any future non-bashly build step.
- `make bin` — creates the `bin/` directory if it doesn't exist yet (it's
  gitignored). An order-only prerequisite (`|`) of every `bin/x` rule, not a
  normal one, so adding/removing links doesn't make `bin/x` targets look
  stale just because the directory's mtime changed.
- `make clean` — removes every `bin/` link (`$(BIN_TARGETS)`) and every
  generated bashly executable (`$(BASHLY_TARGETS)`), undoing `all`/`build`;
  also sweeps `bin/` for any broken symlinks left over from a plain script
  or bashly project that was since removed. bashly has no native clean
  subcommand, so its generated executable is removed directly; fully
  recoverable with `make all`.
- `make lint-plain` — run `$(SHELLCHECK)` (default: `shellcheck`) over
  `plain/`.
- `make lint-bashly` — run `$(SHELLCHECK) --shell=bash` over each project's
  `bashly/*/src/*.sh` (the `--shell=bash` is needed because bashly's
  generated command fragments have no shebang).
- `make lint` — depends on `lint-plain` and `lint-bashly`; with default Make
  behavior it stops after the first failure, use `make -k lint` to run both
  regardless.
- `make new-plain NAME=x` — scaffold `plain/x` (shebang + `chmod +x`) and
  link it into `bin/`.
- `make new-bashly NAME=x` — scaffold `bashly/x/` and run `bashly init`
  inside it; follow up with `make bin/x`.
- `make dump-VAR` — debug helper, prints the value of any Makefile variable
  (e.g. `make dump-BIN_TARGETS`, `make dump-BASHLY_PROJECTS`). For seeing
  the fully-expanded dynamic rules themselves (not just the variable lists),
  use `make -pn | grep -A2 -E '^(bin/|bashly/[^:]+/[^:]+:)'`.

`bashly` is invoked via the `BASHLY` make variable: it uses this repo's own
`.local/bin/bashly` if that's an executable (or a symlink to one) --
gitignored, so drop your own bashly binary/symlink there -- and otherwise
falls back to a dockerized bashly (`dannyben/bashly`, mounting the current
directory and running as your uid/gid) — run `make help` to see which one
is currently active. Override per call if neither fits.

`shellcheck` is likewise invoked via a `SHELLCHECK` make variable (default:
`shellcheck`), following the same tool-variable convention as `CC`/`AR` in
GNU Make's own implicit rules -- override per call if you'd rather use a
dockerized shellcheck or a different binary, e.g.
`make SHELLCHECK='docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck' lint`.

## Layout

- `bin/` — flat directory of everything meant to go on `$PATH`. Contains
  only symlinks, never source files — one per script or generated
  executable, pointing back into `plain/` or `bashly/`. Gitignored (derived
  content; recreated via `make bin`/`make all`). Binary/script names must be
  unique across this whole directory since it is one flat `$PATH` entry.
- `plain/` — simple, single-file scripts with no build step. Each is
  symlinked into `bin/`; the file under `plain/` is the actual source,
  edited directly.
- `bashly/` — full-fledged CLI projects generated with
  [bashly](https://bashly.dannyben.com/), one subfolder per project (e.g.
  `bashly/mytool/`). Generated executables are committed to git (not
  gitignored) so that symlinks in `bin/` work without requiring bashly to
  be installed. bashly expects its config at `src/bashly.yml`, not at the
  project root. After editing that or anything else under `src/`, run
  `make bin/mytool` (regenerates and relinks) rather than invoking `bashly
  generate` by hand.

  Should a CLI-generator framework other than bashly be used later, it
  gets its own sibling wrapper folder (e.g. `argbash/`) rather than being
  mixed into `bashly/`.

## Conventions

- Nothing is edited or authored directly in `bin/` — it holds only
  symlinks. Simple single-file scripts are authored in `plain/`;
  multi-file CLI projects live in their own subfolder under the wrapper
  folder matching the framework that generates them (currently only
  `bashly/`). Both are exposed to `$PATH` by symlinking into `bin/`.
- `bin/` is the single directory meant to be added to `$PATH` — no other
  directory in this repo should be added to it.
- Symlink names in `bin/` are the invocable command name and drop any
  source file extension (e.g. `plain/install-calibre.sh` is symlinked as
  `bin/install-calibre`, not `bin/install-calibre.sh`).
