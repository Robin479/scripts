# CLAUDE.md — bashly/goodreads

This file provides project-specific guidance to Claude Code for the `goodreads`
bashly project. It's layered on top of the repo-wide `CLAUDE.md` at the repo
root, which covers the `make`/`bin`/`bashly` build machinery.

## Purpose

`goodreads` interacts with the goodreads.com website: scraping book details,
reflecting on reading challenges (identifying current challenges and
selecting books to read towards their goals), and managing shelves and
reading progress.

Status: `auth` (login-session management) and the book metadata cache
(schema.org JSON-LD + our own fields, no CLI surface yet) are implemented.
Shelves, reading progress, and reading-challenge support are not designed
yet.

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

  **Minimum request spacing** (`gr::throttle <url>`, called right before
  every actual `curl` invocation in `gr::http_get` — including retries, not
  just the first attempt): sleeps if needed so that returning from this
  function never happens sooner than a random point between
  `http_request_delay_min` and `http_request_delay_max` seconds (config
  keys, seconds; defaults 1/5, in `GR_HTTP_REQUEST_DELAY_MIN_DEFAULT`/
  `GR_HTTP_REQUEST_DELAY_MAX_DEFAULT` — renamed from the original
  `min_request_delay`/`max_request_delay` to match the `http_`-prefixed
  naming already used by `http_retry_delays`) after this same function's
  own *previous* return — a separate, always-on mechanism from the
  WAF-challenge backoff above, meant to avoid triggering that
  burst-then-block behavior in the first place rather than recovering from
  it. Default lowered from an initial 5/10 to 1/5 after two real 10-book
  batches at 1/5 (once the fake-slug URL, see below, was already in place)
  both completed with zero WAF challenges — suggestive that the fake slug
  is what's actually avoiding the challenge, making the wider spacing
  unnecessary, but not conclusively isolated (both changes landed close
  together; not yet tested at 1/5 without the fake slug, or vice versa).
  The target URL
  is passed in ($1) but currently only used for the log message — a hook
  for possible future per-host pacing, not implemented. State (the
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
  (`GR_USER_AGENT`, `GR_HTTP_RETRY_DELAYS_DEFAULT`,
  `GR_HTTP_REQUEST_DELAY_MIN_DEFAULT`/`GR_HTTP_REQUEST_DELAY_MAX_DEFAULT` — this is the
  convention to follow for any new constant added here, not scattered next
  to whichever function happens to use it), then `gr::generic_cookie_jar`/
  `gr::init_cookie_jar`, then `gr::throttle`, then `gr::http_get`;
  `goodreads_auth.sh` holds the
  account/session functions; `goodreads_books.sh`
  holds the book-cache functions; `config.sh`/`ini.sh` are bashly's own
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
work here. Instead, `gr::config_get`/`gr::config_set`
(`src/lib/goodreads.sh`) wrap the real ones and set
`CONFIG_FILE="$(gr::data_dir)/config.ini"` on every call — always call these
`gr::`-prefixed wrappers, never `config_get`/`config_set` directly, or
`--data-path` gets silently ignored.
Keys are dotted (`section.key`) INI-style;
`gr::config_get key.name [default]` / `gr::config_set key.name value`.
No CLI command exposes this yet, and no actual settings have been designed
(next step) — this is scaffolding only, verified by driving the wrapper
functions directly (round-tripped a value, confirmed the `[section]`/`key =
value` file format, confirmed it persists correctly across separate
processes).

The directory key is the **numeric id only**, never `<id>-<username>`.
Goodreads usernames can change; the username is still captured in
`profile.json`, just never used as a filesystem/storage key. Re-running
account identification (re-`auth import`) refreshes `profile.json` without
touching the account's directory name or any already-cached data.

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

## Book metadata cache (implemented — no CLI surface yet, see below)

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

There's no CLI command exposing any of this yet — `gr::book_json` was built
purely as the internal caching primitive; a `book` command group (or
whatever surfaces it) is next-step work.

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
- Command surface for books, shelves, reading progress, and reading-challenge
  scraping.
- How challenge-goal book selection logic should work.
- What settings actually belong in the config file, and whether/how a
  `config` command group should expose them.
