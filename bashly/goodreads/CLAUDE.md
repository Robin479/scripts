# CLAUDE.md — bashly/goodreads

This file provides project-specific guidance to Claude Code for the `goodreads`
bashly project. It's layered on top of the repo-wide `CLAUDE.md` at the repo
root, which covers the `make`/`bin`/`bashly` build machinery.

## Purpose

`goodreads` interacts with the goodreads.com website: scraping book details,
reflecting on reading challenges (identifying current challenges and
selecting books to read towards their goals), and managing shelves and
reading progress.

Status: `auth` (login-session management), the book metadata cache
(schema.org JSON-LD + our own fields), the blog post cache, and reading
challenges (manually curated, see below) are all implemented, each with a
CLI surface — `auth`, `blogs` (`blogs
fetch`/`list`/`get`/`remove`/`challenge`), `books` (`books
fetch`/`list`/`get`/`remove`), and `challenges` (`challenges
create`/`list`/`get`/`edit`/`remove`, plus `challenges
blogs`/`badges add`/`remove`). Shelves and reading progress are not
designed yet, nor is the actual challenge-*goal* book-selection logic
(picking specific books toward a badge) — `challenges` only manages a
challenge's own metadata (title, time window, badge-linked blog posts,
book-count badges), see its own section below. The blog post cache exists
specifically as groundwork for reading-challenge support: challenge detail
data (which books count toward which badge) turned out to be locked behind
a step-up-auth requirement no long-lived session can satisfy (see "Blog
post cache" below), so the plan is a human-in-the-loop workflow — scrape
and flag candidate blog posts, let the user confirm which challenge they
belong to — rather than fully automated association.

## Architecture

- **Interaction stack**: `curl` for HTTP, `xidel` for HTML/XML parsing and
  extraction, `jq` for JSON handling. No other scraping/HTTP libraries. All
  HTTP GETs go through `gr::http_get <url>` (`src/lib/http.sh`) — never call
  `curl` directly for a GET. It prints the response body to stdout and
  nothing else (caller decides how to handle it: redirect to a file,
  capture into a variable, pipe onward). It fails — before touching the
  network at all — if `--offline` was given (this is the **one and only**
  place that checks `gr::offline`; nothing that calls `gr::http_get`
  transitively, like `gr::refresh_book`, needs its own check anymore), and
  otherwise fails like curl's own `--fail` (`-sLf`): non-2xx and transport
  errors both return non-zero with no body, rather than "successfully"
  emitting an error page. **Handled**: AWS WAF (fronting goodreads.com) can
  respond with HTTP 202 + empty body + an `x-amzn-waf-action: challenge`
  header when it decides traffic looks bot-like — curl's `--fail` does
  **not** catch this (202 is a "success" status), so a naive implementation
  reports success with empty output. Confirmed three times, concretely: a
  144-book bulk fetch (paced 0.7s apart) got real content for exactly 2
  books then empty for the rest; two follow-up batches (same pacing) got 3
  real then empty, each time — a burst allowance (seemingly ~3 requests)
  then a hard block that lasts well beyond any reasonable built-in retry
  window, not a fixed request count, and evidently with some memory across
  attempts (a fresh batch doesn't get a fresh full allowance). `gr::http_get`
  now retries on this specific condition (2xx **and** empty body — a
  distinct branch from the real-failure `--fail` case) with a backoff read
  **fresh from the `http_retry_delays` config key on every call**
  (`gr::config_get http_retry_delays "$GR_HTTP_RETRY_DELAYS_DEFAULT"` —
  comma-separated seconds; default lives in `GR_HTTP_RETRY_DELAYS_DEFAULT`,
  same default-in-a-constant-plus-config-key pattern as
  `book_cache_ttl`/`GR_BOOK_CACHE_TTL_DEFAULT`) before giving up. Default
  history: `5,15` (~20s total) proved too short — the block outlasts that
  easily; `10,30,90` (~130s) was a deliberately modest middle ground,
  reasoning that this is a low-level primitive also used by `auth status`'s
  live check, which "shouldn't hang for minutes by default." That reasoning
  was explicitly revisited and overridden: scraping in general got more
  expensive (this project has now hit AWS WAF's throttling repeatedly, see
  above), so the default was deliberately raised to **`20,100,480` (600s /
  10 minutes total)** — patience now matters more than a fast failure, even
  for `auth status`. If that 10-minute worst case ever becomes a real
  problem for a specific caller, the fix is `gr::config_set
  http_retry_delays "..."` (or `COOKIE_JAR`-style per-call scoping if that
  becomes worth building) for that caller's own run, not reverting the
  global default back down. Verified with a stubbed `curl`: a
  `gr::config_set http_retry_delays "1,2"` override is picked up
  immediately (next call, no restart needed) and produces exactly 3
  attempts over ~3s — confirms the config plumbing itself is correct
  regardless of which literal numbers are the current default.

  **The curl binary itself is auto-detected via a priority cascade,
  `gr::init_curl_cmd` (`lib/http.sh`), shared by `gr::http_get`/
  `gr::http_status`** — added to let
  [curl-impersonate](https://github.com/lwthiker/curl-impersonate) (a
  patched curl/libcurl build that replicates a real browser's exact TLS
  handshake — cipher suites, extension order, GREASE values — and HTTP/2
  frame settings) be used automatically when available, addressing AWS
  WAF's TLS/JA3-fingerprint detection layer specifically — confirmed via
  outside research that plain curl's own TLS signature is immediately
  recognizable as non-browser, a layer entirely separate from (and not
  fixed by) the empty-body retry handling above. **Not a full fix** — the
  research also confirmed no plain HTTP client, curl-impersonate
  included, can pass AWS WAF's actual JS challenge (there's no JS engine
  to mint the `aws-waf-token` cookie); this only reduces how often the
  *heuristic* layers trigger a challenge in the first place, the same
  category as the fake book-slug/throttle-spacing mitigations already in
  place, not a replacement for the retry backoff. Priority order, per
  explicit direction:

  1. The `curl_bin` config key, if set at all — an explicit choice always
     wins over auto-detection, whatever it is (a single binary name, or a
     full multi-word command line — see the Docker case below).
  2. The first of `GR_CURL_IMPERSONATE_CANDIDATES` (curl-impersonate's own
     wrapper script names, newest/most-common Chrome build first, then
     Edge, then Firefox, then Safari last — Safari's wrappers are only an
     *approximation* via the Chrome/BoringSSL binary, curl-impersonate
     never got a genuine Safari/Apple-TLS port) found on `$PATH`.
  3. A `docker run` command **auto-crafted fresh each process** (not a
     static config string) around `GR_CURL_IMPERSONATE_DOCKER_IMAGE`'s own
     `GR_CURL_IMPERSONATE_DOCKER_WRAPPER`, if `docker` is on `$PATH` *and*
     its daemon actually answers (`docker info`, not just the binary
     existing).
  4. Plain `curl` (`GR_CURL_BIN_DEFAULT`), if that's on `$PATH`.
  5. A hard error — `error: no usable curl found -- install curl,
     curl-impersonate, or Docker` — nothing usable found at all.

  `-A "$GR_USER_AGENT"` is added only when the resolved command is
  literally plain `curl` (cases 1 or 4 landing there) — any impersonate
  target already bakes in its own matching User-Agent (calibrated to
  agree with the fake TLS handshake it produces) plus a full set of other
  Chrome-shaped headers, and layering a *different* User-Agent on top
  would itself create the kind of mismatch bot detection looks for.

  **Memoized for the lifetime of the process** (`$GR_CURL_CMD_RESOLVED`),
  resolved lazily on the first actual call rather than unconditionally at
  startup — most commands (`books list`, anything under `--offline`, ...)
  never touch the network at all, so there's nothing to gain probing
  `$PATH`/Docker up front. **This memoization does not survive a
  subshell**, which mattered in practice: `gr::run_fetch`'s own per-item
  loop (see "books"/"blogs commands" above) calls each item's `fetch_fn`
  via `$(...)` specifically to capture its outcome text — meaning every
  single item runs in its own freshly-forked subshell, and a variable set
  *inside* one of those (like `GR_CURL_CMD_RESOLVED=1`) is discarded the
  moment that subshell exits, never reaching the parent process. Found by
  testing directly, with a stub `docker` that logs every invocation: a
  4-book `fetch` ran the full `docker info` resolution check **four
  times**, once per book, instead of once for the whole run. Fixed by
  having `books_fetch_command.sh`/`blogs_fetch_command.sh` each call
  `gr::init_curl_cmd` once themselves, *before* their own `gr::run_fetch` call
  (guarded by `gr::offline ||`, so an all-`--offline` run skips the probe
  entirely) — a subshell forked *after* that point inherits the
  already-resolved arrays via ordinary shell-forking semantics (a
  same-process fork copies all current shell state, unlike a genuinely
  separate `exec`'d process, which would only see `export`ed — and,
  critically, never array — variables). Re-verified with the same stub:
  exactly one `docker info` call across a 4-book run, four separate
  `docker run` calls (the real per-item fetches) alongside it.

  **`curl_bin` also has to support a full command line, not just one
  binary name** — e.g. `docker run --rm -u 1000:1000 -v
  /home/kai/.goodreads:/home/kai/.goodreads
  lwthiker/curl-impersonate:0.6.1-chrome curl_chrome116` — so it's
  whitespace-split via `read -a`, not treated as one literal token
  (that used to be a real bug: a multi-word string would try to exec a
  single, nonexistent binary whose name contained spaces). Plain
  whitespace-splitting, not `eval`, is good enough for a docker-run-style
  command line, and this is the user's own local config, not adversarial
  input, so there's no injection concern either way.

  **Docker specifics, all confirmed directly**: `lwthiker/curl-impersonate
  :latest` is the **Firefox** build (`curl_ff*` wrappers only, no
  `curl_chrome*` at all) — the Chrome build needs the exact
  `0.6.1-chrome` version+flavor tag instead, hence
  `GR_CURL_IMPERSONATE_DOCKER_IMAGE`'s own value. A bind mount is
  required for cookie persistence — without one, `--rm` discards the
  container's entire filesystem (including whatever `-c`/`-b` cookie jar
  path curl wrote inside it) the moment the request finishes, so the host
  jar just silently stays empty forever, no error at all. The mount has
  to land at the *same absolute path* inside the container as on the host
  (`-v <data_dir>:<data_dir>`) so the literal `$COOKIE_JAR` string curl
  receives resolves correctly on both sides — this is why the command is
  crafted fresh per process from `gr::data_dir` rather than being a
  static string, unlike a hand-written `curl_bin` override, which can't
  adapt to whatever `--data-path` a given run actually uses. A second,
  independent gotcha: the container runs as **root** by default, so
  anything it writes into that mount comes back root-owned on the host,
  unreadable by the invoking user afterward — same problem this repo's
  own `Makefile` already solved for its dockerized-bashly fallback
  (`-u $(id -u):$(id -g)`, confirmed identical fix needed here).

  **Installing curl-impersonate locally** (case 2 above): prebuilt
  release binaries (no build toolchain needed) — e.g.
  `curl-impersonate-v0.6.1.x86_64-linux-gnu.tar.gz` from the project's
  GitHub releases — ship both a real binary (`curl-impersonate-chrome`)
  and browser-version-specific wrapper scripts (`curl_chrome116`, etc.)
  that call it with the right ciphers/headers/HTTP2 flags baked in; the
  wrapper finds its sibling binary via `$0`'s own directory, so both files
  must be extracted into the same directory — and, for `gr::init_curl_cmd` to
  actually find one this way, that directory needs to be on `$PATH`
  (unlike `curl_bin`, which takes an exact path/command, `$PATH`-based
  detection only ever checks bare command names via `command -v`). A copy
  was installed at `.local/bin/` at the repo root for testing (gitignored,
  same "local-machine-specific tool override, never committed" convention
  the top-level `CLAUDE.md`'s own `.local/bin/bashly` already
  establishes) — **not on `$PATH` by default**, so it's exercised via an
  explicit `curl_bin` config value in practice, not case 2's
  auto-detection, unless `.local/bin` is separately added to `$PATH`.
  Verified directly: `curl_chrome116 --version` reports BoringSSL
  (Chrome's actual TLS library, not OpenSSL), and a real fetch through it
  returns real book data — and, to confirm a configured value is
  genuinely what's driving the invocation and not silently falling back,
  pointing `curl_bin` at a nonexistent path produces a clear "No such
  file or directory" failure from that exact path.

  Set it via `goodreads config set curl_bin <value>` (see "Config file"
  below) — back to auto-detection via `goodreads config unset curl_bin`.

  **Minimum request spacing** (`gr::throttle <url>`, called right before
  every actual `curl` invocation in `gr::http_get` — including retries, not
  just the first attempt): sleeps if needed so that returning from this
  function never happens sooner than a random point between
  `http_request_delay_min` and `http_request_delay_max` seconds (config
  keys, seconds; defaults 3/10, in `GR_HTTP_REQUEST_DELAY_MIN_DEFAULT`/
  `GR_HTTP_REQUEST_DELAY_MAX_DEFAULT` — renamed from the original
  `min_request_delay`/`max_request_delay` to match the `http_`-prefixed
  naming already used by `http_retry_delays`) after this same function's
  own *previous* return — a separate, always-on mechanism from the
  WAF-challenge backoff above, meant to avoid triggering that
  burst-then-block behavior in the first place rather than recovering from
  it.

  **Briefly lowered to 1/5, then reverted — real-world evidence
  contradicted the earlier test result.** Two real 10-book batches at 1/5
  (once the fake-slug URL, see below, was already in place) had both
  completed with zero WAF challenges, which read as evidence the fake
  slug was doing the real work and the wider spacing was unnecessary. Not
  conclusively isolated even then (both changes had landed close
  together), and the user subsequently reported apparently being
  blacklisted after running with 1/5 for real — enough to treat the
  earlier two-batch result as **not representative** (too small a sample
  against a heuristic, possibly IP-reputation-based system, not a stable
  finding) rather than chase it further. Reverted straight back to the
  original 3/10 rather than something in between or more conservative
  still, per explicit direction — no further tightening planned without
  new evidence it's actually safe.
  The target URL is passed in ($1) but currently unused (it used to
  appear in a log message, no longer — see just below) — a hook for
  possible future per-host pacing, not implemented. State (the
  last-return timestamp) is a plain integer-seconds file at
  `.last_request_at`, root of the data directory (see "Data directory"
  below) — deliberately on disk, not a shell variable, since each
  `goodreads` invocation is its own process and pacing needs to hold across
  separate invocations, not just calls within one. No locking: this is a
  single-user CLI tool, concurrent invocations racing each other isn't a
  scenario worth guarding against. Verified directly: a fresh state file
  lets the first call through immediately; a second call shortly after
  waits out the remaining part of a real (short, config-set) window; a
  call made after the window has already elapsed on its own (e.g. a
  separate process invoked later) also returns immediately — and the
  timestamp read via a brand-new process confirms the file (not a
  variable) is really what's being read.

  **`gr::throttle`'s own wait is deliberately silent — it used to print
  `"throttling request to <url> — waiting Ns before continuing"` every
  time, and that was removed, per a direct user report.** This is
  routine, by-design pacing that fires on nearly *every single* request
  at its default few-second spacing — not an anomaly worth announcing,
  unlike `gr::http_get`'s own WAF-retry warning (above), which is rare and
  can run to minutes. During a `fetch` command's self-updating status
  line (see "`books`/`blogs` commands", below), that routine message
  printing every time turned into exactly the "wall of text" the status
  line was built to replace — confirmed directly: a user restarted a
  `fetch --update` run right after the WAF-retry fix below shipped, and
  instead of a hung-looking single line got a scrolling pile of
  `throttling request to ...` lines instead, one per book, since each
  one's routine multi-second wait almost always exceeds how long the
  actual fetch itself takes. Silenced outright rather than routed through
  the status line itself — `gr::throttle` has no way to know whether one
  is even active, being generic and used by plenty of single-shot callers
  with no status line at all (e.g. `auth status`'s live check).

  The cookie jar is **not** a parameter — it's read from the `COOKIE_JAR`
  environment variable, set as a one-off prefix on the call:
  `COOKIE_JAR=path/to/cookies.txt gr::http_get "$url"`. `gr::http_get`
  itself does **not** pick a default when `COOKIE_JAR` is empty — it just
  makes a cookie-less request in that case; default-selection is
  deliberately not its job. That default instead lives in
  `gr::init_cookie_jar` (`src/lib/http.sh`, alongside `gr::generic_cookie_jar`
  — kept with `gr::http_get` since both are entirely about it, not generic
  enough for `goodreads.sh`): it sets the real
  (non-local) global `COOKIE_JAR` to `gr::generic_cookie_jar` unless already
  set to something else, and is called exactly **once**, globally, from
  `before_hook()` (`src/before.sh`, via bashly's `hooks` library — `bashly
  add hooks`) — so it's already set by the time *any* command runs, not
  something each account-less consumer (`gr::refresh_book`, and future ones)
  needs to remember to call itself. Confirmed the bashly-documented reason
  this is the right hook: bashly's `initialize()` hook runs *before*
  argument parsing (too early — `gr::data_dir` needs `--data-path` parsed),
  while `before_hook()`'s own doc header explicitly says it runs "before
  running any command (but after argument processing is complete)", with
  `args` already available — exactly the timing this needs. Verified via
  `bash -x` on the generated script that `before_hook` → `gr::init_cookie_jar`
  → `gr::generic_cookie_jar` → `gr::data_dir` all fire correctly, in that
  order, before any command's own logic runs. `gr::generic_cookie_jar`
  itself is a shared, account-less jar at the data directory root
  (`cookies.txt`, auto-created empty on first use), separate from any
  account's own `accounts/<id>/cookies.txt`.
  `gr::identify_account_from_cookiejar` instead uses an explicit
  `COOKIE_JAR=` prefix (its account's own jar) on each call — that per-call
  override is exactly what the env var is for, distinct from
  `gr::init_cookie_jar`'s "establish the account-less default once" job.
  `src/initialize.sh` and `src/after.sh` (also installed by `bashly add
  hooks`) were deleted — bashly's own doc comments say each hook file is
  safe to delete if unused, and we only need `before.sh`.
- **Shared library layout** (`src/lib/*.sh`, all sourced automatically by
  bashly): `goodreads.sh` holds truly generic bits used by everything
  (`gr::data_dir`, `gr::offline`, `gr::config_*`); `http.sh` holds everything
  HTTP-request-specific — all `readonly` constants grouped at the very top
  (`GR_USER_AGENT`, `GR_CURL_BIN_DEFAULT`, `GR_CURL_IMPERSONATE_CANDIDATES`,
  `GR_CURL_IMPERSONATE_DOCKER_IMAGE`/`GR_CURL_IMPERSONATE_DOCKER_WRAPPER`,
  `GR_HTTP_RETRY_DELAYS_DEFAULT`,
  `GR_HTTP_REQUEST_DELAY_MIN_DEFAULT`/`GR_HTTP_REQUEST_DELAY_MAX_DEFAULT` — this is the
  convention to follow for any new constant added here, not scattered next
  to whichever function happens to use it), then `gr::generic_cookie_jar`/
  `gr::init_cookie_jar`, then `gr::throttle`, then `gr::http_get`;
  `goodreads_auth.sh` holds the
  account/session functions; `goodreads_books.sh`
  holds the book-cache functions; `goodreads_config.sh` holds the
  `config` command group's own user-facing registry (`GR_CONFIG_KEYS`,
  `gr::config_describe`, `gr::config_default_display`) — deliberately its
  own file rather than folded into `goodreads.sh`'s generic `gr::config_*`
  wrappers, since it's specific to the `config` CLI commands, not
  something every area needs; `config.sh`/`ini.sh` are bashly's own
  library (`bashly add config`), untouched, wrapped rather than modified so
  `bashly add config` can still refresh them later. Split by topic as each
  area was built — follow the same pattern for future areas (shelves,
  progress, challenges) rather than growing one file.
- **Local state**: cached data lives in typed `*.json` files (and possibly
  other formats) in a database-like directory structure under the data
  directory (see below).
- **Login sessions**: some actions require being logged in to goodreads.com,
  others don't — this is implicit to each action, not something the caller
  specifies. Whether an action needs a session is transparent/handled
  internally by that action's implementation, via `gr::require_current_account`
  (`src/lib/goodreads_auth.sh`) — a future login-requiring command just calls
  it and gets back the current account id or a clear error.
  - A logged-in session is represented by a cookie file.
  - There is a notion of a "current account", managed by the `auth`
    subcommands (below). Establishing a session (`auth import`) always
    *identifies the account from the session itself* — never from user
    input — and makes it current.
  - Session-specific data (shelves, reading progress, etc.) and that
    session's cookie file live together in an account-specific subfolder
    under the data directory — i.e. the data directory is partitioned per
    account, not just a flat cache.

## Global flags

- `--data-path` — see "Data directory" below.
- `--offline` — skip live network checks and use only cached data. Currently
  affects `auth status`'s session-validity check (`gr::cookies_state`); any
  future command that does a live "is this still good" check should respect
  it the same way.

## Data directory

Resolved by `gr::data_dir` (`src/lib/goodreads.sh`), in order: the
`--data-path` global flag, else `$GOODREADS_DATA`, else `~/.goodreads`.
Layout:

```
$data_dir/
  config.ini                # INI-format config file (bashly's config library — see below)
  cookies.txt               # generic/account-less cookie jar — see gr::http_get above
  .last_request_at          # last-return timestamp for gr::throttle — see gr::http_get above
  current                  # plain text: id of the current account. Absent = none selected.
  accounts/
    <id>/
      cookies.txt           # curl/Netscape-format cookie jar. Absent/removed = logged out.
      profile.json           # {"id", "username", "profile_url", "identified_at"}
      shelves/ ...            # future
      progress/ ...            # future
  books/
    <id>.json                # one-line JSON cache of book <id>'s data — see below
```

**Config file** (`config.ini`, root of the data directory — `.ini` to match
bashly's own default `CONFIG_FILE` name, since we're otherwise using its
library as-is): installed via bashly's own built-in library (`bashly add
config`, which pulled in `src/lib/config.sh` + `src/lib/ini.sh` —
untouched, so a future `bashly add config` can still refresh them). That
library's own functions
(`config_get`/`config_set`/`config_del`/`config_show`/`config_keys`) work
off a global `CONFIG_FILE` variable that's normally set once via a hook —
but bashly's `initialize()` hook runs *before* argument parsing, so
`--data-path` isn't resolved yet at that point and a one-time global doesn't
work here. Instead, `gr::config_get`/`gr::config_set`/`gr::config_del`/
`gr::config_keys` (`src/lib/goodreads.sh`) wrap the real ones and set
`CONFIG_FILE="$(gr::data_dir)/config.ini"` on every call — always call these
`gr::`-prefixed wrappers, never `config_get`/`config_set`/etc. directly, or
`--data-path` gets silently ignored.
Keys are dotted (`section.key`) INI-style;
`gr::config_get key.name [default]` / `gr::config_set key.name value`.

**Exposed via `goodreads config {list,get,set,unset}`** (`unset`, not
`remove`/`rm` like every other command group's own deletion verb — a
setting reverting to its default reads more like `git config --unset`/
`env -u` than "removing" something). `GR_CONFIG_KEYS`
(`src/lib/goodreads_config.sh`) is the single user-facing registry of
every key goodreads itself actually reads — deliberately kept separate
from where each key's real default is asserted (`http.sh`'s
`GR_HTTP_REQUEST_DELAY_MIN_DEFAULT`, etc., `goodreads_books.sh`'s
`GR_BOOK_CACHE_TTL_DEFAULT`), so this file is purely a catalog, not a
second source of truth for behavior — `gr::config_describe`/
`gr::config_default_display` (case statements, not a second array kept
parallel to `GR_CONFIG_KEYS`, so a key present in one but not the other
fails loudly instead of silently misaligning by index) drive `config
list`'s pretty-print of each key's description and effective default.
`config set` on a key outside this registry still works (a plain,
generic `gr::config_set` passthrough underneath) but prints a `note:` to
stderr first — deliberately a warning, not a hard error, since the
registry is just a documentation aid, not a schema the underlying INI
file itself enforces. `config unset --all` clears every key currently
*set* (via `gr::config_keys`, the real on-disk keys — not every key in
`GR_CONFIG_KEYS`, most of which are normally never set at all, sitting on
their default instead).

Tab-completion for the `key` argument is a plain static word list (`get`/
`unset`), not derived from `GR_CONFIG_KEYS` at completion-time — the
generated completions script doesn't source the app's own libs (see the
dynamic id-completion entries elsewhere in this file), so it's a literal,
hand-kept-in-sync duplicate instead. **`config set`'s own `key`/`value`
args deliberately have no completions at all** — confirmed directly that
a command-level `completions:` block in `bashly.yml` applies to *every*
positional argument of that command, not just the one it conceptually
describes (`goodreads config set <TAB>` and the `value` slot after it
both resolved to the same candidate node in the generated script), so
attaching one here would incorrectly offer key names as candidate
*values* too.

The directory key is the **numeric id only**, never `<id>-<username>`.
Goodreads usernames can change; the username is still captured in
`profile.json`, just never used as a filesystem/storage key. Re-running
account identification (re-`auth import`) refreshes `profile.json` without
touching the account's directory name or any already-cached data.

**Every command group's own `list` is its `default: force` command in
`bashly.yml`** (`auth list`, `blogs list`, `books list`, `challenges
list`) — per explicit direction, "make list the default in all groups."
`default: force` (not plain `default: true`) is the one that actually
runs the command when the group is invoked bare with *no* further
tokens at all, not just when an unrecognized one follows (confirmed
directly against the local bashly source at the exact version this
project builds with, `v1.4.0` — `examples/command-default-force/` there
demonstrates precisely this; plain `default: true`'s own example only
covers the "unrecognized token falls through" case, not "invoked with
nothing"). So `goodreads books`, `goodreads blogs`, `goodreads
challenges`, and `goodreads auth` each now behave exactly like their own
explicit `... list` — safe here since none of the four `list` commands
have any *required* argument that bare invocation could leave unsatisfied.
`--help` at the group level is unaffected either way (still shows the
normal command listing, marking the default one `(default)` in its own
summary) — only a bare, help-less invocation is redirected. Top-level
bare `goodreads` (no group at all) is untouched — no top-level command
carries `default: force`, so that still shows the root help as before.

**Tab completion filters a short-form alias (`ls`/`rm`/`new`) out of the
candidate list whenever its own long form is *also* a candidate at that
same position** — per explicit direction: bashly's own generated
completion script (`send_completions`, `lib/send_completions.sh` —
fully bashly-generated/vendored, never hand-edited, confirmed via each
generated file's own `# generated by bashly <version>` header) always
lists a command's long form and its alias as two equally-weighted plain
words in the same `compgen -W "..."` candidate string, so a bare TAB
(nothing typed yet) lists both side by side — checked directly against
the local bashly source at the version this project actually builds
with (`v1.4.0`); there's no YAML-level key to suppress an alias from
this, in either this version's "completely"-DSL generator or the newer
2.x pattern-based one. **`src/completions_command.sh`** (a normal,
hand-edited per-command file, *not* itself part of the generated
artifact — only its one line calling `send_completions` is) is where
this gets fixed, by appending extra script text after that call:
declares `_goodreads_alias_pairs` (the 3 unique `long:short` pairs in
this project — `list:ls`, `create:new`, `remove:rm`, each appearing at
several different command levels but only ever needing to be listed
once) and a wrapper, `_goodreads_completions_filtered`, that runs the
real `_goodreads_completions` first and then drops a pair's short form
from `COMPREPLY` whenever its long form also ended up in that same
result — then re-registers `complete -F` to point at the wrapper
instead. This is deliberately **not** scoped by command path at all: a
pair only ever matters when both of its forms are simultaneously valid
candidates for whatever's actually being completed right now, so a flat,
unscoped list works correctly everywhere it's declared (`challenges
badges remove`'s own `rm` alias and `blogs remove`'s own `rm` alias never
interfere with each other — each position's own `COMPREPLY` only ever
contains whatever's valid *there*). Verified directly against the real
`eval "$(goodreads completions)"` output, across multiple command
levels: a bare TAB after `books`/`challenges`/`auth` shows only the long
forms; typing enough of a short form that its long form no longer
matches (e.g. `blogs r` — matches both `remove` and `rm`, `rm` dropped;
`blogs rm` — the 2nd character no longer matches `remove` at all, so
`rm` alone survives) correctly still offers it.

## `auth` commands (implemented)

`auth import <cookie_file>`, `auth status [account]`, `auth list`, `auth
switch <account>`, `auth logout [account]`. No `auth login` — see below for
why. Source: `src/bashly.yml` (command tree + `--data-path` flag),
`src/lib/goodreads_auth.sh` (shared helpers), `src/auth_*_command.sh` (one
per leaf command).

**Why there's no automated credential login:** Goodreads' own "Sign in with
email" is served by Amazon's Login-With-Amazon (LWA) portal
(`goodreads.com/ap/signin/<request-id>`). A real browser's login POST does
**not** send a plaintext `password` field — it sends `encryptedPwd` (a
client-side-encrypted blob) and `metadata1` (an opaque device/behavior
fingerprint), both computed by Amazon's JS. This was verified two ways: (1)
POSTing the visible static-HTML form fields as-is (including a plaintext
`password`) got a generic "Enter a valid email or mobile number" rejection
and got the test account banned; (2) a HAR capture of an actual successful
browser login showed the real field set above instead of `password`.
Reproducing `encryptedPwd`/`metadata1` would mean reverse-engineering
Amazon's client-side encryption and bot-fingerprinting scheme — that's
Amazon's anti-automation layer, not a Goodreads form, and isn't something to
build regardless of whose account it's for. **Don't attempt this again** —
`auth import` (from a real browser-established cookie file) is the only
supported way to start a session.

**Account identification** (`gr::identify_account_from_cookiejar` in
`src/lib/goodreads_auth.sh`): GET the authenticated homepage and extract the
personal-nav profile link. The class `dropdown__trigger--personalNav` alone
is **ambiguous** — it's shared by at least the notifications trigger and the
profile-menu trigger; the profile link specifically also carries
`dropdown__trigger--profileMenu`, which is what the selector actually
matches on:
`(//a[contains(@class,"dropdown__trigger--profileMenu")])[1]/@href` →
`/user/show/<id>-<username>`. Verified directly against a real authenticated
page (via a user-supplied HAR). If this ever stops matching (Goodreads
changing its markup), that's the one selector to fix.

**bashly runs under `set -e` by default** — this bit us during
implementation: any helper that signals "not found"/"nothing yet" via a
non-zero return (e.g. `gr::current_account` when no session exists) must
never be called as a bare `x="$(fn)"` at a call site, since a non-zero
command-substitution status there aborts the whole script immediately,
*before* any `if [[ -z "$x" ]]` check even runs. Fixed by making such
helpers always `return 0` (using `if/fi`, not `test && cmd`, so a false test
doesn't leak a non-zero status — an `if` with no matching branch is itself
exit-0), and by guarding any call that *does* legitimately fail (e.g.
`gr::identify_account_from_cookiejar`) with `if ! x="$(fn)"; then ...`
rather than a bare assignment. Keep this in mind for every future command.

**A `# shellcheck disable=...` comment as the literal first line of a
file suppresses that check for the *entire file*, not just the next line**
— this is documented shellcheck behavior (a directive before any command
in the file applies file-wide), and it silently bit us: the `# shellcheck
disable=SC2154 # args is bashly's global associative array` line every
`auth_*_command.sh` starts with (needed since `args` is bashly's global,
defined in the generated wrapper, not visible to shellcheck linting the
fragment alone) happened to be genuinely the first line in each of those
files, so it was quietly suppressing SC2154 *everywhere* in each file, not
just for the `args[...]` line it was meant to guard. Verified (by
temporarily stripping it and re-linting) that nothing else was actually
being masked, then fixed by adding a leading no-op (`:`) before the
directive in each file, which is enough to make shellcheck treat it as a
normal line-scoped directive again. **Whenever a shellcheck directive is
the first line of a file, check it isn't accidentally suppressing that
check file-wide** — this class of mistake is invisible in `make
lint-bashly` output specifically *because* it's a suppression, not a
warning.

**Session lifetime:** unknown in general, but a real imported session's own
cookie jar tells you directly — curl's Netscape cookie format stores an
expiry unix timestamp per cookie (5th column), so just read it rather than
guessing. On the one real account checked (2026-08-29), Amazon's actual auth
tokens (`at-main`, `sess-at-main`) were valid for about a year; most other
cookies (`session-id`, `ubid-main`, `sst-main`, `x-main`, `lc-main`) matched
that. `_session_id2` (Rails' own short session cookie) was valid for only
hours — but that's a rolling per-visit cookie, not the auth proof, and
doesn't indicate the session itself is short-lived. Don't hardcode any of
this as an assumption; `auth status`'s live check (below) is how the tool
actually finds out, per-account, without predicting a TTL.

**Live session check (`auth status`, default-on):** `gr::cookies_state` in
`src/lib/goodreads_auth.sh` — given an account id, if `cookies.txt` exists it
copies the jar to a temp file and runs `gr::identify_account_from_cookiejar`
against the copy (never mutates the stored jar), reporting `valid`, `expired
or invalid — run 'goodreads auth import' to refresh`, or (if the cookie file
somehow resolves to a *different* account than expected) a mismatch
warning. `--offline` skips the network call entirely and just reports
`present`/`missing` from the cookie file's existence. Always returns 0
(state is encoded in the printed string) — same set-e-safety rule as above.

## Book metadata cache (implemented — CLI surface: `books`, see below)

**Book URLs** (`gr::book_url <id>` → `https://www.goodreads.com/book/show/<id>`):
the trailing title-slug goodreads.com normally shows in book URLs
(`.../199698485-the-god-of-the-woods`) is decorative — confirmed by
fetching both the full-slug URL and the id-only URL for the same book and
comparing: both HTTP 200, identical `<title>`, identical `<link
rel="canonical">` (which itself always carries the full slug regardless of
which form was requested). So always construct book URLs from the id alone.
Book pages don't need a login — fetched with `gr::http_get`'s default
(generic, account-less) cookie jar.

Even though the slug is ignored, `gr::refresh_book` appends a fake one of
its own right before actually fetching — `"$(gr::book_url "$id")-$(gr::random_book_slug)"`
— purely so the request looks like normal browser traffic
(`.../show/<id>-a-blue-box`) instead of a bare numeric id. Deliberately not
done inside `gr::book_url` itself (not every caller necessarily wants a
fake slug attached — keep URL construction and this cosmetic concern
separate). `gr::random_book_slug` (`src/lib/goodreads_books.sh`) builds a
random-but-grammatical three-word phrase: first word is an article
(`a`/`an` — picks whichever fits the adjective that follows — or `the`) or
a spelled-out number (`two`..`twelve`); second word is a generic adjective
(colors and similar generic descriptors, e.g. `red`, `shiny`, `old`); third
word is a noun for a generic object (`box`, `chair`, `lamp`, ...), pluralized
exactly when the first word grammatically requires it (singular after
`a`/`an`/`one`, plural after any other number, either after `the`). Since
`gr::refresh_book`'s own request now always carries this fake slug, its
`.query.book_id` sanity check (below) had to change from an exact match to
comparing only the numeric prefix.

`gr::book_json <id>` (`src/lib/goodreads_books.sh`) is the internal entry
point: emits one-line JSON for a book id, backed by an on-disk cache at
`books/<id>.json`, fresh for `book_cache_ttl` config **seconds** (the
`config.ini` key, via `gr::config_get`/`gr::config_set` — not a section, a
top-level key) — defaults to `GR_BOOK_CACHE_TTL_DEFAULT` (100 days, in
seconds — raised from an initial 7 days once scraping got meaningfully more
expensive due to throttling risk; book metadata doesn't change often enough
to justify refreshing it that eagerly) when unset. Staleness is checked
with a single `find "$book_file"
-newermt "$threshold" 2>/dev/null` against a precomputed `date -d "-N
seconds"` threshold — that one call handles *both* "missing" and "stale" at
once: it prints the path only if the file exists **and** is newer than the
threshold, so empty output means "needs a refresh" either way, with no
separate `[[ -f ]]`/`stat` age check needed. (The bare `find ... || true`
matters: a missing path makes `find` exit non-zero with a stderr message,
which would otherwise trip `set -e` on this assignment — same class of
gotcha as `gr::current_account`, below.) `gr::book_json` **always** asks
`gr::refresh_book` for a refresh when the cache isn't fresh — it does not
check `--offline` itself, and does not fall back to serving stale/missing
data if the refresh call fails for *any* reason. Neither function ever holds
the JSON in a shell variable — `gr::refresh_book` must write straight to a
file, and `jq -c .` is what both re-emits it as the guaranteed-one-line
output *and* doubles as a validity check. The **on-disk cache file itself is
pretty-printed** (`gr::refresh_book`'s final `jq` call has no `-c`) —
deliberately human-readable, so `books/<id>.json` can be opened and read
directly — while `gr::book_json`'s `jq -c .` compacts it back to one line
for actual output; don't add `-c` back to the write side, that's exactly
the split this is for.

`gr::refresh_book <id>` is **implemented**: fetches the book page
(`gr::book_url <id>`, via `gr::http_get` — `COOKIE_JAR` is already the
shared account-less jar by this point, via `before_hook()`, since book pages
don't need a login), then builds the book JSON from three sources:

1. **Our own scraped/derived fields** — `book_id` (the id itself) and
   `canonical_url` (see below for how it differs from `url`).
2. **Goodreads' embedded Next.js page data** (`<script id="__NEXT_DATA__"
   type="application/json">`, extracted into `$apollo_json`) — used for
   three distinct things:
   - **Sanity check**: `.query.book_id` is the literal Next.js route
     parameter used to serve the page — its numeric prefix (up to the
     first `-`) is compared against the requested `id` *before* anything
     gets cached — a prefix, not an exact match, since `gr::refresh_book`
     always fetches through its own fake slug (above), so
     `.query.book_id` itself is really the whole `<id>-<slug>` segment,
     not just `$id`. This is a genuine, real check, not
     defensive-programming-for-its-own-sake: **verified it actually catches
     a real mismatch** — a leftover test fixture that had been fetched via
     the full-slug URL (before `gr::book_url`'s bare-digit convention
     existed) had `.query.book_id` == `"199698485-the-god-of-the-woods"`,
     not `"199698485"`, and the check correctly rejected it (back when the
     comparison was still an exact match, prior to the fake-slug change).
     If the fetched page were ever for some *other* id entirely — wrong
     URL construction, a redirect, a misdirected fetch — this is what
     would catch it before caching under
     the wrong id.
   - **Every apolloState-sourced string that reaches the output is passed
     through `clean_or_null`** (`squeeze_ws`, i.e. collapse whitespace runs
     to one space, plus treat `""` as absent so `drop_nulls` actually drops
     it): `title`, `description`, `contributors[].name`, `series[].name`,
     `work.title`. This wasn't always true — a full anomaly sweep over the
     144-book test corpus (2026-08-31) found real, un-squeezed double-space
     author names surviving all the way to the final output (e.g.
     `"James  Patterson"`, `"Bill  Bryson"`, `"Rachel  Lyon"`), because the
     whitespace/entity cleanup below (**JSON-LD's own cleanup pass**) only
     ever touched the JSON-LD side, never the apolloState side — and since
     the final merge is `$ld[0] * $apollo[0]` (apolloState wins on any
     shared key), even a field JSON-LD *did* clean (like `description`,
     which both sources have) had its clean version silently discarded in
     favor of apolloState's dirty one. `clean_or_null` fixes both classes at
     once, applied directly at each apolloState field's own construction
     site rather than as a separate post-merge pass.
   - **Book-level fields**: `.props.pageProps.apolloState` is a
     GraphQL-normalized cache with one or more `"Book:<opaque-ref>"`
     entries (one per book referenced *anywhere* on the page, e.g. "other
     editions" widgets — a real fetch had 3, only one of them ours). Find
     the entry whose own `.legacyId` matches the requested id, then take:
     `.legacyId` (stored as a **native JSON number**, not stringified — the
     source data's own type, kept as-is in case it ever diverges from
     `book_id` — which stays a deliberate string per this project's usual
     id convention — no known divergence case yet, kept as cheap insurance);
     `.webUrl` (stored as
     **`url`**; this specific edition's own self URL, always matching the
     requested id; see below for how it differs from `canonical_url`);
     `.title` (stored as **`title`** — the *clean* title, with no series
     annotation — see below for why this is a separate field from `name`);
     `.details.publicationTime` (epoch ms, converted to a `YYYY-MM-DD`
     string, stored as `published` — *this edition's* publish date);
     `.bookGenres[].genre.webUrl` (stored as `genres`, a plain array of
     **slug strings** extracted from each genre's URL, e.g. `"harry-potter"`
     from `.../genres/harry-potter` — deliberately not name+url objects,
     the slug alone is enough); `.bookSeries[]`, each entry contributing
     `.userPosition` (stored as `position` — this book's index within that
     series, e.g. `"1"` for the first Harry Potter book; a plain sibling
     field on the `bookSeries` entry itself, no ref to resolve, so bind it
     to a variable *before* piping into the series lookup below or it's
     lost once `.` becomes the resolved `Series:` object) alongside
     `.series.__ref`, resolved to its own apolloState `"Series:..."` entry
     for `{name: .title, series_id, url: .webUrl}` (`series_id` is the
     leading digits of the series `webUrl`, e.g. `45175` from
     `.../series/45175-harry-potter` — same "id is the leading digits of
     the slug" convention as `book_id` itself). Also: `["description({\"stripped\":true})"]`
     (stored as `description` — note the bracket access, since that's the
     GraphQL query-cache key verbatim, not a plain field name; deliberately
     the *stripped* variant, not the plain `description` field, which
     contains raw HTML like `<br />`/`<b>` — consistent with this whole
     pipeline's stance of not leaving markup junk in string values);
     `.details.publisher`/`.details.isbn`/`.details.isbn13`/`.details.asin`.
     `.details.isbn` is stored as `isbn10`, not `isbn` — renamed after a
     real anomaly sweep over the full 144-book test corpus found a
     self-published/POD edition (id `229004405`) where `.details.isbn` was
     itself a 13-digit value **identical** to `.details.isbn13` (Goodreads
     fills it in that way when there's no true ISBN-10), which would have
     been stored as a bogus "10-char" isbn. `isbn10_or_null` (defined
     alongside the other `def`s in this jq program) now drops
     `.details.isbn` unless it's actually exactly 10 characters, so `isbn10`
     is either a real ISBN-10 or absent, never a duplicate of `isbn13`. A
     top-level `isbn` array is also always present (`[]` if neither exists)
     combining whichever of `isbn10`/`isbn13` are non-null — for callers
     that just want "any ISBN this edition has" without caring which kind.
     `isbn`/`isbn13` no longer collide with JSON-LD's own occasional `isbn`
     key the way the old top-level `awards` collision did — `isbn10` avoids
     the name entirely, and `isbn`/`isbn13` still win on merge regardless
     since `$apollo_json` merges last; `.primaryContributorEdge` +
     `.secondaryContributorEdges[]` combined into one `contributors` array
     of `{role, name, url}` (`role` is e.g. `"Author"`/`"Illustrator"`/`"Translator"`
     — JSON-LD's own `author` has no role distinction at all, just a flat
     list). **Deliberately not included**: the rest of each contributor's
     own apolloState entry (a `Contributor:` entry also has a `description`
     field — checked directly, and it's a full prose author biography,
     several KB of HTML for a well-known author like J.K. Rowling — that's
     author metadata, not book metadata, and would bloat every single book
     file; skip it unless a dedicated author-entity feature is built later).
   - **Work-level fields, nested under a `work` sub-object** (the
     *original creative work*, as opposed to this specific edition —
     resolved via the book's own `.work.__ref`; deliberately **nested**,
     not flat-merged like everything else, precisely *because* they're
     scoped to the work rather than the book — mixing them in at the top
     level would blur that distinction): the Work entry's **own**
     `.legacyId` (stored as `work.legacyId`, also a native number — a
     *different* id from `book_id`/top-level `legacyId`, identifying the
     abstract work rather than this edition; without this, nothing in the
     JSON actually says *which* work the rest of `work.*` refers to) and
     `.details.webUrl` (stored as `work.url`); `.details.originalTitle`
     (stored as **`work.title`** — named to match the top-level `title` it
     parallels, not `original_title`, since nesting under `work` already
     says "this is the work's own", making an `original_` prefix
     redundant); `.details.publicationTime` (epoch ms → `YYYY-MM-DD`,
     stored as **`work.published`** for the same reason — parallels the
     top-level `published`; this is the *work's* first publish date, which
     can predate this edition's own top-level `published` by decades — same
     underlying concept, different scope, same field name at each level);
     `.details.awardsWon[]`, each mapped to
     `{award_id, name, url, date, designation, category}` — `award_id` is
     the leading digits of the award's own `webUrl` (e.g. `159` from
     `.../award/show/159-mythopoeic-fantasy-award`), `date` is `.awardedAt`
     (epoch ms → year, see below), `designation` is the source field as-is
     (`"WINNER"`/`"NOMINEE"`), `name` is squeezed for whitespace (source
     data has real cases like `"American Booksellers Book Of The Year
     Award"` with a double space before "Award"), `category` is included
     **only if genuinely present** — the source field is `null` for some
     awards and `""` (empty string) for others, both treated as "doesn't
     exist" and the key dropped entirely rather than kept as a null/empty
     value (a stricter filter than the usual `drop_nulls`, since `""` isn't
     `null` — see `drop_empty`, applied per-award-object, not just once to
     the outer structure; confirmed on Harry Potter's real 30 awards: 14
     have a real category, 16 have none and correctly lack the key
     entirely). All of this stored as `work.awards`. Both id-from-url
     extractions (`series_id`, `award_id`) use a regex `capture(...)`
     wrapped in `try ... catch null`, since a surprising/malformed URL
     should degrade to a missing id rather than
     crash the whole refresh over one field.

     **The top-level `awards` field is left alone** — it comes from JSON-LD
     (below) as Goodreads' own folded string (e.g. `"Mythopoeic Fantasy
     Award Children's Literature (2008), ..."`), and is no longer
     overridden now that the structured version lives at `work.awards`
     instead of colliding with it at the top level. (An earlier version of
     this design put the structured array at a top-level `awards` key and
     had to reorder the merge specifically to make it win over JSON-LD's
     string — that workaround is gone now that the two don't share a key.)

     **Epoch-millisecond timestamps are converted per field, matching each
     field's actual real precision** — `published`/`work.published`
     use the full `YYYY-MM-DD` (`epoch_to_date`: `./1000 | gmtime |
     strftime("%Y-%m-%d")`), since these genuinely carry real day/month
     precision (verified: Harry Potter's `work.published` resolved to
     the real UK publish date `1997-06-26`, not a placeholder). Each
     award's `date` instead uses **year-only** (`epoch_to_year`: same
     conversion but `strftime("%Y")`), because award `awardedAt` values
     never carry real day/month precision — verified directly: every one
     of Harry Potter's 30 awards resolved to `<year>-01-01` (a placeholder
     day), matching Goodreads' own display (awards only ever show a year in
     parentheses). Don't "fix" this by switching awards to full dates again
     — the placeholder day would be fabricated precision that was never
     actually there.

     **Fields that don't exist for a given book are dropped, not kept as
     `null`** (`with_entries(select(.value != null))`, applied both to the
     top-level object *and separately* to the `work` sub-object before it's
     nested in — a book with no series has no top-level `series` key, and
     `work` itself would lose `title`/`published` the same
     way if either were absent) — except `series`/`genres`/`work.awards`
     are **arrays**, and an empty array survives that filter (it isn't
     `null`): a book with no awards gets `"work": {"awards": []}` (plus
     whatever else `work` has), not a missing key, since "no awards" is
     itself meaningful data, not an absent field. Confirmed both cases
     concretely: Harry Potter has 2 series entries and 30 awards; "Das Herz
     des Piraten" has `"series": []` and `"work": {"awards": [], ...}` (and
     its `work.title` happens to equal the top-level `title` — that's just
     this book, not a rule to special-case away).
3. **The page's own schema.org/Book JSON-LD** (`<script
   type="application/ld+json">`, via xidel, into `$ld_json`), after a
   cleanup pass through `jq 'walk(...)'` that, for every string value:
   squeezes whitespace runs to one space (Goodreads' own markup left
   `"Liz    Moore"` — an author name — with a run of spaces) and
   HTML-entity-decodes `&lt; &gt; &quot; &#39; &apos; &amp;` (Goodreads'
   own template leaves literal `&amp;` etc. in there too, even though this
   is inside a `<script>` block where entities shouldn't need decoding at
   all). This is the source of `name` — deliberately **left exactly as
   Goodreads provides it**, series annotation and all (e.g. `"The Giver
   (Giver, #1)"`) — `title` (above) is the separate, deliberately-clean
   field for when that annotation isn't wanted.

**`canonical_url` vs `url` — do not conflate these, they answer different
questions.** `canonical_url` (`<link rel="canonical">`) is the *work's*
preferred edition, and **can point at a different book id than the one
requested**: confirmed directly — fetching id `25098993`
("Das Herz des Piraten") got `canonical_url` embedding id `1744452` instead
(also in the *older* `<id>.Title_With_Underscores` slug style, vs. the
newer `<id>-title-with-dashes` style `url`/webUrl uses). `url` is always
this specific edition's own self URL, guaranteed to match the requested id
(that's exactly what the sanity check above confirms). If you mean "the
specific edition someone read," use `url`; if you mean "the work in
general" (e.g. resolving to Goodreads' preferred edition), follow
`canonical_url` — deliberately **not** auto-resolved/cached automatically
here (would silently turn one lookup into two fetches under a different
id, with no current consumer that needs it — revisit once something
actually does).

Book-level fields (ours and apolloState's) are **flat-merged** — no
sub-keys, except `work`, which is deliberately nested (see above) — into
the final `books/<id>.json`, written with **sorted keys** (`jq -S`, easier
to scan by eye and diff between refreshes). The merge order is `{book_id,
canonical_url} * $ld_json[0] * $apollo_json[0]` — JSON-LD **first**, our
own apolloState-derived fields **last**, so ours wins on any accidental
future key collision (jq's `*` merge lets the right-hand operand win). This
used to matter concretely: an earlier version of this design put the
structured awards array at a top-level `awards` key, directly colliding
with JSON-LD's own top-level `awards` (a folded string, e.g. `"Barry Award
Mystery (2025), Anthony Award ..."`) — confirmed then that putting
`$apollo_json` last made the structured array win. Moving the structured
version to `work.awards` (per the nesting above) eliminated that collision
entirely — the top-level `awards` is JSON-LD's folded string again,
unmodified, and `work.awards` holds the richer structured data alongside
it. The merge order is kept as-is regardless, as cheap insurance against
whatever collision might come up next. `@context`/`@type` are kept as-is
(not stripped, even though `url` replaced the more JSON-LD-idiomatic `@id`
a node identifier would use) — the result stays valid, literal JSON-LD,
just extended with our own fields (a plain `url` property is itself
standard schema.org, just not acting as the RDF node's own identifier the
way `@id` would), rather than being reduced to a
JSON-LD-inspired-but-not-actually-JSON-LD blob. See the actual saved
example fetched during research (`/tmp/goodreads-book-jsonld.json` in a
prior session — not committed anywhere, regenerate from a live fetch if
needed) for what schema.org/Book alone provides: `name`, `image`,
`bookFormat`, `numberOfPages`, `inLanguage`, `awards` (the folded string),
`author` (array of `{"@type": "Person", "name", "url"}`), `aggregateRating`,
sometimes `isbn`.

All five temp files (fetched HTML, cleaned JSON-LD, `__NEXT_DATA__`, the
apolloState-derived sub-object, the final merged JSON) are pre-created via
`mktemp` up front and cleaned up by **one** `trap ... EXIT` covering all of
them — traps replace each other rather than stacking, so setting a fresh
one per `mktemp` would only clean up the last file made. Every stage that
can legitimately fail (fetch, canonical-link extraction, `__NEXT_DATA__`
extraction, the id sanity check, apolloState extraction, JSON-LD extraction,
building the final JSON) is checked explicitly and returns 1 *before* the
final `mv`, never left to `set -e`: a caller invoking `gr::book_json` as a
non-final part of an `&&`/`||`/if-condition list (completely plausible —
my own test harness did exactly this) suppresses `errexit` for the *entire
nested call chain*, and `jq -c .` on a fully empty file exits 0 with empty
output rather than erroring — so an implicit-only check let a failed
refresh silently blank a previously-good cache the moment it was called
that way. Found this by testing the exact `&&`-wrapped call shape;
`gr::book_json` also checks `gr::refresh_book`'s return with `|| return 1`
rather than a bare statement, for the same reason. **Lesson**: don't rely
on ambient `set -e` for correctness that must hold regardless of how a
function gets called — check explicitly whenever a wrong silent success
(not just a crash) would be the failure mode. Verified end-to-end (fetch,
parse, merge, cache, re-read via `gr::book_json`, the sanity-check
mismatch case, the `work` sub-object nesting and its own null-stripping,
the empty-series/empty-`work.awards` case, and the
no-canonical-link/no-`__NEXT_DATA__`/no-apolloState-match/no-JSON-LD
failure paths all leaving no stray file) against real books — prefer
replaying a saved page over hitting the live site repeatedly (this project
has triggered AWS WAF's bot-challenge on goodreads.com more than once
already, see above — `gr::http_get` now retries/fails loudly on it rather
than silently caching nothing, but it still costs real requests; don't
provoke it needlessly). `gr::refresh_book` also
creates `books/` itself (`mkdir -p`) rather than relying on `gr::book_json`
having already done so — found via testing that calling it
directly/standalone (its own doc comment invites this) failed with a plain
`mv` error otherwise.

## `books` commands (implemented)

`books fetch [book_id...] [--blog <blog_id>...] [--challenge <challenge_id>]
[--all|-A] [--update|-U] [--batch|-B]`, `books list [book_id...] [--limit
n]`, `books get <book_id> [--json] [--update|-U]`, `books remove
[book_id...] [--all]`. Source: `src/bashly.yml` (command tree), one
`src/books_*_command.sh` per leaf command — same one-file-per-command
pattern `auth`/`blogs` use, all thin wrappers directly over
`gr::book_json`/`gr::book_dir`/`gr::book_file` (unlike `blogs fetch`,
there's no `gr::discover_*` equivalent backing any of these — see below
for why).

**No discovery, unlike `blogs fetch`** — there's no goodreads.com listing
page enumerating "all books"; a book only ever becomes known to this cache
by being fetched via an explicit id (from a blog post's own
`book_sections`, or hand-entered). So `fetch` only ever operates on ids
it's actually given: explicit `book_id...` args, `--blog <blog_id>`
(repeatable — expands to every book referenced by that blog post's
`book_sections`), `--challenge <challenge_id>` (expands to every book
referenced by *any* blog post linked to that challenge — see below), or
`--all` — the first three freely combine and are deduped together into
one `book_ids` pool, `--all` is mutually exclusive with all of them, and
giving none of the four at all is a plain usage error.

**`--challenge <challenge_id>`** resolves the challenge's own `.blogs[]`
(`gr::require_challenge_file`, same lookup `challenges get` uses — an
unknown id fails the same way, `error: no challenge <id>`) into their
`blog_id`s, merges those into `$blog_ids` (deduped there too, in case a
blog id was also given directly via `--blog`), then falls into the exact
same `--blog` expansion loop below — no separate code path, `--challenge`
is purely an alternate way to seed the same `blog_ids` variable. A
challenge with no linked posts at all gets `note: challenge <id> has no
linked blog posts` (same shape as `--blog`'s own "no books to extract"
note) rather than an error — an empty result is a normal, valid outcome,
not a mistake. **Books very much do repeat across a challenge's own
linked posts** — confirmed directly against the real `2026Q3` challenge's
8 linked posts: several books appear in 3 of them, and the final,
deduped set (850 unique ids) is exactly the same as manually
concatenating and deduping all 8 posts' own book lists by hand — the
existing dedup (already needed for plain `--blog`, just as relevant here)
handles it for free, no `--challenge`-specific logic needed.

**`fetch`'s default changed from "always force-refetch every given id" to
"only actually touch the network for an id that genuinely needs it,"
alongside its rename from `update`** — per explicit direction, in two
separate steps (the second one narrower than the first, see below).
`fetch_one` (`books_fetch_command.sh`) is driven by a `force` **policy**
string computed once up front (`force_policy`, one of `""`/`"ttl"`/
`"force"`), not a plain boolean — `--all` needs a genuinely third
behavior, distinct from both explicit-id defaults:

- **`""`** (explicit ids, no `--update`) — an id already cached, *at any
  freshness*, is skipped entirely (`-> already cached`, no network
  touched); a missing one gets a plain `gr::book_json "$id"` call (`->
  fetched`). This was the first step's change: every explicit id used to
  always force-refetch unconditionally before this.
- **`"force"`** (`--update`, alone or combined with `--all`) — always
  `gr::book_json "$id" --force`, bypassing the cache TTL entirely; `->
  refreshed` if it was already cached going in, `-> fetched` otherwise
  (only reachable via explicit ids + `--update` — never via `--all`,
  which only ever operates on ids that are already cached to begin with).
- **`"ttl"`** (`--all`, *without* `--update`) — **the second, narrower
  change: `--all` itself now honors the cache TTL by default too, instead
  of unconditionally force-refreshing every cached book the way it did
  right after the rename above** (which had only changed the *explicit*
  id path, leaving `--all` at its own prior "sync everything
  unconditionally" behavior) — per explicit follow-up direction, once
  more per-command consistency was wanted. Every already-cached book is
  still asked about here (never skipped outright the way `""` does), but
  via a plain `gr::book_json "$id"` call, no `--force` — so gr::book_json
  itself decides whether a real refetch happens, based on its own TTL
  check. `fetch_one` separately calls `gr::book_fresh "$id"` *before*
  that, purely to tell "already cached (fresh)" apart from "was stale,
  genuinely refreshed" in its own report — a distinction `gr::book_json`'s
  return value alone can't make, since it succeeds identically either
  way. **`gr::book_fresh`** (`goodreads_books.sh`) is that TTL/staleness
  check itself, factored out of `gr::book_json` for exactly this reuse —
  the same "missing or stale, one `find -newermt` check" logic as before,
  just now callable on its own; `gr::book_json` itself is otherwise
  unchanged, just calling `gr::book_fresh` instead of inlining the same
  check.

`--update`/`-U` is genuinely the *only* way to still bypass a book's cache
TTL on demand — `-A`/`--all` alone no longer implies that. **`-A`, not
`-a`, for `--all` on these two renamed commands specifically** — chosen to
read consistently alongside `--update`/`-U`'s own capital short flag;
every other command's unrelated `--all`/`-a` (`books list`/`remove`,
`blogs list`/`remove`, etc.) is untouched. `outcome_text`'s
`removed_remotely`-vs-`refreshed` distinction (`blogs fetch`) has no
counterpart here — `gr::refresh_book` doesn't implement that concept at
all, so a forced re-fetch is always reported as a plain `-> refreshed`, a
first-time fetch as `-> fetched`, regardless of anything else.

**`get --update`/`-U`** forces `gr::book_json "$id" --force` instead of the
plain, TTL-respecting call — the one place a book's cache TTL can still be
bypassed on demand for a single item outside of `fetch`.

**Progress during `fetch` is shown as a single, self-updating status
line, not a scrolling per-id list — `--batch`/`-B` (or stdout not being a
terminal at all) suppresses it entirely, per explicit direction.** Shared
verbatim with `blogs fetch` via four small helpers in `lib/goodreads.sh`
(nothing books- or blogs-specific about any of them):

- **`gr::fetch_quiet <batch_flag>`** — true (exit `0`) when the live line
  should be suppressed: an explicit `--batch`, or `[[ ! -t 1 ]]` (stdout
  isn't a terminal at all — a live, `\r`-based line would just corrupt a
  redirected/piped log with a churn of overwritten partial lines; this
  half is automatic, not something the user has to remember `--batch`
  for). Each fetch command computes this once, into a plain `quiet`
  variable, right after parsing its own flags — **as a real `if
  gr::fetch_quiet ...; then quiet=1; fi`, never
  `quiet="$(gr::fetch_quiet ...)"` or a bare `gr::fetch_quiet ... &&
  quiet=1`** — see the dedicated "round three" bug writeup further below
  for exactly why a command substitution here silently breaks the whole
  feature (it took a real, user-reported bug to find: the live status
  line was never able to draw at all, for anyone, until this was fixed).
- **`gr::status_line <message> <quiet>`** — `\r` plus `\033[K`
  (clear-to-end-of-line, so a shorter message never leaves a stray tail of
  a longer previous one) then `$message`, no trailing newline; a no-op
  when `$quiet` is non-empty.
- **`gr::status_line_clear <quiet>`** — clears the line without printing a
  replacement; called right before a genuine failure message, so it can
  never garble together with (or get silently overwritten by) whatever
  the status line was last showing. No-op when `$quiet` is non-empty, same
  as `gr::status_line`.
- **`gr::run_fetch <quiet> <fetch_fn> <force> <id...>`** — the actual
  per-id loop, calling `"$fetch_fn" <id> <force> <quiet>` for each
  remaining id and showing `"[<n>/<total>] <id>..."` on the status line
  *before* each call (so it's visible while a potentially slow network
  fetch is in flight) and `"[<n>/<total>] <outcome>"` after (overwriting
  the same line) when the call actually printed one. **Calling convention
  `fetch_fn` must follow**: print outcome text to stdout on success (`0`)
  or skip (`2`) — shown transiently on the status line, or dropped
  entirely under `--batch`/non-tty; print nothing to stdout on any other
  (failure) exit status, having already printed the failure straight to
  stderr itself, via `gr::status_line_clear` first. Leaves totals in
  `$GR_FETCH_OK`/`$GR_FETCH_SKIPPED`/`$GR_FETCH_FAIL` for the caller's own
  summary line (different call sites want different wording, e.g. `books
  fetch`'s single summary vs. `blogs fetch`'s three separate ones — new
  posts, `--all`'s already-cached sweep, and the explicit-id path each
  print their own). **Clears the status line before returning, rather
  than ending it with a newline** (`gr::status_line_clear`, not
  `printf '\n'`) — per explicit direction, so the caller's own summary
  line, printed immediately after, *replaces* the last status update
  instead of leaving it behind as a stray permanent line with the summary
  printed underneath it. Every call site prints its own summary right
  after calling this with nothing else in between, so this always lands
  on the right line. **Calls `$fetch_fn` — a bare statement — inside an
  `if`, never directly**: bashly's generated scripts run under `set -e`
  (see the `auth` section, way above), and a bare call would abort the
  *entire* command on `fetch_one`'s very first "skipped" return (`2`) —
  routine here, not even a failure — rather than just ending that one
  iteration. Found by testing directly: an early version called it bare
  and a mixed cached/uncached id list silently stopped after the first
  cached one, with no error at all.

**A single slow `gr::book_json`/`gr::blog_json` call must still be able to
explain itself live, even with a status line active — this took two
rounds of real, user-reported bugs to get right.**

Round one: `fetch_one`'s first version captured the whole call's stderr
(`err="$(gr::book_json ... 2>&1 > /dev/null)"`), meaning to defer it past
`gr::status_line_clear` and only ever print it on an actual failure. That
broke exactly the case that matters most: a call that's *slow* — an AWS
WAF bot-challenge retry (`gr::http_get`, up to `20+100+480` ≈ 10 minutes
total, see "Interaction stack" above) — but eventually *succeeds*. Its own
retry warning, the only thing that would explain the delay, was being
captured right alongside the real payload and then silently discarded the
moment the call returned success, since only the failure path ever
printed `$err`. A user saw the live symptom directly: `books fetch --blog
<id> --update` sat on `[1/9] <first id>...` for minutes with zero output,
looked indistinguishable from hung, and the only way to actually confirm
it wasn't was `ps`/`pstree` on the real box, finding a `sleep 100` child —
exactly `GR_HTTP_RETRY_DELAYS_DEFAULT`'s own middle value. **Fixed by no
longer capturing that stderr at all** — `fetch_one` now just does
`gr::book_json "$id" ... > /dev/null` (stdout only) and lets stderr flow
straight through live, the same as before this whole feature existed.
That reintroduced a garbling risk instead — a live warning landing mid-line,
right after the status line's own un-terminated `[n/total] id...` text —
handled at the source: **`gr::term_clear_line`** (`lib/goodreads.sh`) is
called by `gr::http_get` itself, immediately before its own retry
warning, clearing the line if stderr is a real terminal (`[[ -t 2 ]]`)
before printing. Deliberately **not** threaded through `fetch_one`'s own
`$quiet` — `gr::http_get` is generic, used by plenty of things that know
nothing about a `fetch` command's own `--batch` state (`auth status`'s
live check, `gr::refresh_blog`, etc.), so coupling it to that would be the
wrong layer; checking `-t 2` directly gets the *important* case right (a
redirected/piped log, where `-t 2` is false, never gets raw escape bytes
injected) at the cost of a harmless-but-imperfect one (an interactive
terminal combined with an explicit `--batch` still emits one no-op clear
sequence per warning, since nothing was ever drawn there to begin with —
not worth plumbing `$quiet` this deep just to avoid).

Round two, found immediately after restarting with round one's fix live:
letting stderr flow through uncaptured also unmasked `gr::throttle`'s own
*routine* wait message again — which, unlike the WAF retry, fires on
nearly every single request (default spacing is a few seconds, almost
always longer than one item's actual processing time), so it printed a
persisted line for nearly every id in the loop, right back to a scrolling
wall of text instead of a clean single line. **Fixed by silencing
`gr::throttle`'s message outright** (see "Minimum request spacing",
above) rather than routing it through the status line — it's expected,
by-design pacing, not worth announcing at all, unlike the genuinely
anomalous WAF backoff. Verified directly, end-to-end, with a stubbed
slow-then-successful fetch: `gr::throttle`'s own wait now produces no
output at all (confirmed with real elapsed time via `time`), while
`gr::http_get`'s retry warning still prints as its own clean, persisted
line — clearing the pending `[n/total] id...` first — and the outcome
line still draws correctly right after, with nothing swallowed.

**Round three, after the user reported the status line* still* wasn't
overwriting even with rounds one and two both live: the status line had
never actually been able to draw at all, for anyone, ever — the real bug
was in `gr::fetch_quiet` itself, not in anything downstream of it.** Its
original form communicated "suppressed" by echoing `"1"` to stdout (or
nothing), meant to be read back via `quiet="$(gr::fetch_quiet
"${args[--batch]:-}")"` — but **a command substitution's subshell has its
own stdout redirected to the capture pipe**, so the `[[ -t 1 ]]` check
*inside* `gr::fetch_quiet` was testing whether *that pipe* was a
terminal — which it structurally never is — rather than the real
script's actual stdout. `quiet` therefore came out non-empty
*unconditionally*, on every single invocation, regardless of whether the
real terminal was interactive or not, forcing every `fetch` command into
silent/`--batch`-equivalent mode from the moment the feature was first
built. Every manual/stubbed test in rounds one and two above (all of
which called `gr::fetch_quiet`, `gr::status_line`, etc. directly, never
through the real `$(...)`-wrapped call site the actual command scripts
use) validated the *downstream* logic correctly but never exercised this
specific bug at all — a sharp lesson in why testing a helper function
directly isn't the same as testing how it's actually invoked. Confirmed
directly with a real pty (`python3 -c 'import pty; pty.fork()...'`, since
neither plain output redirection nor `script` allocates a real one in
this environment): the old version produced **zero** status-line bytes
even when genuinely connected to a terminal — only the unconditional
failure lines (and, before round two's fix, `gr::throttle`'s own message)
were ever visible, which is exactly the symptom reported throughout this
whole saga.

**Fixed by switching `gr::fetch_quiet` to communicate via exit status
instead of stdout**, callable as a plain statement with no subshell at
all: `quiet=""; if gr::fetch_quiet "${args[--batch]:-}"; then quiet=1;
fi` (both `books_fetch_command.sh` and `blogs_fetch_command.sh`) — note
this is deliberately a real `if`, not a bare `gr::fetch_quiet ... &&
quiet=1`: the latter's own overall exit status would be `1` whenever
*not* quiet, tripping `set -e` and aborting the whole command in exactly
the normal, interactive case that most needs to work — the same class of
bug the `auth`/`fetch` sections above already call out repeatedly.
Re-verified with the same real-pty harness: the byte stream now shows the
expected `\r\033[K[n/total] id...` / `\r\033[K[n/total] id -> outcome`
sequence for every item, with a single real newline only once, right
before the final summary — confirmed correct for both `books fetch` and
`blogs fetch`.

**Round four, once round three actually let the status line draw: the
retry warning itself started piling up instead of updating in place.**
With the line finally working, `gr::http_get`'s own retry warning (kept
deliberately persisted back in round two, as the one genuinely-exceptional
case worth a real scrolling line) turned out to still be too noisy in
practice — a sustained bot-challenge block, per its own documented
behavior ("a burst allowance then a hard block outlasting any reasonable
retry window"), tends to affect *every* item in a loop, not just one, and
each one can retry up to `${#delays[@]}` times — so a real blocked run
could print many near-identical `warning: empty response for ...
retrying in Ns` lines back to back, overwhelming the very `[n/total]`
marker it was meant to explain. Reported directly by the user right after
confirming the marker itself finally worked.

**Fixed with a new `gr::term_status`** (`lib/goodreads.sh`, alongside
`gr::term_clear_line`): same idea as `gr::status_line`, but independent of
any command's own `$quiet` (checks `[[ -t 2 ]]` itself, since generic
code like `gr::http_get` has no way to reach a particular `fetch`
command's `--batch` state) — prints `\r\033[K$1` (no trailing newline,
overwriting in place) when stderr is a terminal, or an ordinary persisted
line otherwise (a redirected/piped log still benefits from seeing every
retry, not just the last one — there's no "in place" to overwrite there
regardless). `gr::http_get`'s retry warning now goes through this instead
of a plain `echo`, so repeated retries — whether from the same URL or
different ones later in the same loop — update a single line instead of
scrolling. The *final*, conclusive "kept returning an empty response
after retries" message (once, not repeated, genuinely worth a permanent
line) still goes through `gr::term_clear_line` first, to end that live
line cleanly before printing it. Verified directly with a stubbed `curl`
that always returns an empty body: two retry attempts against the same
URL now overwrite each other in place, and the final error prints as its
own clean, separate line right after.

**Round five, reported directly by the user: a genuine parse/validation
failure inside `gr::refresh_book`/`gr::refresh_blog` itself (e.g. "no
canonical link found") still garbled the status line**, even after all
four rounds above. Those functions' own `error: ...` messages (there are
several per function — fetch failure, missing canonical link, missing
`__NEXT_DATA__`/JSON-LD, id mismatch, JSON-build failure) were plain
`echo ... >&2` with no clear first — round one/four's fix only ever
covered `gr::http_get`'s *own* messages (the WAF-retry warning and its
final "kept returning an empty response" failure), never the messages
its *callers* print after `gr::http_get` already returned successfully
but a later parsing step then fails. **Fixed the same way as `gr::http_get`
's own final failure line**: `gr::term_clear_line` right before every one
of these `echo "error: ..."` calls in both functions — cheap and safe to
add unconditionally (a no-op if stderr isn't a terminal, or if there's
nothing on the current line to clear), rather than auditing which of
these specific error paths can *actually* fire while a status line is
live (in practice: all of them can, since every one is reachable from
`books fetch`/`blogs fetch`'s own per-item loop).

**`list` sorts by title, not by a recency date, unlike `blogs list`** — a
book's own `published` field is the *edition's* publish date, not remotely
"when this entry was added to the cache," so there's no meaningful
recency ordering to default to the way a blog feed naturally has one.
Columns: `id, published, author(s), title, pages, rating, url` (per
explicit direction, evolved twice: `published` moved between `id` and
`title` first, then `author(s)` moved in front of `title` and
`pages`/`rating` added right after it; `author(s)` is every
`contributors[].name` joined) — no `series` column (per explicit
direction, dropped to keep the table narrower — `books get` still shows
it) and no `challenge`-style column, since books carry no equivalent
field. `title` is truncated (`trunc(n)`, a local jq `def`) to 60
characters, and `author(s)` to 30 (also moved back down from a brief
40-character stint, both per explicit direction) via its own
`trunc_authors(n)` (below) — both replacing the cut tail with a single
`…` character (not `"..."`) so a truncated value is never longer than
its limit, rather than a three-character ellipsis pushing it over.
`pages` (`.numberOfPages`, right-aligned like `id`) and `rating`
(`.aggregateRating.ratingValue` — a bare number, the `★` it briefly
carried was dropped again per explicit direction; `?` when absent) are
the same
two JSON-LD-only fields `books get`'s own byline shows — here each its
own column instead, and `rating` deliberately compact (value only, no
`ratingCount`) since a list row has far less room than `get`'s detail
view.

**`trunc_authors(n)` cuts at a name boundary, not mid-name, per explicit
direction** — plain `trunc(n)` (used for `title`) chops at a fixed
character position regardless of what's there, which for a joined
`"Name1, Name2, Name3"` string can slice a name in half. Instead: if the
whole joined list already fits in `n`, it's left alone; otherwise, if
even the *first* name alone is already longer than `n` (no comma boundary
exists within the limit at all), it falls back to plain `trunc(n)` on the
full joined string — a mid-name cut is genuinely unavoidable here, per
the user's own stated exception; otherwise, the longest prefix of full
names whose own joined length still fits within `n` is kept, and `", …"`
appended right after it — i.e. the ellipsis always lands immediately
after the last preceding comma, never inside a name. Confirmed directly
against `V for Vendetta`'s real 4-author `"Alan Moore, David Lloyd, Steve
Whitaker, Siobhan Dodds"` (55 characters) → `"Alan Moore, David Lloyd,
Steve Whitaker, …"` at the 40-character limit, and against a synthetic
single name well over 40 characters on its own → falls back to a plain
mid-name `trunc(40)` cut, confirming the exception path.

**`strip_tagline` runs on `title` before `trunc(60)`, per explicit
direction** — many long titles are actually "Title: tag-line" (e.g.
`"Long Walk to Freedom: The Autobiography of Nelson Mandela"`), and
showing the tag-line half in a width-constrained list column is less
useful than showing the real title alone. Not reliably distinguishable
from a title that legitimately *contains* a colon (e.g. `"All About
Love: New Visions"`), so this is a deliberate heuristic, not a real
parse, per the user's own suggested rule: only when the *whole* title
exceeds 30 characters (a short title is never worth treating as a
title+tag-line pair) **and** the part before the first colon is shorter
than the part after it (a real tag-line is normally the longer half —
confirmed against several real cached titles, e.g. `"Stupid TV, Be More
Funny: How the Golden Era of The Simpsons Changed
Television—and America—Forever"` → kept `"Stupid TV, Be More Funny"`)
does the colon onward actually get dropped; otherwise the title is left
alone (`"All About Love: New Visions"` is only 28 characters, so it's
kept whole despite having a colon). Only the *first* colon is ever
considered, not every one in the title — a real tag-line always
immediately follows the title itself, not some later, incidental colon
deeper in the string. This only ever affects `books list`'s own display
— the full, untruncated title (colon and all) is always what `books get`
shows, and what's actually stored on disk; nothing about the cache
itself is touched. `url` is built fresh as
`"https://goodreads.com/book/show/" + .book_id` (id only, no slug, no
`www.`) rather than read off the cached `.url` field — that field
carries the full `<id>.Title_With_Underscores` slug, and a short id-only
url was explicitly what was asked for; same "no `www.`" convention
`blogs get`'s book rows already use (tested: a book url behaves
identically with or without `www.`, unlike a blog url — see there).
Sorted case-insensitively
(`ascii_downcase`) by `title // name`. A single `--limit n` caps the
*alphabetically-first* `n` after sorting (no `--since`/`--until`/`--all`/
`--reverse` — none of those have an obvious meaning for a title-sorted
list, so they were left out rather than copied over from `blogs list` for
symmetry's own sake); omitting `--limit` shows everything, which is the
default (unlike `blogs list`'s capped-by-default 15) since there's no
"most recent N" concept driving a sensible cap here either. Explicit
`book_id...` args narrow the candidate set the same way `blogs list`'s do
(missing ones noted to stderr, not fatal) and are unaffected by
`--limit`. Implementation is the same `cat "${files[@]}" | jq -s '...'`
single-pipeline shape `blogs list` uses, for the same performance reason
(see the "Performance lesson" note above).

**`get`** always calls plain `gr::book_json <id>` (no `--force`) — the
book cache has a finite TTL (`book_cache_ttl`, unlike blog posts' infinite
one), so a bare `get` transparently re-fetches a stale entry on its own;
there's no "if not cached yet" caveat to state the way `blogs get`'s doc
comment does. `--json` behaves identically to `blogs get --json` (`cat`s
the pretty-printed cache file directly, bypassing `gr::book_json`'s own
compacted stdout). The default pretty rendering is a `{meta, series}`
object from one jq call (same "build a JSON object, format it in bash"
shape `blogs get` already uses for its own book-sections table).

`meta` is a flat list of present-only lines, each built so an absent
field just contributes nothing (`map(select(. != null and . != ""))`),
same "no stray separators from a fixed template" approach `blogs get`'s
own byline line uses — in order: title; the byline `by <contributors> ·
<published>[ · work first published <work.published>, only when it
actually differs] · <numberOfPages> pages · <ratingValue>
(<ratingCount> ratings)` (page count and rating are JSON-LD-only fields,
per the "Open design questions" note above — pulled straight off
`.numberOfPages`/`.aggregateRating`, not otherwise renamed or reshaped;
`ratingValue` is a bare number, no `★` — briefly added, then dropped
again per explicit direction; no thousands-separator formatting on
`ratingCount`, kept as the plain number); `Genres: ...`; `ISBN: ...`;
and, **last, per explicit
direction** (moved down from originally being the second line, right
after the title), `URL: <url>` — deliberately the very last `meta` line
so it sits immediately before the `series` table (below) in the actual
printed output, not just last in the array by coincidence.

**`series` is its own table, per explicit direction** — not folded into
`meta` as a single joined line the way an earlier version had it.
Columns: `series_id` (read directly off the cached `series[].series_id`
field — already extracted at fetch time, see the book cache section
above — right-aligned, `column -t -R 1`, same convention as every other
id column in this project), `title` (each entry's `name` plus `
#<position>` when present — the *series* index, not to be confused with
`published`), and `url`, built fresh as `"https://goodreads.com/series/"
+ .series_id` rather than read off the cached `series[].url` field — that
field is inconsistent (sometimes carries the older
`<id>-slug`-style path, sometimes just the bare id, confirmed directly on
a real book with two series entries) and always allows `www.`; a short,
consistently-shaped id-only url without `www.` was explicitly what was
asked for, same convention `books list`'s own book urls already use (see
above — tested there that `www.` is genuinely superfluous for
goodreads.com, at least for `/book/show/`; not separately re-tested for
`/series/` specifically, but kept consistent regardless). Printed under
its own `Series:` header, indented two spaces (`sed 's/^/  /'` over the
already-`column -t`-aligned table), only when the book actually has at
least one series entry — nothing printed at all otherwise, confirmed
directly against a real standalone (non-series) book.

`description` (often a full paragraph) is printed last, after a blank
line, on its own — not folded into `meta` at all — prefixed with
`"Description: "` (per explicit direction, matching the `"URL: "`/
`"Genres: "`/`"ISBN: "` labeling convention the other `meta` lines
already use).

**`remove`** is a straight copy of `blogs remove`'s shape (`book_id...` or
`--all`, mutually exclusive, an error if neither is given, per-id outcome
plus a summary, exits 1 if anything requested wasn't cached) — nothing
book-specific to say about it beyond substituting `gr::book_dir`/
`gr::book_file` for their blog equivalents.

## Blog post cache (implemented — no CLI surface yet, see below)

`src/lib/goodreads_blogs.sh`. Exists as groundwork for reading-challenge
support: a challenge's own badges each link off to a `goodreads.com/blog`
post (e.g. the "CommunityPicks" badge → a themed book-list post), but that
mapping only lives behind the step-up-auth wall described in the reading
challenge research (`~/.goodreads/research/reading-challenges/notes.md` —
machine-local, not committed; summary: certain endpoints require the
underlying Amazon login to have happened within the last hour, which a
long-lived `auth import` session structurally cannot satisfy). Blog posts
themselves, by contrast, are plain public pages — no login needed at all,
confirmed by fetching with the account-less/generic cookie jar. So the
plan is a human-in-the-loop workflow: scrape blog posts and flag the ones
that look like challenge book-listings (book count + cover-grid layout —
confirmed via research that this correlates with "big listicle", not
specifically with "challenge", so it's a candidate filter, not proof), let
the user manually supply a challenge's title/date-window and confirm which
flagged posts actually belong to it. This cache is the "scrape and store
blog posts" half of that; the flagging/matching logic itself isn't built
yet.

**Cache TTL is infinite, unlike books** — deliberate, per explicit
direction: a published blog post's content doesn't change. So
`gr::blog_json` (`src/lib/goodreads_blogs.sh`) has no
`book_cache_ttl`-style age check at all — "the file exists" and "the cache
is fresh" are simply the same question here. The only way to re-fetch an
already-cached post is passing `--force` as `gr::blog_json`'s second
argument; `gr::refresh_blog` itself takes no force/freshness parameter
and always fetches, unconditionally, whenever called — same division of
responsibility as `gr::book_json`/`gr::refresh_book` (the wrapper decides
*whether* to call refresh; refresh itself doesn't decide, it just does).

**Blog post URLs** (`gr::blog_url <id>` →
`https://www.goodreads.com/blog/show/<id>`): same "id alone is enough"
convention as `gr::book_url`, confirmed directly — requesting the bare-id
form of a real post gets a plain HTTP 301 to the full `<id>-slug` URL
(`gr::http_get`'s `-L` follows it transparently), while a genuinely gone id
gets a real, distinct HTTP 404. Fetched account-less (the generic cookie
jar `before_hook` already defaults `COOKIE_JAR` to) — blog posts don't need
a login to view, confirmed directly.

**Posts get deleted from goodreads.com eventually** (confirmed: several
old-looking ids return a real 404) — per explicit direction, a
locally-cached post's content must survive that, not get silently wiped or
left to look like an ordinary "never fetched" miss. `gr::refresh_blog`
handles this by treating the two failure modes differently: `gr::http_get`
itself only reports success/failure, not *why*, so on failure a dedicated
follow-up call to `gr::http_status` (`src/lib/http.sh` — a new, minimal
"just tell me the status code" sibling to `gr::http_get`, sharing its
offline/cookie-jar/throttle handling but not its WAF-challenge retry loop,
which is about something else entirely — a 2xx response with an empty
body, not a 4xx) checks specifically for `404`. A confirmed 404 calls
`gr::mark_blog_removed`, which sets `removed_remotely: true` +
`removed_remotely_detected_at` (an ISO 8601 UTC timestamp, set once on
first detection and left alone on every later call — no value in
re-stamping "still gone") on the *existing* cache file, touching nothing
else in it; if nothing was ever cached for that id, a minimal stub
(`{blog_id, url, removed_remotely, removed_remotely_detected_at}`) is
written instead of nothing, so `gr::blog_json`'s plain
file-exists-means-fresh check (above) naturally stops re-attempting a
confirmed-dead id without needing any special-case logic of its own. Any
*other* failure (network hiccup, unexpected page structure, etc.) is a
normal error — return 1, nothing written, any existing cache file left
completely untouched, same "never silently corrupt a good cache on
failure" rule `gr::refresh_book` follows.

**Sanity check**: the fetched page's own `<link rel="canonical">` — its
leading digits must match the requested id — same spirit as the book
scraper's `__NEXT_DATA__`-based check, adapted since blog posts aren't
Next.js pages (no `__NEXT_DATA__` here at all; this is an older,
server-rendered Rails view).

**Extracted fields**: `blog_id`, `url` (the canonical link), `title`
(`<h1 class="gr-h1 gr-h1--serif">`), `author` and `published`
(`YYYY-MM-DD`, parsed from the page's own "Posted by `<author>` on
`<Month> <Day>, <Year>`" byline text), `like_count` (from the page's own
like-count link, `/rating/voters/<id>`), and `book_sections`/
`challenge_potential`, below.

**The article container's raw HTML is deliberately *not* persisted** — per
explicit direction, only the structured fields above are wanted, not a copy
of the markup. It's still extracted internally though (via
`--output-format=html`, not xidel's default plain-text extraction —
confirmed directly that a listing post's actual book list is almost
entirely `<img alt="...">` cover-grid elements a text-only extraction would
silently drop): it's the input `book_sections`' own extraction validates
against (a basic "did we actually find a real post" check) and
`challenge_potential` greps for its grid-widget class name on (a CSS
class name only exists in real HTML, not a plain-text rendering) — written
to its own temp file either way, on general principle, even though it's no
longer written into the final cache file.

**`book_sections`**: every book referenced anywhere in the post, id +
title, grouped the way the post itself groups them. A listing post often
divides its books into named sub-lists (e.g. "204 Retellings" groups its
204 books under headings like "Retellings based on Greek and Roman
mythology"; "I Love the 90s" groups by individual year, 1990–1999, plus two
catch-all sections) — plain `<h1 style="text-align:center">` elements
interleaved with the book grids in the body, confirmed against multiple
real posts (not exclusive to grid-style posts either — a small "weekly
recommended books" post turned out to have one too, just a single section
covering all its books). Most posts have no such headings at all and get
one `{section: null, books: [...]}` group holding everything — the general
case collapses cleanly to a flat list, no special-casing needed for it.
`book_sections` **replaced** an earlier flat `book_ids` field — a plain id
array with no titles or grouping, superseded once this was built (its
grouping is a strict generalization: flatten `book_sections[].books[]` to
get the old shape back).

Per book: `book_id` and `title`. Grid-embedded books get a real title from
their cover image's `<img alt="...">` — specifically the one whose class
contains `AcrossImage` (`fourAcrossImage`/`threeAcrossImage`, the only
variants a real cover image has ever been confirmed to use), **not** just
the first `<img>` anywhere inside the link. That distinction is a real
fix, found via `blogs get`'s pretty rendering (below) surfacing several
books titled literally "Kindle Unlimited" once a human was actually
reading the titles instead of them sitting unnoticed in JSON: a book's
cover-grid entry is preceded by its own sibling
`<div class="amazonBadge amazonBadge--fourAcrossImage__missing">`, a
wrapper for a promotional badge (Kindle Unlimited eligibility, evidently)
that's usually empty (`__missing`) but not always — when it does contain
its own `<img>`, that image sits *before* the real cover image in document
order, and `string()` on a multi-node XPath result takes the first one.
Fixed retroactively too — 13 of the then-172 cached posts had at least one
"Kindle Unlimited"-titled book, all re-fetched after the fix, all clean
afterward (confirmed: zero remaining). A plain inline prose mention (an
ordinary `<a href="/book/show/...">`, no image) has no reliable title
anywhere in the markup at all, and gets `title: null` — confirmed directly
that real posts mix both forms for the *same* book (an early inline
mention with no title, then the same book id again later in its actual
section's grid, title included that time). Deduplicated by book_id first —
among a book_id's occurrences, the one with a non-null title wins (falls
back to the first occurrence if none has one), which in every real case
checked is also the one with the book's true section, so the null-titled
duplicate is simply discarded. Section-grouping is then a `reduce`, not a
second `group_by` (which would silently re-sort groups alphabetically by
section text, destroying the post's own reading order) — each deduped book
keeps its original document position (`idx`, assigned before dedup)
specifically so re-sorting by `idx` afterward recovers narrative order,
and each book is folded into whichever section group is already open for
its section value, opening a new one when it isn't. This needs
`--extract-kind=xquery3` on that particular `xidel` call — its default `-e`
language is plain XPath, which has no `let` bindings at all (confirmed:
errors outright without the flag) — needed here for
`$a/preceding::h1[...][last()]`, the nearest *document-order* preceding
heading regardless of tree nesting (a section heading and its book grid
are siblings/cousins at varying depths, not ancestor/descendant, so a
tree-structural query wouldn't find it).

**`challenge_potential`**: a float, `0` to `1` — **currently only ever
exactly `0` or `1`**, a direct carry-over of an earlier plain boolean field
(`likely_challenge_listing`, renamed and reworked into this one per
explicit direction: "we will refine the rules for the value later, just
convert current true and false to 1 and 0 for now"). The underlying
heuristic computing it is unchanged from that earlier boolean version —
only the field's name and output type changed, to leave room for a
genuinely fractional confidence score once the heuristic itself gets
refined. `1` only when *all three* of the following hold — hardened
repeatedly since the first version, each time against a real, named
counterexample the user pointed at directly, not a hypothetical (and once,
just as usefully, *un*-hardened again when a "fix" turned out to be
wrong — see condition 2's own history below):

1. The post's body uses Goodreads' own compact cover-grid embed
   (`threeAcrossImage`/`fourAcrossImage` — confirmed the only two variants
   actually seen). The original, sole condition.
2. At least `$GR_CHALLENGE_LISTING_MIN_BOOKS` (40) books total. Added after
   post 3182 ("The Week in Books..."), a 33-book weekly news roundup, was
   found still flagged `true` — a post can legitimately use the grid
   widget for just a handful of picks without being any kind of big themed
   listing. The threshold wasn't picked blind: sorting every then-flagged
   post by book count showed a clean jump from 12 and 33 (both real
   small-roundup/promo posts, confirmed on inspection) straight to 48 and
   up (everywhere from there reads as a genuine big listicle, whatever
   it's actually about) — 40 sits in that real gap. One-directional, not a
   reversal of the earlier "count alone doesn't work" finding below: that
   finding was about a *high* count not proving true-positive-ness, which
   a floor doesn't contradict — it only ever excludes posts too small to
   be a real candidate, never confirms one.

   **A third condition was added here, then reverted — worth keeping the
   story, not just the outcome.** Reasoning at the time: 3182 mixes its 8
   grid-widget "trending this week" picks with a *second* section using
   `oneAcrossImage` + a full `<div class="bookInfoFullRow">` (an editorial
   `<div class="bookDescription">` paragraph per book, not just a cover) —
   surely a real big listicle would never mix the two, so exclude any post
   that does. Checked against four known-good posts at the time
   (3140/3184/3043/3145) and all were exclusively one widget, no mixing —
   looked solid. **It wasn't**: confirmed directly against real,
   *known-correct* ground truth — post 3127 ("Readers' Hit New Books of
   the Year (So Far)") is one of the actual current Summer Challenge's own
   8 badge-linked posts (verified via the gated achievement data captured
   earlier this project — see the "HAR capture" section above), and it
   genuinely mixes the two exactly the way 3182 does (a
   `oneAcrossImage`/`bookInfoFullRow` "featured pick, more detail" entry
   per genre section, alongside the main grid) — yet it's unambiguously
   real challenge material. "A real big listicle never mixes the two" was
   simply false. Worse, the condition was never even load-bearing for the
   case that motivated it: 3182's real book count (33) already sits below
   the condition-2 floor (40) on its own — the mixing check added zero
   coverage for 3182 and one confirmed false negative for 3127. Reverted
   outright rather than patched (e.g. into a ratio/threshold check) —
   checked the actual numbers first (3182: ~2 of 33 books via the one-per-
   row widget; 3127: ~11 of 143) and they're similar enough that no simple
   ratio would cleanly separate the two either. **Lesson: don't harden
   against a single counterexample with a rule stronger than that
   counterexample actually needs, and check any new exclusion rule against
   confirmed *positive* examples too, not just the negative one that
   motivated it** — condition 3 (audiobooks, below) was cross-checked
   against 3127 specifically for exactly this reason once it was found.
3. **At least one *plain, unmodified* grid image** —
   `class="fourAcrossImage"` or `class="threeAcrossImage"` *exactly*, not
   Goodreads' own `--audiobook` BEM modifier of that same class
   (`class="fourAcrossImage--audiobook"`). Subsumes condition 1's own
   grid-presence check entirely (an exact-class match is trivially also a
   substring match), so that separate check was folded into this one
   rather than kept alongside a now-redundant duplicate. Added after post
   3157, "72 Reader-Approved Audiobooks for Every Bookish Mood" — a clean
   grid, all 72 entries, easily past the count floor, yet not a challenge/
   big-listicle post at all, per explicit direction (the actual tell
   suggested: audiobook cover art reads roughly square, real book covers
   read portrait) — confirmed directly the *markup* already says so
   explicitly, no image-dimension inspection needed: every one of 3157's
   cover `<img>`s carries the modifier.

   **This condition's first version repeated condition 2's exact mistake,
   for the exact same reason — worth keeping this story too.** It excluded
   on *any* occurrence of the `--audiobook` modifier anywhere in the post,
   checked at the time against 3127 specifically (zero occurrences there)
   and judged safe. It wasn't: post 3129 ("The Goodreads Staff...Share Top
   Book Recommendations" — also real challenge material, the StaffShelves
   badge) turned out to have 8 occurrences of the modifier mixed into an
   otherwise-normal 128-cover grid — a handful of the staff's picks happen
   to be audiobooks, same as any real recommendation list might
   legitimately include a few. Checking only against 3127 wasn't
   checking against the *whole* known-good set, and this is exactly the
   gap that let it through — condition 2's retrospective already named
   this as the lesson, and this condition's first draft still fell into it
   regardless. Fixed the same way as condition 2: require the post to have
   at least one plain-class cover (confirmed directly — 3157 has zero;
   3129 has 128, the 8 audiobook ones notwithstanding) rather than
   excluding on any audiobook-styled cover being present at all.

**Still not proof a post is tied to any *specific* challenge** — confirmed
directly, before any of this hardening, that an unrelated big listicle
(3043, "204 Retellings") uses the exact same grid widget as real challenge
posts, and nothing added since changes that: this field says "book-listing-
shaped candidate", never "confirmed challenge material". It's a candidate
signal for the human-in-the-loop matching workflow this whole cache exists
to support (see "Purpose"/status above): book-listing-shaped posts,
narrowed by a challenge's own date window (user-supplied, since that's not
reliably scrapeable either), confirmed by the user — not something this
field claims to settle on its own. That confirmation step is `challenge`,
below.

Retroactively re-applied across the whole cache every time the heuristic
itself hardened (`blogs fetch --all`, since the value is computed at
fetch time from body HTML that isn't persisted — there's no way to
recompute it without a real re-fetch) — not just the one or two posts
spot-checked directly. The rename to `challenge_potential` itself (this
session) was likewise applied to the whole then-existing 172-post cache —
but as a pure data migration (`likely_challenge_listing: true/false` →
`challenge_potential: 1/0`, no `.challenge` field touched, since it didn't
exist yet at that point), not a re-fetch: the value itself didn't change,
only its name and JSON type, so there was nothing to actually recompute.

**`challenge`**: the human half — a **tri-state manual override**:
`true`, `false`, or the key **entirely absent** (never `null` — per
explicit direction, "neither of the two" is a genuinely third state, not
the same thing as an explicit `false`, and storing it as JSON `null` would
blur that distinction; jq itself already reads a truly-missing key as
`null` anyway, so nothing is lost by using absence for it instead of a
literal value). Set via `blogs challenge <blog_id...> (--yes | --no |
--auto)` — `--auto` runs `del(.challenge)`, not an assignment,
specifically to produce the "absent" state rather than a stored `null`.
Unlike `challenge_potential`, this is never touched by
`gr::refresh_blog`'s own scraping logic — it only *preserves* whatever
value (or absence) was already on disk across a refresh, read from the
old cache file before that file gets rebuilt from scratch (`gr::refresh_blog`
always does a full `jq -S -n` rebuild, not a merge — without this explicit
carry-forward step, a routine `blogs fetch --all` would silently wipe
out every manual decision made since the last full re-fetch). Confirmed
directly: marking a post, then force-refreshing it (`blogs fetch
<blog_id>`, a real re-fetch over the network) left `challenge` untouched
while `challenge_potential` still got freshly recomputed as normal.

**Merging the two into one effective status** — "is this post effectively
considered a challenge listing" — is centralized in exactly one place:
`GR_CHALLENGE_JQ_DEFS` (`src/lib/goodreads_blogs.sh`), two jq `def`s held
together as one bash string constant:

- `gr_challenge_status`: `challenge` wins whenever it's actually present
  (`!= null`, which for jq is the same test as "not the absent-key case"),
  otherwise falls back to `challenge_potential` crossing
  `$GR_CHALLENGE_POTENTIAL_THRESHOLD` (0.5 — moot today since the value is
  only ever exactly 0 or 1, but factored out by name rather than
  hardcoded, ready for when `challenge_potential` gains real fractional
  values).
- `gr_challenge_marker`: one of four single characters, replacing an
  earlier plain `*`/` ` binary marker per explicit direction — `°`
  explicitly marked *not* a challenge (`.challenge == false`), `*`
  explicitly marked *as* one (`.challenge == true`), `?` no manual
  override but `gr_challenge_status` is still true (i.e. the machine guess
  alone crosses the threshold), or a plain space for neither. Built on top
  of `gr_challenge_status` rather than re-deriving the threshold
  comparison a second time: by the point its own `elif gr_challenge_status`
  branch is reached, `.challenge` has already been ruled out as `true` or
  `false` by the branches above it, so `gr_challenge_status` there is
  exactly the machine-guess fallback alone.

Every command that needs either — `blogs list`'s marker + potential
columns, `blogs get`'s challenge-potential line — prepends this constant
to its own jq program text (`"$GR_CHALLENGE_JQ_DEFS"'...rest of the
program...'`, two adjacent bash string tokens with no space between them,
which bash concatenates into a single argument to `jq`) rather than
reimplementing the same `if/else` inline at each call site — the whole
reason this is a named constant instead of just being written inline the
first time it was needed: a merge rule duplicated across several separate
`jq` invocations in separate command files is exactly the kind of thing
that quietly drifts out of sync the next time only one of the copies gets
updated.

**Why two fields instead of one** — considered merging `challenge` directly
into `challenge_potential` (e.g. pinning it to `0`/`1` once manually
decided) rather than keeping them separate. Rejected: refresh would still
need the exact same "read the old value before rebuilding, carry it
forward" logic regardless of which field name it's preserving — merging
them doesn't remove that need, it just hides which parts of a single
field are machine-owned versus human-owned, and loses the genuine "neither
was ever decided" state entirely (a merged field has no way to tell "never
looked at" apart from "assessed as 0"). Two fields keep that distinction
explicit and keep `gr::refresh_blog` free to always overwrite
`challenge_potential` unconditionally — no conditional "don't clobber
this" logic needed there at all, only the one explicit carry-forward read
for `challenge`.

**Large HTML content must never be passed to `jq` via `--arg`** — found
while `body_html` (above) was still a persisted field: a big listicle
post's body easily exceeds 500KB, and `--arg` becomes a literal element of
`jq`'s own argv, which blew straight past the OS's argument-list size
limit (`jq: Argument list too long`) on a real 204-book post, confirmed
directly. Fixed at the time by writing it straight to its own temp file
and passing that to `jq --rawfile` instead, which has no such limit —
`body_html` no longer reaches `jq` at all now that it isn't persisted (see
above), but the underlying lesson still applies to anything comparably
large that does: never `--arg`, always a temp file + `--rawfile`. Every
other currently-extracted field is small enough that plain `--arg` is
fine.

**A `trap ... RETURN` set inside a function is a global handler, not
scoped to that call frame** — it stays the active RETURN trap and fires
*again* on the next function return anywhere up the call stack, not just
the one that set it. Bit this code directly: `gr::refresh_blog` (and
`gr::mark_blog_removed`) each set a `trap 'rm -f ...' RETURN` to clean
up their own temp files: fine on their own return, but since neither
function used to clear it afterward, the *same* trap — still referencing
that function's own now-out-of-scope locals — fired again when the
*caller* (`gr::blog_json`) itself returned. Under plain `set -e` (no
`set -u`, which is what bashly's generated scripts actually run under —
see the auth section above) this was silently harmless (`rm -f ""` is a
no-op), but running the same code under `set -u` (as a manual test
driver did) turned it into a hard `unbound variable` crash — and either
way, a leftover trap silently referencing whatever an unrelated later local
variable of the same name happens to be is fragile, not just cosmetically
wrong. Fixed by having the trap's own command clear itself as its last
action (`trap 'rm -f "$x"; trap - RETURN' RETURN`) so it never outlives the
function that set it. Worth checking `goodreads_auth.sh`'s existing
`trap ... RETURN` uses (`gr::identify_account_from_cookiejar`,
`gr::cookies_state`) for the same latent issue if either is ever touched
again — not fixed here, out of scope for this change, and doesn't
misbehave in the real `set -e`-only bashly context, but the same root
cause applies.

The `blogs` command group (below) is the CLI surface for this cache — the
actual challenge-association flagging/matching logic this cache exists to
support is still next-step work, not yet built.

## `blogs` commands (implemented)

`blogs fetch [blog_id...] [--all|-A] [--update|-U] [--batch|-B]`, `blogs
list [blog_id...] [--all | --since <date> --until <date> --limit <n>]
[--reverse]`, `blogs get <blog_id> [--json] [--update|-U]`, `blogs
challenge <blog_id...> (--yes | --no | --auto)`,
`blogs remove [blog_id...] [--all]`. Source: `src/bashly.yml` (command
tree), one `src/blogs_*_command.sh` per leaf command — same
one-file-per-command
pattern `auth` uses; `fetch` is the one command backed by real logic in
`src/lib/goodreads_blogs.sh` (`gr::discover_blog_ids`) rather than being a
thin wrapper — every other command is just that, directly over
`gr::blog_json`/`gr::blog_dir`/`gr::blog_file`.

**Progress during `fetch` (all three branches below) is shown as a
self-updating status line, suppressed by `--batch`/`-B`, shared verbatim
with `books fetch`** — see the "`books` commands" section, above, for the
full `gr::run_fetch`/`gr::status_line`/`gr::status_line_clear`/
`gr::fetch_quiet` mechanics (nothing books-specific about any of them);
this section only covers what's actually different here.

**`fetch`** started out as two separate commands (`refresh`/`discover`)
and was deliberately collapsed into one, per explicit direction — its
behavior branches on what's passed, in priority order:

1. **One or more `blog_id`s** (`repeatable: true` in `bashly.yml` — bashly
   exposes this at runtime as `args[blog_id]`, a single space-separated
   string, not a real array; word-split back apart deliberately, not
   quoted): `fetch_one` (`blogs_fetch_command.sh`, called via
   `gr::run_fetch` — see above) handles each one with the `""`/`"force"`
   force policy — no `"ttl"` on this path, that's `--all`-only, below — a
   post not already cached always gets a plain `gr::blog_json <id>` call
   (reported `-> fetched`, doubling as "add a new post by id", no
   separate "add" needed); one *already* cached is left alone (`->
   already cached`, no network touched) **unless `--update`/`-U` is
   given**, which force-refetches it instead (`gr::blog_json <id>
   --force`, reported `-> refreshed`, or `-> confirmed removed remotely`
   if it 404s — see `outcome_text`). **This default — skip what's already
   cached — is a behavior change from this command's former name,
   `update`**, where an explicit id was *always* force-refetched
   regardless of cache state; renamed to `fetch` alongside that change,
   per explicit direction. Mutually exclusive with `--all` — checked
   explicitly and rejected with an error, since bashly itself doesn't
   enforce that (confirmed directly: both can be set simultaneously as far
   as arg parsing is concerned).
2. **`--all`/`-A`**: does a **full** discovery pass (`gr::discover_blog_ids
   --full` — see below for what that means) *and* additionally checks
   every post that was already cached before this run started, via
   `fetch_one`'s `"ttl"` force policy by default, or `"force"` if
   `--update` is also given (`refresh_force`, computed right before that
   call). **`--all` alone no longer unconditionally force-refreshes
   everything the way it always used to — per explicit follow-up
   direction, for consistency with `books fetch --all` now also honoring
   its own real TTL (see there).** The blog cache's own TTL is *infinite*
   though (a published post's content never changes, see "Blog post
   cache" below) — `gr::blog_fresh` (`goodreads_blogs.sh`) is trivially
   just `gr::blog_file`'s own existence check, so under the `"ttl"` policy
   *every* already-cached post is reported `-> already cached (fresh)`
   without ever touching the network at all. **This makes plain `--all`
   (without `--update`) unable to re-verify an existing post is still
   there any more** — a real, acknowledged behavior loss, accepted
   anyway for cross-command consistency, per explicit direction ("may
   make the flag absurd, but consistent with `books fetch --all`"). Run
   `--all --update` for the old "sync everything, confirm nothing's
   gone" behavior — that combination still force-refreshes every
   already-cached post exactly as `--all` alone always used to. The set
   checked is deliberately *only* what was cached going in, not including
   whatever this same run just discovered — no point re-asking about
   something that's already fresh from the discovery pass moments
   earlier. Also the *only* mode that reports which cached ids no longer
   turn up in the current listing — see below for why that specifically
   needs `--full`'s guaranteed-complete scan, not available on plain
   `blogs fetch` at all anymore; that report suggests `fetch <id>
   --update` specifically, since plain `fetch <id>` on an already-cached
   id would otherwise just skip it without checking anything.
3. **Neither** (plain `blogs fetch`): a discovery pass only — scans the
   `/news` listing (`gr::discover_blog_ids`, no flag — see below for how it
   short-circuits) and fetches whatever comes back as genuinely new
   (`fetch_one` with the `""` force policy — they're genuinely new,
   nothing to force over, so this behaves the same as the explicit-id
   path's own default). The short-circuit lets this stop *far* short of
   the full ~18 pages once at least one discovery has ever completed (see
   below) — no "no longer appears in the current listing" report on this
   path at all, unlike an earlier version: a short-circuited scan can't
   tell an older, never-(re)scanned id apart from one that quietly
   disappeared, so it has nothing honest to say about that; run `--all`
   for that check.

Formalizes what had been done ad hoc all session via one-off research
scripts (see the "news catalog" research notes) into a real, reusable
command.

`gr::discover_blog_ids` (the underlying function) paginates
`/news?content_type=articles[&page=N]` — the filter is deliberate, not the
default: removing it also surfaces `/interviews/show/<id>.<name>` pages, a
structurally different content type (separate id space, separate layout,
no book list at all) this project doesn't scrape — confirmed directly that
without the filter, zero *additional* `/blog/show/` ids turn up, only
those unrelated interview pages, so filtering costs nothing.
`$GR_NEWS_DISCOVER_MAX_PAGES` (50) is a safety cap against looping forever
if the listing ever breaks in some way that doesn't terminate naturally —
well above the real page count (17-18, confirmed directly by running this
to completion against the live site).

**The discovery marker** — added per explicit direction, replacing an
earlier design (below) that seeded pagination with the *entire* on-disk
cached-id set: a small on-disk state file
(`gr::blogs_discovery_marker_file`, `$(gr::data_dir)/.blogs_discovery_marker`
— a plain-text file holding one numeric blog id, same "small state file
directly in the data dir" convention as `gr::throttle`'s own
`.last_request_at`) remembers the id of whatever post sat at the very top
of page 1 as of the last **successfully completed** discovery. A later
plain `blogs fetch` stops paginating as soon as it encounters that exact
id again — the listing is recency-ordered, so reaching it means everything
from that point on is guaranteed already-known, no need to keep walking
the remaining ~17 pages just to re-discover ids already sitting in the
cache. Only ids appearing *before* the marker in that page's own document
order count as new (found via an order-preserving dedup,
`awk '!seen[$0]++'`, not `sort -n -u` — position relative to the marker is
what matters here, not just set membership). `--full` mode
(`gr::discover_blog_ids --full`, what `--all` uses) ignores this marker
entirely and walks the whole listing unconditionally, the same as a
marker-less first-ever run does — but **every** successful run, `--full`
included, still updates the marker afterward: "this marker is only ever
updated by running a blog discovery" (explicit direction) means any
completed discovery counts, not just the short-circuited kind.

Two termination conditions, either one ends the pagination loop: the
marker turning up on a page (the common case once any discovery has run
before), or a page contributing no id beyond what's already been
accumulated *this run* (the fallback — covers `--full`, a marker-less
first run, and the marker's own post having since been deleted from the
listing so it can never be matched again).

The marker write is the very last thing `gr::discover_blog_ids` does, and
only on the success path — the early `return 1` on a page-fetch failure
never reaches it. Confirmed directly: with `--offline` forcing a failure,
the on-disk marker was untouched afterward; a later, successful run picks
up exactly where the old marker leaves off, same as if the failed attempt
had never happened. This was an explicit requirement, not just a nice
property — "allow repeating a failed discovery with still the old
marker."

**Getting the marker capture right took two real, confirmed bugs to find**
(both caught by testing directly against the live listing rather than
trusting the design on paper):

1. The very first version extracted candidate ids with a page-wide
   `grep -oE '/blog/show/[0-9]+'` — anywhere on the page, not scoped to the
   actual article listing. The page header carries its own unrelated
   promotional banner link (a `topFullImage`/`BigBooksFall26_eb`-style
   React prop, not part of the article feed) that happens to point at some
   blog post id too, and sits *before* the real listing in raw document
   order — so this matched it as if it were the listing's own first
   (implicitly: newest) entry. Confirmed directly against a real fetched
   page: that banner linked to the single *oldest* post actually visible in
   the real listing below it, about as wrong as a "newest post" marker
   could possibly be. This likely also explains the older "one single
   stray id past the real page range" finding (used for the fallback
   termination condition, above) from long before the marker existed — the
   header, banner included, renders on every page template regardless of
   whether real content still exists at that page number, so an
   out-of-range page could easily echo nothing but that same banner link
   for the same reason; that finding only described the symptom
   empirically at the time, this is the likely actual cause. Fixed by
   scoping the match to lines that also carry
   `editorialCard__image--fullHeight` — the real per-post listing card's
   own cover image class, always on the same physical line as its
   `/blog/show/<id>` href in this markup (confirmed directly against real
   fetched pages) — which the header banner never carries.
2. Even after that fix, the very first live re-run of a short-circuited
   `blogs fetch` — genuinely nothing new since the marker was set — came
   back reporting a hard failure (exit 1) with no error message at all.
   Traced (via `bash -x`) to `gr::discover_blog_ids`'s own last line:
   `sort -n -u <<< "$all_ids" | grep -v '^$'` — when there's legitimately
   nothing to return, `grep -v` finds zero lines to output and exits 1
   (its own "no lines selected" convention, not an actual error), which
   then became *this function's own* return status since it was the last
   command executed. Every caller's `gr::discover_blog_ids ... || exit 1`
   read that as a real failure. Fixed by capturing the result into a
   variable and `echo`ing it instead of ending on the bare pipeline —
   `echo` always succeeds regardless of whether there's anything to print,
   so the function's own exit status now reflects only whether the
   pagination loop itself actually failed.

**`gr::discover_blog_ids` no longer filters its own return value against
the real on-disk cache at all** — a deliberate simplification over the
earlier `$1`-seeded design (below): it only ever answers "what does the
listing currently show, scanned this efficiently," never "what's not
already cached." Diffing against the real `*.json` files present is the
caller's job in both branches of `blogs_fetch_command.sh` now (`comm -23`
against a freshly-built `cached_ids`, built once, shared by both the
`--all` and plain branches) — previously only `--all` needed to do this
itself, since the old seeded design had the plain path do this filtering
internally. Found to be necessary, not just a symmetry cleanup: on a
marker-less first-ever run (or the marker's-post-deleted fallback), a
short-circuited scan can return ids that are already sitting in the local
cache, and without this diff those got misreported as `-> fetched` even
though `gr::blog_json` itself still only ever served the on-disk copy for
them — no wasted network call, just a misleading label. Confirmed directly
against the real 172-post cache before this fix, and clean after.

**Earlier design, superseded by the marker above**: `gr::discover_blog_ids`
used to take an optional `$1` — a newline-separated set of already-known
ids — and seed the "no new ids" per-page termination check with it
directly, added per explicit direction so plain `blogs fetch` could stop
paginating once it reached ids the local cache already had, rather than
always walking the full ~18-page listing even when nothing past page 1 or
2 was ever going to be new. Confirmed working at the time: a routine
`blogs fetch` against an already-fully-populated 172-post cache dropped
from walking all ~18 pages (several minutes, throttled) to ~2 seconds.
Replaced because a single remembered marker id is simpler than carrying
the *entire* known-id set through this function just to diff against it on
every single page, and doesn't depend on the caller having an accurate
known-id set in the first place (the marker is authoritative about "what
discovery last saw," independent of whatever's separately been added or
removed from the cache by other means since).

**bashly's command-embedding step silently corrupts a multi-line string
literal spanning two source lines in a `*_command.sh` file** — found while
building `discover`'s own already-cached/catalog set-difference. It
prepends a fixed indent to *every physical line* of a command file when
inlining it into the generated script's function body (purely cosmetic for
ordinary code — confirmed harmless everywhere else), but a continuation
line of a multi-line string picks up that injected indentation as part of
its actual runtime *value*, not just source formatting. `discover`'s first
version built its already-cached-ids list as `cached_ids="$cached_ids\n$(...)"` split across two source lines, which reached the generated
executable as `cached_ids="$cached_ids\n  $(...)"` — a stray two-space
prefix on every id, invisible in the source file itself. The fallout was
silent and total: `comm` (used for the new/missing set difference) never
matched a single already-cached id against anything, so a live run
reported **all 166** ids as "new" and force-refetched every one — including
the 33 already genuinely cached — rather than the ~133 that actually were.
No error, no warning, just wrong output; caught only by noticing the
fetched count didn't match expectations and diffing this source file
against the corresponding function body in the generated `goodreads`
script. Fixed by never spanning a string literal across two physical
source lines in a command file — `"${cached_ids}${cached_ids:+$'\n'}${id}"`
instead, one physical line, immune to the injected indent regardless of
where it lands. `src/lib/*.sh` files are sourced verbatim (no such
re-indentation happens there), so this is specific to `*_command.sh` files
— worth remembering for any future multi-line string built in one of
those, and worth an extra moment's suspicion any time a command file's
runtime behavior doesn't match what its source plainly says it should do.

**Regenerating `bin/goodreads` (`make bin/goodreads`) while a long-running
invocation of it is still executing in the background is *mostly* safe,
but not entirely** — a *single* overwrite while a process has the old file
open for reading is fine (Linux keeps serving that process the original
content through its already-open file descriptor; confirmed directly,
several times, across this whole `blogs` feature's development, each time
regenerating mid-run to pick up the next change without disrupting a
several-minutes-long `blogs fetch --all` already in flight). But doing
that *repeatedly* during one single long-running invocation eventually
desynced something: a real run left a stray
`line 2845: logs_usage: command not found` at the very tail of its output
— a corrupted read, evidently from the executing process's read position
no longer lining up with any one consistent version of the file after
several successive overwrites. It landed strictly after all the real work
for that run (the refresh loop, the summary counts, the missing-ids
report) had already completed and printed correctly, so no actual data was
lost — confirmed directly: the final file count, per-post success count,
and JSON validity all checked out fine afterward — but it's real
corruption, not just a cosmetic annoyance, and could plausibly land
somewhere that *does* matter with different timing. **Prefer letting a
background invocation of `goodreads` finish before regenerating the
executable again**, rather than relying on this having worked out gently
each time so far.

A successful `gr::blog_json` call doesn't distinguish "fetched real
content" from "confirmed permanently gone, marker written" (both are
success from its own point of view — see `gr::refresh_blog` above), so
`fetch`'s own `outcome_text` helper checks `removed_remotely` itself
afterward and reports `-> confirmed removed remotely` instead of a plain
`-> refreshed`/`-> fetched` when that's what actually happened — found by
testing against a real nonexistent id and noticing the plain "Refreshed
blog post 999999." message was misleading (nothing was actually fetched).
Shared by every `fetch_one` call site (the explicit `blog_id...` path,
the discovery loop's genuinely-new ids, and `--all`'s own already-cached
sweep) via `gr::run_fetch` — see the "`books` commands" section for that
mechanism, and above in this section for `--all`'s own `"ttl"`/`"force"`
split.

**`list`**: one line per post, sorted by `published` date, most recent
first — changed from an id sort on explicit direction. Defaults to the 15
most recent (`--limit <n>` overrides the count; `--all` shows everything,
mutually exclusive with `--since`/`--until`/`--limit` — asking for
"everything" and a filtered/capped view at once doesn't mean anything) and
prints a trailing note naming the true total whenever the cap actually
truncated something (never printed when `--all`, explicit ids, both
`--since`+`--until` together, or the true total is already `<= limit`).
Explicit `blog_id...` args narrow the candidate set to exactly those
(missing ones are just noted to stderr, not fatal — the rest of the
request still gets served) and bypass the cap entirely, same as `--all`
does — you asked for specific ones, so exactly those are what get shown,
however many that is; combining explicit ids with `--since`/`--until` is
allowed (they still narrow the *shown* set further) since there's no real
conflict, only `--all` is exclusive with the date flags. `--since <date>`/
`--until <date>` are parsed liberally via `date -d` (same as
`gr::refresh_blog`'s own byline-date parsing) rather than requiring the
exact `YYYY-MM-DD` storage format, so "yesterday", "2 weeks ago", etc. all
work.

`--limit`'s meaning depends on which date bound, if any, is active — per
explicit direction that "the 15 most recent" isn't actually what's wanted
once a bound narrows the range:

- Neither bound (or `--until` only): `--limit n` keeps the `n` *newest*
  matching posts — the same head-of-sorted behavior as always, since
  "closest to `--until`" and "most recent" agree in this direction.
- `--since` only: `--limit n` keeps the `n` *oldest* matching posts — the
  ones closest to `--since`, working forward — the opposite end of the
  sorted array from the no-bound case, since here "closest to the bound"
  means the earliest matches, not the latest.
- Both `--since` and `--until`: no cap at all — the two bounds together
  already say exactly which posts are wanted ("all of them, in that
  range"), so a `--limit` alongside both is contradictory, not merely
  redundant, and is rejected outright (`error: --limit has no effect once
  both --since and --until are given...`), the same way `--all` combined
  with a date flag is rejected — never silently ignored.
- `--until` before `--since` (both given) is also rejected outright
  (`error: --until (...) is before --since (...)`) rather than silently
  producing an empty range.

`--reverse` flips whatever set actually ends up selected/capped, applied
as the very last step, regardless of which of the above branches produced
it — reversing before capping would reverse *which* posts got shown, not
just their order, which isn't what "reverse the list" means. The trailing
truncation notice's wording follows the same split: "oldest" when
`--since` alone drove the cap, "most recent" otherwise — printed only when
a cap was actually applied (tracked via one `bypass_limit` bash variable
covering `--all`, explicit ids, and the both-bounds case uniformly, rather
than re-deriving "was anything capped" from `$all`/`$blog_ids` alone,
which would silently miss the both-bounds case).

Implementation is `cat "${files[@]}" | jq -s '...'` — every candidate
file, slurped into one real JSON array, with the date filter, the sort,
the cap, and `--reverse` all done as a single `jq` pipeline over that
array. An earlier version instead built a TSV row per file (one `jq -r`
call each) and drove `sort`/`awk`/`head`/`tac` over that in bash — working,
but needlessly roundabout for something `jq` itself already does natively
once every candidate is one array; simplified on direct feedback that this
was overcomplicated. `jq -s` (slurp mode) takes concatenated JSON documents
from stdin exactly as `cat` produces them, whitespace between them (this
project's own pretty-printed storage format, in particular) included —
no manual line-joining needed regardless of file count or formatting.
Emits `{total, lines}`: `$total` is the post-filter, pre-cap count (what
the truncation notice needs), `$lines` is TSV — one row per post actually
being displayed, **already in final display form** (the effective
challenge status — `gr_challenge_status`, see the "Blog post cache"
section above — and a `[removed remotely]` suffix both folded into the row
by `jq` itself, not reconstructed from separate fields in bash). The
header row is fed through the exact same pipe as the data —
`{ printf 'id\tpublished\ttitle\tbooks\tchallenge\turl\n'; jq -r '.lines[]' <<< "$result"; } | column -t -s $'\t' -R 1,4`
— and `column -t` (not a hand-picked fixed-width `printf`, an earlier
version's approach, changed on direct feedback) does the actual column
alignment: it sizes each column to its own widest value, so there's no
fixed-width assumption (`%-7s` for id, say) to silently outgrow the moment
some value needs one more character than expected — and the header has to
go through the same measurement pass as the data for exactly that reason,
not print pre-aligned to an assumed layout. `-R 1,4` right-aligns the id
and books-count columns specifically (util-linux `column`'s own flag for
it, per explicit direction, each added in its own turn) — `published`,
`title`, `challenge`, and `url` stay left-aligned, `column -t`'s default;
`challenge` deliberately so even though it's numeric-adjacent — it's a
compound marker-plus-number label (below), not a pure number, so
right-justifying it wouldn't read as cleanly as it does for `id`/`books`.

Column order is `id, published, title, books, challenge, url`, per
explicit direction (an earlier version had two separate leading marker/
potential columns before `id` — see `challenge`, below, for why they're
one column now, and in this position). `url` is the rightmost column, per
explicit direction — `title` sits earlier instead and does need real
column-width padding as a result (there's nothing to its right when it was
the trailing column). Real
scraped titles routinely carry curly quotes, em dashes, etc.; tested
directly that util-linux `column` (2.37.2 here) measures that UTF-8
content correctly rather than by raw byte count, so this doesn't actually
misalign the `url` column that follows — but that's a property of this
`column` build, not a guarantee, worth re-checking if this project ever
moves to a much older util-linux. `url` is built fresh as
`"https://www.goodreads.com/blog/show/" + .blog_id`, not read off the
cached `.url` field, since that one carries the full slug and a short,
id-only url was explicitly what was asked for (confirmed elsewhere, e.g.
`gr::blog_url`: goodreads.com resolves either id-only form identically to
the slug one). `www.` is kept here — unlike `blogs get`'s book urls
(below) — tested directly: a bare `goodreads.com/blog/show/<id>`
301-redirects to add `www.` back before serving anything (on top of the
already-known, unrelated id→slug redirect every blog url gets regardless
of `www.`), while `www.goodreads.com/book/show/<id>` vs.
`goodreads.com/book/show/<id>` behave identically with no redirect at all.
Not obviously explained by anything this project controls — just an
observed, tested asymmetry in how goodreads.com itself routes the two
paths.

The sort/filter key is `.published`, or a `"0000-00-00"` fallback —
lexically before every real date — when absent (only a `removed_remotely`
stub file ever lacks one); that fallback sorts an unknown-date post to the
very end in most-recent-first order rather than landing arbitrarily, and
gets explicitly excluded whenever `--since`/`--until` is actually active
(an unknown date can't truthfully satisfy an explicit range, so it's
dropped rather than kept with an unanswerable comparison — but only when a
date filter is in play; with neither flag given, every cached post is
still shown, unknown-date ones just sorted last). One easy-to-miss
`jq` subtlety: `sort_by(x) | reverse` is *not* the same as a stable
descending sort — reversing the whole array after an ascending stable sort
also flips the relative order of same-key ties, unlike (e.g.) GNU
`sort -r`, which stays stable in the forward direction even reversed. Not
worth working around: "sort by publish date" doesn't specify tie-breaking
among same-day posts, so which of two same-date posts prints first is
genuinely unspecified, not a correctness bug — just don't be surprised by
it if it ever comes up again.

`challenge` is one column, not two — raw `challenge_potential` rounded to
2 decimal places (`fmt2dp`) and `gr_challenge_marker` (`°`/`*`/`?`/space
for explicitly-not/explicitly-yes/machine-guessed/neither, see "Blog post
cache" above), joined by a single space, value first then symbol
(`(.challenge_potential // 0 | fmt2dp) + " " + gr_challenge_marker`) —
per explicit direction (value-then-symbol order swapped from an earlier
symbol-then-value version); an even earlier version had these as two
separate leading columns instead. `fmt2dp` is a `def` local to this
command — presentation formatting, not
part of `GR_CHALLENGE_JQ_DEFS`, since no other command needs it. jq has no
built-in printf-style decimal formatting, so `fmt2dp` builds the fixed
"X.YY" string by hand: scale by 100 and round to a whole number of
"cents", split into whole/fractional parts, zero-pad the fractional part
back to two digits (`round()` alone would print `"1"` for `0.1`, not
`"0.10"` — jq numbers drop trailing zeros in `tostring`). `[removed
remotely]` is appended to the title for a post `removed_remotely` marked
true. Book count is `[.book_sections[]?.books[]?] | length` — the `?`s
matter, a `removed_remotely` stub file has no `book_sections` key at all,
and this degrades to `0` instead of erroring.

**`get`**: fetches on demand via `gr::blog_json` (discarding its own
compact-JSON stdout, only used for its side effect + exit status). Default
output is a pretty book listing, not the raw JSON — per explicit
direction, since that's what someone running `get` almost always actually
wants to read. `--json` gets the old behavior: `cat`ing the cache file
directly rather than re-emitting anything (the file on disk is already
pretty-printed with sorted keys, `gr::refresh_blog`'s own write format —
`gr::blog_json`'s own stdout is deliberately compacted to one line
instead, for programmatic callers, so `--json` bypasses it too).
`--update`/`-U` swaps the plain `gr::blog_json "$id"` call for
`gr::blog_json "$id" --force`, force-refetching an already-cached post
before printing it (e.g. to re-check whether it's since 404'd) — the only
way to force this outside of `fetch <id> --update`.

The pretty renderer is one `jq` call that emits a JSON object (`{removed,
meta, sections, rows}`), not text directly — title/url/`author · published
· N likes` (each piece dropped via `map(select(. != null))` if actually
absent, rather than a fixed three-part template that would leave stray
`· ·` separators) plus a `gr_challenge_marker`-prefixed "Challenge
potential: `<raw value>`" line go in `meta` — unconditional now (an
earlier version only showed anything here when `gr_challenge_status` was
true; changed per explicit direction to display the value itself, not
just a derived yes/no) — with a parenthetical noting *why*
(`"(manually marked as a challenge listing)"`/`"(manually marked as NOT a
challenge listing)"`) whenever `.challenge` is actually set, nothing
appended when there's no override and the line is just reporting the
machine's own guess. Shown at full precision here, unlike `blogs
list`'s 2-decimal-rounded column — no column-width constraint in this
one-post detail view;
`sections` is `{header, count}` per `book_sections` group (`Section
(count):`, or `Books (N):` for the single group a post with no real
sectioning gets); `rows` is every book across every section, flattened
into one `book_id\ttitle` TSV list, in original order. A `removed_remotely`
post instead gets `{removed: true, meta: [...]}` with no `sections`/`rows`
at all — its own much shorter branch, since a stub has none of the normal
fields to render (no title/author/book_sections — see
`gr::mark_blog_removed`), not the full renderer running over mostly-absent
data.

Book rows are id-first, `column -t`-aligned (`  - Title  [book_id]`, an
earlier version's format, dropped on explicit direction for a real
id-then-title table instead — id right-aligned, `-R 1`, matching
`blogs list`'s own id column), `url` the rightmost column (per explicit
direction, same as `blogs list`) — built fresh as
`"https://goodreads.com/book/show/" + .book_id` (there's no cached field
to read here regardless, unlike a blog post's own stored `.url`),
**without** `www.`, unlike `blogs list`'s blog urls — tested directly:
`goodreads.com/book/show/<id>` and `www.goodreads.com/book/show/<id>`
behave identically, no redirect either way, so `www.` is genuinely
superfluous for a book url specifically (confirmed *not* true for a blog
url — see there, the asymmetry is real and tested, not assumed). `title`
sits in the middle and does need real column-width padding as a result;
tested directly that util-linux `column` (2.37.2 here) measures real UTF-8
title content (curly quotes, em dashes) correctly rather than by raw byte
count, so this doesn't misalign the trailing `url` column, but that's a
property of this `column` build, not a guarantee — and aligned **once,
globally, across every section**, not reset per section: `jq -r
'.rows[]' <<< "$result" | column -t -s $'\t' -R 1` runs a single time over
the *entire* flattened book list, then
a `while` loop walks `sections` again and slices consecutive lines off the
front of that one aligned array using each section's own `count` (tracked
via a running `idx`) to know where one section's rows end and the next
begin. Running `column -t` separately per section instead would size each
section's id/title columns independently — inconsistent alignment across
one single listing the moment two sections' ids differ enough in digit
count, exactly what running it once globally avoids. A blank line follows
each section's own books (a plain `echo` at the end of the same loop
iteration, added per explicit direction) — including a trailing one after
the very last section, not specifically suppressed there since a trailing
blank line is harmless.

**`challenge`**: sets or clears `.challenge` (see the "Blog post cache"
section above for the full tri-state design and why it's a separate field
from `challenge_potential`) on one or more posts — `blog_id` is
`repeatable: true` here (renamed from an earlier single-id-only `mark`
command per explicit direction, taking the same repeatable-id shape
`fetch`/`remove` already use). Exactly one of `--yes`/`--no`/`--auto` is
required — checked by hand in bash, same "bashly doesn't enforce this
itself" pattern every other multi-flag `blogs` command uses — and unlike
those, *no* flag given is rejected too rather than defaulting to anything,
since there's no sensible default for a command whose entire purpose is
recording an explicit human decision. Each id needs to already be cached
(`gr::blog_file`'s path exists) — an uncached id is reported to stderr
(`<id> -> not cached`) and counted as a failure rather than aborting the
whole run, same "best-effort across the list, report the tally" shape
`blogs remove`'s own multi-id loop uses (`mark_one`/`remove_one`, a shared
helper plus a loop, in each case) — not fetched on this command's own
initiative, since marking an as-yet-unseen post as a challenge listing (or
not) isn't something it can meaningfully do sight unseen; the failure
message points at `blogs fetch <blog_id>` instead. Implementation is a
plain `jq '. + {challenge: true}'` / `'. + {challenge: false}'` /
`'del(.challenge)'` **merge onto the existing cache file**, not a rebuild —
unlike `gr::refresh_blog`'s own `jq -S -n`, every other field (including
`challenge_potential`, the machine's own guess) is left untouched, since
this command only ever means to touch the one key it's actually about.
`--auto` is `del(...)`, specifically, not an assignment to `null` — the
tri-state is true/false/*absent*, and `del` is the operation that actually
produces "absent" rather than a stored `null` value.

**`remove`** (renamed from `delete`, per explicit direction — same
command, same behavior, just the name; its own alias was already `rm`
before the rename, so this only made the primary name match the alias
family every other `remove` command in this project already uses):
takes the same `blog_id...`/`--all` shape as `fetch` (added afterward, on
explicit direction, to match) — one or more explicit ids, or `--all` for
every cached post, mutually exclusive, and now an error if *neither* is
given (a bare `blogs remove` with nothing to act on used to be impossible
since `blog_id` was `required: true`; now that it's `repeatable`
instead — optional by bashly's own rules — that "give me something to
do" case has to be checked explicitly). `--all` builds its id list from
`gr::blog_dir`'s contents and folds it into the exact same `blog_ids`
code path the explicit-id case uses (word-split apart the same way)
rather than being a separate branch, keeping only one place that
actually does a removal (`remove_one`). Per-id outcome plus a summary
line, same shape as `fetch`'s own reporting; unlike `fetch`'s failures (a
network hiccup is worth tolerating and reporting on, not aborting over), a
requested id that was never cached is treated as a real usage error here —
`remove` exits 1 if anything requested wasn't found, `fetch` does not.
Still no confirmation prompt even for `--all` (which can now wipe the
*entire* local blog cache in one call) — same non-interactive-removal
precedent as `auth logout`, not changed just because the blast radius grew;
revisit only if actually asked for.

## Reading challenges (implemented — CLI surface: `challenges`)

**Challenges are manually curated, not scraped** — the "Blog post cache"
section above already established that challenge *detail* (which books
count toward which badge) is largely locked behind a step-up-auth wall no
long-lived session can satisfy, so there's no `gr::discover_challenges`-
style listing scan the way `blogs` has. This is the human-in-the-loop half
that groundwork was building toward: the user records a challenge's own
title/time-window by hand, then links it to whichever `blogs`-cached
posts and book-count badges actually apply — `challenges edit
--add-blog`/`--add-badge` below, not automated discovery.

**`challenge_id` is a purely local string** (`--arg id`-bound in the jq
program that writes the file, so it's always a JSON string, never a
number, regardless of whether it happens to look numeric) — unlike
`book_id`/`blog_id`, which are goodreads.com's own ids, there is no
external id to key off here at all. **Derived from the challenge's own
`start`/`end`, not a sequential counter** (`gr::generate_challenge_id` in
`src/lib/goodreads_challenges.sh`, called once by `gr::create_challenge`;
there is no `.next_challenge_id` state file, unlike an earlier version of
this design):

- **Seasonal** (per `gr::challenge_season` — the exact same rule
  `gr::default_challenge_title` uses to decide whether to name a challenge
  after its season, so a challenge's id and its default title can never
  quietly disagree about "is this seasonal"): `<year>Q<quarter>`, e.g.
  `2026Q3` for a challenge whose `end` falls within a month of the
  `2026-09-30` quarter-end (`<quarter>` is 1-4, `GR_QUARTER_END_MONTHDAY`'s
  own index + 1). If that id is already taken, `-<counter>` is appended,
  counting up from **2** (`2026Q3-2`, `2026Q3-3`, ...) — the bare id reads
  as "the first one", so its first collision is naturally "the second one".
- **Non-seasonal**: `<year>-<counter>`, keyed off `start`'s own year (no
  quarter-end to anchor to) — counting up from **1** straight away, with
  no bare `<year>`-only id ever attempted first (unlike the seasonal case,
  where the bare `<year>Q<quarter>` id always exists and is only avoided
  on an actual collision).

Existence is checked directly against the real `challenges/*.json` files
on disk (`gr::challenge_file "$candidate"`), not any separate counter
state. **This means an id genuinely can be reused once its challenge is
removed** — confirmed directly: creating `2026Q3`, removing it, then
creating an equivalent challenge again produces `2026Q3` again, not
`2026Q3-2` — a real behavior change from the sequential-integer scheme
this replaced (which never recycled a removed id at all, see git history
if that reasoning is ever needed again). Accepted deliberately here: this
scheme's ids are meant to be recognizable/predictable content-derived
labels (closer to a slug than an opaque counter), and a slug for a
genuinely re-created challenge naturally lands back on the same slug.

**An id is fixed at creation and never recomputed by `edit`** — editing a
challenge's `start`/`end` later (`challenges edit`) does *not* rename its
id to match, even if that changes which quarter (or year) it now falls
into or whether it's still "seasonal" at all. This is the same general
risk `[[feedback-stable-ids-over-mutable-slugs]]` warns about for
mutable/human-readable identity keys (there: a Goodreads username
changing out from under an `<id>-<username>` directory key) — accepted
here anyway, per explicit direction to use this exact date/quarter-derived
scheme, but worth remembering: after a significant `edit`, a challenge's
id may no longer reflect its current window. Nothing currently depends on
re-deriving it, so this is cosmetic (a possibly-stale-looking id), not a
correctness problem — revisit only if something ever does start relying on
an id's own shape matching its challenge's current data.

**`create --id <id>`** overrides `gr::generate_challenge_id` entirely — the
given string is used as-is (`gr::create_challenge`'s 4th, optional
parameter), no `<year>Q<quarter>`/`<year>-<counter>` derivation at all.
Checked *before* anything else in `challenges_create_command.sh` (ahead of
the badges/blogs handling, start/end parsing, etc.) — an already-taken id
fails outright with `error: challenge <id> already exists`, and an id
containing `/` is also rejected (`error: --id must not contain '/':
<id>`) since it becomes a filename component verbatim
(`gr::challenge_file`), the one piece of input sanitization this command
does that no other `challenges`/`books`/`blogs` id-taking command bothers
with (those never derive a path from unvalidated user input the way a
freshly-typed `--id` does here). No further format constraint — a manual
id doesn't have to look anything like the auto-generated ones, e.g. `--id
book-club-pick` is fine.

**Schema** (`challenges/<id>.json`, pretty-printed with sorted keys, same
convention as `books`/`blogs`): `challenge_id`, `title`, `start`, `end`
(both plain `YYYY-MM-DD`, parsed liberally via `date -d` at the CLI layer
the same way `blogs list --since`/`--until` already are), `blogs` (array
of `{blog_id, name}`), `count_badges` (array of `{count, name}`). Per
explicit direction: both list fields are genuinely allowed to stay empty
(`[]`) forever — a challenge with no badge-linked posts yet, or no
book-count badges at all, is a normal, valid state, not an error — and
both are lists of *objects*, not bare ids/integers, specifically so a
`name` (the badge each entry earns) can hang off either kind of entry.
`blogs[].name` and `count_badges[].name` are each optional (`null` when
not given, never `""` — same "absence is a real third state" stance
blogs' own `.challenge` tri-state field takes) — a badge doesn't have to
be named to be tracked.

**`gr::add_challenge_blog`/`gr::add_challenge_count_badge` are upserts,
keyed by `blog_id`/`count` respectively** — adding an id/count already on
the challenge only replaces its `name` (in place, so add-order — and thus
display order — is preserved) rather than appending a duplicate entry.
`count_badges` is additionally kept `sort_by(.count)` after every write,
so display order is always ascending (2, 3, 5, ...) regardless of the
order badges were actually added in — `blogs` has no equivalent re-sort,
since add-order (roughly, the order a human worked through a challenge's
badges) is itself meaningful there, unlike a badge's numeric count.
`gr::remove_challenge_blog`/`gr::remove_challenge_count_badge` each
return 1 (nothing written) when the given id/count isn't actually present
— `challenges edit`'s own `--remove-blog`/`--remove-badge` handling uses
this to report a per-item outcome, same "best-effort across the list,
report the tally" shape `blogs remove`'s own multi-id loop already uses.

**Every write is a merge onto the existing file, never a full rebuild**
(`gr::update_challenge`, `gr::add_challenge_blog`,
`gr::add_challenge_count_badge`, and their `remove` counterparts all read
the file, `jq`-transform just the relevant part, and `mv` a temp file back
over it) — same principle as blogs' own `challenge` command merging onto
its cache file rather than reusing `gr::refresh_blog`'s full
`jq -S -n` rebuild. `gr::update_challenge` treats an empty string as
"don't touch this field" for each of `title`/`start`/`end` independently
— safe here specifically because none of the three is ever legitimately
an empty string.

**`$end` does not parse as a jq variable reference — a real, confirmed jq
parser quirk, not a typo.** `end` is a bareword jq keeps for `if`/`end`;
a bare object key `end: ...` and field access `.end` both compile fine
(confirmed directly), but `--arg end "$value"` followed by `$end` in the
program fails to compile (`syntax error, unexpected end, expecting IDENT`)
— jq's grammar can't disambiguate a `$`-prefixed reference to the same
reserved word. Fixed by naming the jq-side binding `end_date` instead
everywhere a challenge's end date is threaded into a jq program
(`gr::create_challenge`, `gr::update_challenge`) — purely a jq-side
rename, the bash variable and the JSON field are both still plainly
`end` throughout current code and on disk.

**`GR_CHALLENGE_STATUS_JQ_DEF`** (`src/lib/goodreads_challenges.sh`) is a
shared jq `def challenge_status($today): ...` constant, prepended to both
`challenges list`'s and `challenges get`'s own jq programs the same way
`GR_CHALLENGE_JQ_DEFS` (`goodreads_blogs.sh`) is — centralizing the
planned/`ongoing`/`finished` computation in one place rather than
duplicating it, so it can't quietly drift out of sync between the two
commands. Deliberately unrelated to `GR_CHALLENGE_JQ_DEFS` despite the
shared "challenge" word in both names: that one is about a *blog post's*
own candidate-listing flag (`blogs`' `.challenge`/`.challenge_potential`),
this is about a *reading challenge's* own lifecycle. Status is computed
from plain `YYYY-MM-DD` string comparison against `$today` (passed in
once per invocation via `--arg`, not recomputed per challenge) — the same
lexical-date-comparison trick `blogs_list_command.sh`'s own
`--since`/`--until` handling already relies on. Never stored on disk —
purely a display-time computation, since "is this challenge currently
ongoing" changes on its own as time passes, unlike anything actually
persisted in the file.

## `challenges` commands (implemented)

`challenges create` (alias `new`) `[--id <id>] [--title <title>] [--start
<date>] [--end <date>] [--badges <specs> | --badge <spec>... | --no-badges]
[--blogs <specs> | --blog <spec>... | --no-blogs] [--no-goals]`,
`challenges list`, `challenges get [challenge_id] [--json]`, `challenges
edit <challenge_id> [--title <title>] [--start <date>] [--end <date>]
[--add-blog <spec>...] [--remove-blog <blog_id>...] [--add-badge
<spec>...] [--remove-badge <count>...]`, `challenges remove
[challenge_id...] [--all]`. Source: `src/bashly.yml`, one
`src/challenges_*_command.sh` per leaf command, same one-file-per-command
pattern `auth`/`blogs`/`books` use. **No nested `challenges blogs`/
`challenges badges` command groups any more** — those existed as a
three-level command tree (`challenges` > `blogs`/`badges` > `add`/
`remove`) in an earlier version of this design; per explicit direction,
managing a challenge's badge-linked blog posts and book-count badges is
now entirely folded into `edit`'s own flags instead (below), since it's
still fundamentally "changing a challenge," not a separate concern —
`edit <id> --add-blog <blog_id>:<name> --remove-badge <count>` now does
in one call what used to take two separate command invocations.

**`create`** parses `--start`/`--end` liberally via `date -d` (same as
`blogs list`'s own date flags), rejects an end-before-start window
up front, and delegates the actual id assignment + file write to
`gr::create_challenge`, printing the new id in a confirmation message
(there's no other way to learn a just-created challenge's id, since it's
assigned internally, not chosen by the caller).

**`--title`/`--start`/`--end` are all optional**, with defaults geared
towards "just keep making quarterly challenges" (`gr::default_challenge_*`
in `goodreads_challenges.sh`):

- **`--start`** continues right after the latest existing challenge's own
  end, if a hypothetical immediately-following challenge with
  automatically selected bounds would still be ongoing right now (one
  test, confirmed directly as covering both "the latest challenge is
  still ongoing" and "it recently ended" at once — no separate check for
  either). Otherwise, the start of the current calendar quarter (there's
  either no prior challenge, or the trail went cold long enough ago that
  picking back up from it doesn't make sense).

  **Fails outright instead — naming the actual conflicting challenge —
  if the latest existing challenge hasn't started yet ("planned")**,
  rather than trying either of the above: there's nothing sensible to
  chain off of yet, and falling back to the quarter start could just as
  easily land back on top of an *earlier* challenge instead. Confirmed
  directly: three successive no-arg `create` calls today (2026-09-19)
  create #1 (covers the current quarter) then #2 (chains right after #1
  into next quarter) — but #3's "latest" is #2, still merely *planned*
  today, so #3 fails with `error: the latest challenge (challenge 2,
  2026-10-01 to 2026-12-31) hasn't started yet -- can't auto-select
  --start from it. Pass --start explicitly.`, rather than silently
  falling back to a quarter start that would have collided with #1.
- **`--end`** is the next quarter-end (Mar-31/Jun-30/Sep-30/Dec-31) at or
  after `--start`, unless that's under 6 weeks away, in which case the
  one after that — e.g. `--start=2024-09-15` selects `2024-12-31`, not
  `2024-09-30` (only 15 days).
- **`--title`** becomes `"<Season> Challenge <year>"` when the actual end
  (given or selected) falls within one calendar month of a quarter-end
  *and* the challenge is at least 6 weeks long — both conditions, not
  either — else `"Unnamed Challenge"`. Season names are
  Winter/Spring/Summer/Fall for Jan-Mar/Apr-Jun/Jul-Sep/Oct-Dec
  respectively (explicit direction — not the Northern-Hemisphere
  calendar seasons). `<year>` is the *matched quarter-end's* own year,
  not necessarily the end date's — an end of `2025-01-15` is within a
  month of `2024-12-31` (Fall), so the title says `2024`.
- **`--badges`** is a comma-separated list of book-count badges to add
  right after creating the challenge, each entry either a bare `<count>`
  (unnamed) or `<count>:<title>` (each becomes its own
  `gr::add_challenge_count_badge "$id" "$count" "$title"` call), defaulting
  to `2:Page-Turner,3:Speed Reader,5:Book Boss` (`default_badges` in the
  command script — note the space in `Book Boss`, a real title, not a
  formatting mistake; the 3/5 titles were swapped from an earlier version
  that had them backwards — `3:Book Boss,5:Speed Reader` — per explicit
  correction, along with the existing real challenge(s) that had already
  been created with the mixed-up names). Each spec's count is
  validated as a positive integer *before* the challenge is created at
  all, so a bad value can't leave one half set up with only some badges
  applied. Deliberately has no `default:` in `bashly.yml` — bashly's own
  default-application applies the YAML default whenever the value comes
  out *empty*, not just when the flag is absent (confirmed directly), so
  a real `default:` there would silently turn an explicit `--badges ""`
  (the documented way to opt out of any badge, alongside `--no-badges`
  below) right back into the default. `[[ -v args[--badges] ]]` (checking
  the *key*, not the value) is what actually tells "never passed" apart
  from "passed as an empty string" — same trick `--blogs` (below) uses.

  **`--badge <count>[:<title>]`** is a repeatable alternative to `--badges`
  for the same `<count>[:<title>]` shape, one badge per occurrence
  (`--badge 2:Page-Turner --badge 5`) — mutually exclusive with `--badges`
  itself (both given is a plain usage error, checked explicitly, same
  "bashly doesn't enforce this itself" pattern used throughout this
  project). **Needs `eval` to reassemble, unlike every other repeatable
  flag/arg in this project** (`--blog`, `blog_id`, etc., all just
  space-word-split via a bare `for x in $y`): those never carry a space
  in any real value, but a badge title routinely does (`"7:Marathon
  Reader"`). bashly's own generated flag-parsing case already
  shell-escapes each repeated value with `printf '%q'` before
  space-joining them into `args[--badge]`, specifically so this is
  reversible — `eval "badge_specs=(${args[--badge]})"` is what actually
  un-escapes and re-splits it back into the original per-occurrence
  strings, verified directly with `--badge "2:Page Turner" --badge
  "7:Marathon Reader" --badge 10` round-tripping as three distinct badges,
  the two spaced titles intact.

  **`--no-badges`** disables the default outright, equivalent to `--badges
  ""` but without needing to know that trick. Combining it with an actual
  `--badges`/`--badge` isn't an error — checked explicitly, but only to
  print a warning to stderr and otherwise ignore `--no-badges`, then let
  the explicit badges win. **The warning names the actual flags
  involved, not a generic list of aliases** — `warn_superfluous_no_flag`
  (shared with the `--blogs` case below) checks `-v args[...]` on each of
  the two possible "no" flags separately (`--no-badges` and `--no-goals`
  can both genuinely be given at once) to build the "ignoring ..." half,
  and separately checks which of `--badges`/`--badge` is actually set
  (mutually exclusive with each other, so exactly one) for the "...,
  because ... was given explicitly" half — e.g. plain `--no-badges
  --badges 1` warns `ignoring --no-badges, because --badges was given
  explicitly`, while `--no-badges --no-goals --badges 1` (both "no" flags
  at once) warns `ignoring --no-badges and --no-goals, because --badges
  was given explicitly`. Never mentions a flag the user didn't actually
  type. Explicit badges win since giving real badges already implies "not
  the default" on its own,
  `--no-badges` genuinely adds nothing in that case, and there's no
  actually-conflicting *intent* here worth hard-erroring over (unlike
  `--badges`/`--badge` given together, which really are two different,
  incompatible ways of saying what the badges should be — that combination
  still is a real error, above). `badge_specs`' own resolution
  (`challenges_create_command.sh`) checks `--badge`/`--badges` *before*
  `$no_badges` for exactly this reason — explicit input wins outright, the
  warning is purely informational.
- **`--blogs`** is the same `<id>`/`<id>:<title>` shape as `--badges`
  (comma-separated, no `default:` in `bashly.yml` for the same reason,
  same `[[ -v ]]` trick), with the same repeatable `--blog <id>[:<title>]`
  alternative (mutually exclusive with `--blogs`, same %q/eval round-trip
  to survive a spaced title — see `--badge` above, the exact same
  reasoning applies verbatim). Two differences from `--badges`, though:

  - **Every explicitly given post (`--blogs`/`--blog`, never the computed
    default below) is fetched via plain `gr::blog_json "$blog_id"`** —
    from cache if already there (cheap: the blog cache has no TTL, see
    "Blog post cache" above), a real network fetch otherwise — both to
    confirm it actually exists (a bad id fails the whole `create` with
    `error: could not fetch blog post <id>`, before the challenge itself
    is created, same "validate everything before creating anything"
    ordering `--badges`' count check already follows) and, when no
    `<title>` was given, to default to the post's own `.title` (`jq -r
    '.title // empty'` on the fetched JSON — empty for a
    `removed_remotely` stub, which has no title, same as giving no title
    explicitly). `gr::add_challenge_blog "$id" "$blog_id" "$blog_title"`
    then gets a real name either way, not left unnamed the way a bare
    numeric id used to leave it.
  - Its **default list** (when neither `--blogs` nor `--blog` is given at
    all) is computed instead of fixed
    (`gr::default_challenge_blogs`), and those auto-selected posts are
    *not* additionally fetched/named this way — they already came from a
    cache scan (so existence is a given) and are added unnamed, same as
    before this change; only posts the user actually names on the command
    line get the fetch-and-default-title treatment.

  `gr::default_challenge_blogs`: every *cached* blog post (can't
  discover ones never fetched) published within
  `GR_CHALLENGE_BLOG_WINDOW_BEFORE_START_DAYS` (7) days before `--start`
  through `GR_CHALLENGE_BLOG_WINDOW_BEFORE_END_DAYS` (14) days before
  `--end` **or today, whichever is earlier**, whose `challenge_potential`
  is at least `GR_CHALLENGE_BLOG_DEFAULT_MIN_POTENTIAL` (0.7) — the raw
  likelihood score itself, not `gr_challenge_status`'s derived (and
  manually overridable) boolean, since this is specifically a
  *likeliness* threshold, and deliberately a higher bar than
  `goodreads_blogs.sh`'s own `GR_CHALLENGE_POTENTIAL_THRESHOLD` (0.5,
  which decides whether a post counts as a challenge listing at all, a
  different question from whether to auto-link it to a brand new one).
  This needs `--start`/`--end`/today already resolved, so it's decided
  later in the command file than `--badges` is, even though it's
  declared right after it in `bashly.yml`.

  **The today cap is deliberate, not just a convenience**: real
  challenges reveal their badges and backing posts gradually over their
  own run (confirmed directly — a challenge created today typically has
  only 3-5 of its eventual badges/posts known, with the rest revealed
  later, sometimes well after the post for a later badge is even
  published), so a post for a badge that hasn't been revealed yet
  genuinely doesn't exist to be found — scanning past today is
  meaningless, not just imprecise. This only *reduces* how much
  `gr::default_challenge_blogs` can find, on top of the already-known
  limitation that `challenge_potential` can't reliably predict the real
  editorial curation on Goodreads' own (auth-walled) challenge hub page
  at all (confirmed directly against real data: structurally-identical
  posts, published the same day, one curated in and one not, with no
  discoverable distinguishing feature). Both limitations point the same
  way: treat this default as a rough, correctable starting point, not
  an authoritative answer — `challenges edit --add-blog`/`--remove-blog`
  (and `--add-badge`/`--remove-badge`) are the real mechanism for keeping
  a challenge's badges/posts in sync as more get revealed over its
  lifetime.

  **`--no-blogs`** disables the default outright, equivalent to `--blogs
  ""` but without needing to know that trick — same "superfluous, not
  conflicting" treatment as `--no-badges` above when combined with an
  actual `--blogs`/`--blog`: a warning to stderr, then the explicit list
  wins (`blogs_given` — set from either flag — is checked before
  `$no_blogs` in the blog-resolution `if`/`elif` chain, same ordering
  principle).

**`--no-goals`** is a plain shorthand for `--no-badges --no-blogs`
together — `no_badges`/`no_blogs` (the command script's own two local
flags, set from `args[--no-badges]`/`args[--no-blogs]`) are both forced to
`1` up front whenever `args[--no-goals]` is set, *before* either flag's own
superfluous-combination check against `--badges`/`--badge`/`--blogs`/
`--blog` runs — so `--no-goals` alongside any of those four triggers the
exact same warning `--no-badges`/`--no-blogs` alone already would, and
still names only the flags actually typed (`warn_superfluous_no_flag`
checks `args[--no-goals]` directly, same as `args[--no-badges]`/
`args[--no-blogs]` — it doesn't matter *which* local variable a "no" state
came from, only which literal flags are actually present in `args`), e.g.
plain `--no-goals --badge 2` warns `ignoring --no-goals, because --badge
was given explicitly` — never mentioning `--no-badges` at all, since it
was never typed. Either way, the explicit badges/blogs still win. No
separate `--no-goals` branch exists anywhere past that
point — every later check/branch in the command script only ever looks at
`$no_badges`/`$no_blogs`, never at `args[--no-goals]` directly.

Two GNU `date` quirks confirmed directly while building this, both now
baked into `gr::last_day_of_prev_month`/`gr::last_day_of_next_month` and
`gr::days_between`:
- A single chained relative-date string (`"$d +1 day +1 month -1 day"`)
  is *not* applied strictly left-to-right — for `2024-03-31` it gives
  `2024-05-01`, not the intended `2024-04-30`. Only re-parsing an
  already-resolved intermediate date at each step (three separate
  `date -d` calls) gets the "1 month after, clamped to that month's own
  last day" result the "end near a quarter" check needs (matching the
  worked example: a challenge ending `2024-04-30` is a "Winter Challenge
  …", one month after `2024-03-31`).
- A plain local-time `epoch / 86400` day-count is off by a day across a
  DST transition (e.g. `2024-03-25` to `2024-04-01` in `Europe/Berlin`
  comes out as 6, not 7 — that week is actually 23 hours short there).
  `gr::days_between` pins both endpoints to UTC (`date -u`) to avoid this.

**`gr::challenges_overlapping`** additionally refuses the whole creation
if an *auto-selected* `--start` (never an explicit one — that's the
documented way to force a window regardless) would still produce a
window overlapping an existing challenge, naming the collision. Per the
reasoning above, this shouldn't actually be reachable through `create`'s
own defaulting any more (the "planned latest" case that used to trigger
it now fails earlier, with a more specific message — see `--start`
above); it's kept as a genuine safety net regardless, e.g. against
manually edited challenge files or a future change to the defaulting
rules, and was verified directly against a hand-crafted overlapping
challenge file.

**`list`** has no filtering/paging flags at all, unlike `books`/`blogs`
list — deliberately: challenges are few and manually curated, so there's
no "most recent N" or discovery-pagination concern driving a cap the way
there is for books/blog posts. Sorted by `start` (chronological, the
natural reading order for a list of time-windowed challenges) rather than
alphabetically (`books`) or by recency (`blogs`). Columns: `id, title,
start, end, status, blogs, badges` (`blogs`/`badges` are each entry's own
list length, `id` and both counts right-aligned).

**`get <challenge_id>` — the id is optional, per explicit direction.**
Omitted, it defaults to `gr::next_ending_challenge` (`goodreads_challenges.sh`)
— the existing challenge with the smallest `.end` that's still `>=` today,
i.e. the next one to actually finish, covering both a currently *ongoing*
challenge and a still-*planned* one uniformly (whichever ends soonest
wins, regardless of which of those two states it's actually in — verified
directly: a `planned` challenge ending sooner than an already-`ongoing`
one is correctly preferred). If none qualify (every existing challenge
has already ended), falls back to `gr::latest_challenge` — the one with
the largest `.end` overall, i.e. the most recently ended one — same
function `challenges create`'s own `--start` auto-defaulting already
uses. If there are no challenges at all, neither function returns
anything and this fails outright: `error: no challenges yet. Run
'goodreads challenges create' to add one.` Both helpers return
`"<id>\t<start>\t<end>"`; only the `<id>` field is actually used here
(`IFS=$'\t' read -r id _ _`), the rest exists for `gr::default_challenge_start`'s
own use of `gr::latest_challenge`. This defaulting runs *before*
`gr::require_challenge_file`, so an explicitly-given id is still
validated exactly as before — the new logic only ever fires when the
argument is omitted entirely.

**`get`**'s default pretty rendering follows the same "`{meta, ...}`
object from one jq call, formatted in bash" shape `books get` uses:
`meta` is `[title, "<start> to <end> (<status>)"]`; `blogs` and `badges`
are each their own indented table (same `column -t -R 1` plus
`sed 's/^/  /'` shape `books get`'s own `series` table uses) — `blogs`'
columns are `blog_id, name (or "(unnamed)"), url` (the url built fresh as
`"https://www.goodreads.com/blog/show/" + .blog_id`, same "no bare
missing-field placeholder" stance as everywhere else in this project);
`badges`' columns are `count, name (or "(unnamed)")`. Neither table is
printed at all when its list is empty — same "nothing printed when
there's nothing to show" rule `books get`'s own `series` table follows.
`--json` behaves the same as `books get --json`/`blogs get --json`: `cat`s
the on-disk file directly.

**`edit`** requires at least one of `--title`/`--start`/`--end`/
`--add-blog`/`--remove-blog`/`--add-badge`/`--remove-badge` (a bare
`challenges edit <id>` with nothing to change is a plain usage error,
checked explicitly) — folding badge-linked-blog and book-count-badge
management into `edit` this way, rather than the separate `challenges
blogs`/`challenges badges` nested command groups an earlier version of
this design had, was per explicit direction: managing them is still just
"changing a challenge," and a single `edit` call can now do several
unrelated changes at once (rename it, add a blog, drop a badge) instead
of needing one invocation per concern. Re-validates the *resulting*
window before writing anything when `--start`/`--end` are involved —
whichever of the existing/updated start and end actually apply after
this edit — not just a changed pair in isolation: editing only `--end`
still has to stay after the *existing*, unchanged `start`, and vice
versa. `gr::update_challenge` itself does the actual `--title`/`--start`/
`--end` field merge (see above); only invoked at all when at least one of
those three was actually given, so a call that's *purely* about blogs/
badges (e.g. `edit <id> --remove-badge 3`) never touches those fields.

- **`--add-blog <blog_id>[:<name>]`** / **`--add-badge <count>[:<name>]`**
  (both repeatable) use the exact same `<spec>[:<name>]` shape and
  `%q`/`eval` round-trip `challenges create`'s own `--blog`/`--badge`
  flags do (see there for why a plain word-split doesn't survive a name
  containing a space) — parsed, and for `--add-badge` validated (count
  must be a positive integer, same `^[1-9][0-9]*$` pattern used
  throughout this project) *before* any write happens, same "a bad entry
  can't leave the rest of this edit half-applied" principle `create`
  follows. Each spec becomes its own `gr::add_challenge_blog`/
  `gr::add_challenge_count_badge` call (an upsert — adding an id/count
  already on the challenge just replaces its name in place, see above),
  reported per item (`<id> -> blog <blog_id> added/updated ("<name>")`,
  or without the parenthetical when no name was given).
- **`--remove-blog <blog_id>`** / **`--remove-badge <count>`** (both
  repeatable) — `--remove-badge`'s own values are validated as positive
  integers up front too, for the same "don't half-apply this edit"
  reason (a malformed `--remove-badge` fails the whole command before
  anything — including any `--title`/`--add-blog`/etc. given in the same
  call — is written, confirmed directly). Each removal reports its own
  per-item outcome (`<id> -> blog <blog_id> removed` or `<id> -> blog
  <blog_id> not on this challenge`, mirroring `gr::remove_challenge_blog`/
  `gr::remove_challenge_count_badge`'s own return-1-if-absent shape) plus
  its own summary line (`Removed N blog(s).`, `Removed N badge(s).`) —
  same "best-effort across the list, report the tally" shape `blogs
  remove`'s own multi-id loop uses; the whole command exits 1 if *any*
  requested removal wasn't actually present, same as `blogs remove`.
- Add and remove operations for the same kind (blogs or badges) can be
  combined freely in one call (e.g. `edit <id> --add-blog 123 --remove-blog
  456`) — adds are applied first, then removals, then the two kinds'
  removal tallies print in blog-then-badge order; nothing about the
  ordering is semantically load-bearing (an add and a remove can never
  target the same key in one call in a way that would make order matter),
  it's just the order the command happens to process things in.

**`remove`** (renamed from `delete`, per explicit direction — same as
`blogs`/`books remove` below) is the same shape `books`/`blogs remove`
already use (`challenge_id...` or `--all`, mutually exclusive, an error
if neither is given, per-id outcome plus a summary, exits 1 if anything
requested wasn't found) — nothing challenge-specific to say about it
beyond substituting `gr::challenge_dir`/`gr::challenge_file` for their
book/blog equivalents. There's no counter state to roll back or leak —
`gr::generate_challenge_id` checks the real files on disk (see above), so
removing a challenge frees its id for reuse by a later `create` that
happens to land on the same `<year>Q<quarter>`/`<year>-<counter>` id,
rather than a freshly re-created challenge always getting a brand new one.

## Open design questions

- Still unused from `apolloState`'s Book/Work entries: affiliate/purchase
  links (`.details.links` — commercial, not descriptive, probably skip),
  `characters`/`places` (Work-level, content-ish but more borderline —
  `{name, webUrl}` and `{name, countryName, webUrl, year}` respectively),
  `choiceAwards` (Work-level, a separate array from `awardsWon` — empty on
  both books tried so far, shape unconfirmed), `bestBook` ref (Work-level —
  resolves to the edition Goodreads considers "best/most popular"; a
  possible alternative to `canonical_url`, which can be a bit
  arbitrary/inconsistently formatted). `bookFormat`/`numberOfPages` are
  still JSON-LD-only (not pulled from apolloState too) — revisit if JSON-LD
  ever turns out unreliable for them. `editions.webUrl` deliberately
  **not** added — trivially constructible as
  `https://www.goodreads.com/work/editions/<work.legacyId>` now that
  `work.legacyId` exists, so persisting it separately would just be
  redundant.
- Whether/when to auto-resolve+cache the *canonical* edition's own JSON
  when a requested book's `canonical_url` points elsewhere (deliberately
  not done automatically yet — see above).
- Command surface for shelves and reading progress (books, blogs, and the
  challenge-metadata surface itself are all done — see their own sections
  above).
- How challenge-*goal* book selection logic should work — i.e. actually
  picking specific books toward a badge, once `challenges` has recorded
  which blog posts/book-counts a challenge cares about. `challenges`
  itself only manages that metadata; it doesn't select or recommend any
  books yet.
- What settings actually belong in the config file, and whether/how a
  `config` command group should expose them.
