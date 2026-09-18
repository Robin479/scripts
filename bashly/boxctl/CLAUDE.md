# CLAUDE.md — bashly/boxctl

Project-specific guidance for the `boxctl` bashly project, layered on top of
the repo-root `CLAUDE.md` (which covers the `make`/`bin`/`bashly` build
machinery, including `bashly/.template/` — the scaffolding template
`make new-bashly` instantiates for every new bashly project, not specific to
boxctl).

## Purpose

Grab-bag CLI for local machine maintenance/setup tasks that don't warrant
their own project (cache-dropping, installing tools not packaged in the
default system repositories, etc).

## `install` subcommand conventions

`boxctl install` is a command **group**, one leaf subcommand per tool
(`install xidel`, `install calibre`, ...) — not a single `install <tool>`
command with an enum arg. It started as the latter, but was promoted once
a tool actually needed its own flag (calibre's `--version`, xidel's
`--dev`) that doesn't apply to the others; bashly flags are scoped to one
command, so tool-specific options need tool-specific subcommands. **Add
new tools as new subcommands from the start**, not by growing a shared
enum arg again.

Each tool's logic lives in its own `src/lib/install_<tool>.sh`, exposing
exactly four functions, named `boxctl::install_<tool>_*`:

- `_check` — dependency checks only. **Never a root check here** — see
  "Root handling" below.
- `_installed_version` — sets `INSTALLED_VERSION` (empty string, not
  unset, if the tool isn't installed). Best-effort: xidel reads
  `dpkg-query`; calibre (not dpkg-managed) scans `/opt/calibre-*` and takes
  the highest via `sort -V`.
- `_available_version` — sets `AVAILABLE_VERSION` plus whatever `_install`
  will need (`DOWNLOAD_URL`/`FILENAME`/etc). **Must not require root**, and
  should avoid a full download if at all possible — xidel used to download
  the whole `.deb` just to read its `Version` field via `dpkg-deb`; it now
  parses the version straight out of the SourceForge feed's filename
  instead (`xidel_<version>-<build>_amd64.deb`). Confirmed directly: the
  filename's trailing `-<build>` packaging counter is *not* part of the
  installed package's actual `Version` field — `dpkg-query` reports plain
  `<version>`, same as `_installed_version` above reads — so `_available_version`
  strips it too, keeping the two comparable without downloading anything.
- `_install` — performs the actual install/upgrade, using state the two
  functions above set. This is the one function allowed to need root.

The leaf command file (`src/install_<tool>_command.sh`) is a thin
dispatcher: read `args`, call the four functions above in order, decide
whether to actually install. **Keep that decision logic in the command
file, not the lib** — the lib functions are pure building blocks reused
identically regardless of what a future subcommand's own flags decide to
do with them.

### `--update`/`-u`

Deliberately **not** pip's `-U` semantics, by explicit direction — pip's
`install <pkg>` (no `-U`) silently no-ops when already installed, without
even checking for a newer version; `-U` always converges to latest
regardless of prior state, no in-between. `boxctl install <tool>` instead
has a real third state:

- **Not installed**: always install the latest (or whatever `--version`/
  `--dev` asked for), regardless of `--update`.
- **Installed, `--update` not given**: never installs or upgrades
  anything — looks up `AVAILABLE_VERSION` anyway and, if it differs from
  `INSTALLED_VERSION`, reports it and tells the user to pass `--update`.
  This proactive nudge (not just silence) is the whole point — confirmed
  directly as the preferred behavior over pip's silent-skip: it tells you
  an update exists without ever taking the update-or-install action on its
  own initiative.
- **Installed, `--update` given**: resolves and installs/upgrades — but
  still no-ops with a plain "already installed" message if
  `AVAILABLE_VERSION` turns out to equal `INSTALLED_VERSION` (asking for
  latest when you're already on latest isn't an error).
- **Installed, explicit version pin given** (calibre's `--version=X.Y.Z`):
  always reinstalls, even when `X.Y.Z` equals `INSTALLED_VERSION` —
  confirmed directly as the preferred behavior: pinning to the exact
  version you already have is a deliberate repair/reinstall request, not
  an "am I up to date" check, so it must not be swallowed by the
  already-latest no-op that `--update` gets. The command file distinguishes
  this from `--update` by checking the raw `--version` flag value, not the
  `--update`-aliased-to-`--version=latest` one used for the actual install
  call (`explicit_version` vs. `version` in `install_calibre_command.sh`).

A tool with its own version-pinning flag (calibre's `--version=X.Y.Z`)
should treat *any* explicit version request the same as `--update` for
this purpose — "if `--version` is given, a missing `--update` can be
ignored" (explicit direction) — and should make `--update` a literal
alias for `--version=latest` in code, with the two flags declared
`conflicts:` on **both** sides in `bashly.yml` (bashly's own native
mutual-exclusion check, not a hand-rolled bash one) so e.g.
`install calibre --update --version=1.2.3` is rejected before the command
script even runs, regardless of whether the pinned value happens to equal
`latest` too.

## Root handling (`src/lib/boxctl.sh`)

**Never hard-require root upfront** (no "must be run as root" check in
`_check`). Instead, `boxctl::run_as_root <command...>` — runs the command
directly if already root, otherwise prints a generic notice built from
`"$*"` (naming the actual command, not a per-call custom message — by
explicit direction, to keep the wrapper trivial to reuse) and re-runs it
via `sudo`. Wrap **only** the specific commands that actually need root,
as close to the point of use as possible — e.g. xidel's
`_check`/`_available_version` need no root at all (only `apt-get install`
in `_install` does); calibre needs it for extracting into `/opt`, running
`calibre-uninstall`, and running `calibre_postinstall`, each wrapped
individually. When two root-needing steps are tightly coupled (calibre's
`mkdir -p "$INSTALL_DIR"` + `tar xf ... -C "$INSTALL_DIR"`), combine them
into one `boxctl::run_as_root bash -c '...' _ "$arg1" "$arg2"` call (using
`_` as the inner script's `$0` and passing real args positionally, not
interpolated into the string) rather than two separate `sudo` calls —
fewer password prompts, and avoids the quoting hazard of building a
`bash -c` string via interpolation instead of positional args. This also
means a plain `boxctl install <tool>` version-check (`--update` not given,
nothing to actually install) generally needs **no root at all** — only an
actual install/upgrade does.

## Adding a new tool

1. `src/lib/install_<tool>.sh` with the four `boxctl::install_<tool>_*`
   functions above.
2. A leaf command under `install:` in `bashly.yml`, **alphabetically
   sorted** among the existing tool subcommands (explicit direction — so
   `install --help` reads alphabetically), with only that tool's own
   flags.
3. `src/install_<tool>_command.sh` dispatching to the lib functions and
   implementing the `--update` decision above.
