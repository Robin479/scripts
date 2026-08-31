# scripts

Personal collection of bash and bashly tools for the Linux command line.

## Layout

- `bin/` — flat directory of everything meant to go on `$PATH`. Contains
  only symlinks, never source files — one per script or generated
  executable, pointing back into `plain/` or `bashly/`. Gitignored (its
  contents are derived, and the directory itself is (re)created on demand
  by the Makefile) -- run `make all` after a fresh clone. Add this
  directory to `$PATH`.
- `plain/` — simple, single-file scripts with no build step. Each is
  symlinked into `bin/`.
- `bashly/` — full-fledged CLI projects generated with
  [bashly](https://bashly.dannyben.com/), one subfolder per project (e.g.
  `bashly/mytool/`). Generated executables are committed to git so `bin/`
  symlinks work without requiring bashly to be installed. Each project's
  generated executable is symlinked into `bin/`.

  Should another CLI-generator framework be used later, it gets its own
  sibling wrapper folder (e.g. `argbash/`) rather than being mixed into
  `bashly/`.

## Makefile

Run `make help` for the full target list. The two you'll use day to day:

- `make bin/x` — the make way to get one `bin/` entry built and linked.
  For a bashly project, regenerates `bashly/x/x` first if its `bashly.yml`
  or `src/` changed (a no-op otherwise), then (re)links `bin/x`. For a
  `plain/` script, just links it.
- `make all` — the same, for every `bin/` entry at once.

Plus `bashly-build` (regenerate every bashly project, without touching
`bin/`) and `build` (currently just depends on `bashly-build`), `bin`
(creates the `bin/` directory if it's missing -- an order-only prerequisite
of every `bin/x` link, so it's created automatically as needed), `clean`
(remove every `bin/` link, including broken ones from removed
scripts/projects, and every generated bashly executable -- undoes
`all`/`build`), `lint-plain`/`lint-bashly` (and `lint`, depending on both),
`new-plain NAME=x`, `new-bashly NAME=x`, and `dump-VAR` (debug helper, e.g.
`make dump-BIN_TARGETS`).

`bashly` is invoked via the `BASHLY` make variable: it uses this repo's own
`.local/bin/bashly` if that's an executable (or a symlink to one) --
gitignored, so drop your own bashly binary/symlink there -- and otherwise
falls back to a dockerized bashly (`dannyben/bashly`, mounting the current
directory and running as your uid/gid) — run `make help` to see which one
is currently active. Override per call if neither fits, e.g.:

```
make BASHLY='bashly --some-flag' build
```

`shellcheck` (used by `lint`) follows the same convention via a `SHELLCHECK`
variable (default: `shellcheck`), overridable the same way, e.g. to run a
dockerized shellcheck instead.
