# CLAUDE.md — bashly/goodreads

This file provides project-specific guidance to Claude Code for the `goodreads`
bashly project. It's layered on top of the repo-wide `CLAUDE.md` at the repo
root, which covers the `make`/`bin`/`bashly` build machinery. Tried-out and
discarded designs, superseded behavior and the incidents behind the current
design live in `DESIGN-HISTORY.md` next to this file.

## Purpose

`goodreads` interacts with the goodreads.com website: scraping book details,
reflecting on reading challenges (identifying current challenges and
selecting books to read towards their goals), and managing shelves and
reading progress.

Status: implemented, each with a CLI surface — `auth` (login-session
management), `books` (book metadata cache: schema.org JSON-LD + our own
fields; `fetch`/`list`/`get`/`remove`), `blogs` (blog post cache;
`fetch`/`list`/`get`/`remove`/`challenge`), `challenges` (manually curated;
`create`/`list`/`get`/`edit`/`remove`, plus `challenges blogs`/`badges
add`/`remove`) and `config`. Not designed yet: shelves, reading progress,
and the challenge-*goal* book-selection logic (picking specific books toward
a badge) — `challenges` only manages a challenge's own metadata (title, time
window, badge-linked blog posts, book-count badges).

The blog post cache is groundwork for reading-challenge support: challenge
detail data (which books count toward which badge) is locked behind a
step-up-auth requirement no long-lived session can satisfy (see "Blog post
cache"), so the plan is human-in-the-loop — scrape and flag candidate blog
posts, let the user confirm which challenge they belong to — rather than
fully automated association.

## Architecture

### HTTP: `gr::http_get`

- **Interaction stack**: `curl` for HTTP, `xidel` for HTML/XML parsing and
  extraction, `jq` for JSON. No other scraping/HTTP libraries.
- **All HTTP GETs go through `gr::http_get <url>`** (`src/lib/http.sh`) —
  never call `curl` directly for a GET. It prints the response body to
  stdout and nothing else; the caller decides what to do with it.
- **Fails (return 1, no body)** on `--offline` (checked before touching the
  network, so transitive callers like `gr::refresh_book` need no check of
  their own), on transport errors, and on a non-2xx final status. curl's
  `--fail` is *not* used: the status is checked by hand, *after* the
  bot-challenge classification, so a challenge delivered with a 4xx status
  is still recognized (and retried) as one.
- **Env inputs, prefix form** (`VAR=... gr::http_get "$url"`):
  - `COOKIE_JAR` — jar for `-c`/`-b`; empty = cookie-less request (see
    "Cookie jar" below).
  - `GR_HTTP_EXPECT` — optional ERE a 2xx body must match. Book and blog-post
    fetches pass `GR_HTTP_EXPECT_CANONICAL` (a `<link ... rel=canonical>`,
    which their parsers start from), so a non-book page is retried as a
    challenge instead of failing in the parser with "no canonical link
    found".
- **Response headers** go to `<data_dir>/.last_response_headers` (`-D`,
  all redirect hops). Inside the data dir, not `/tmp`, because the Docker
  curl fallback only bind-mounts the data dir. Classification looks only at
  the *final* response block (`gr::final_response_headers`: after the last
  `HTTP/` line of the `-L` chain, CRs stripped).
- **Bot-challenge classification** (goodreads.com is fronted by AWS WAF via
  CloudFront). A response is a challenge if any of:
  - an `x-amzn-waf-action` header (any status);
  - HTTP 202, 429 or 503;
  - a 2xx with an empty body;
  - a 2xx body not matching `GR_HTTP_EXPECT`.

  What a WAF challenge looks like: HTTP 202, `x-amzn-waf-action: challenge`,
  and either an empty body (plain curl) or a ~2.4 KB JS-challenge
  interstitial (`window.gokuProps`, `challenge.js` from
  `*.token.awswaf.com`, `AwsWafIntegration.getToken()`, a "verify that
  you're not a robot" `<noscript>`) — served to curl-impersonate since it
  looks like a browser that could run it. 202 is a "success" status, so
  neither `--fail` nor an empty-body check alone catches every form.
  History: see DESIGN-HISTORY.md › WAF challenge detection.
- **On a challenge**: `gr::pace_report challenge "<description>"`, the body
  is saved quietly as `.last_bad_response.*` (latest only), and the request
  is retried — spaced purely by the shared pacer (below), there is no
  per-URL sleep. It gives up when the pacer sets `GR_PACE_GIVE_UP`
  (`http_challenge_max_probes` failed probes in the incident, counted across
  processes, so a parallel process's failed probes count too); then it
  `touch`es `gr::blocked_marker_file` (`<data_dir>/.last_request_blocked`)
  and fails with a message pointing at `.last_bad_response.{html,headers}`.
  `max_attempts = 2 * (max_probes + 1)` is only a per-call safety net.
- **On a non-challenge response**: removes the blocked marker,
  `gr::pace_report ok`, then returns the body (2xx) or fails (non-2xx).
- **`gr::save_bad_response <body> [quiet]`** copies a body plus the last
  headers to `<data_dir>/.last_bad_response.{html,headers}`. Besides the
  quiet call on every challenge, `gr::refresh_book`/`gr::refresh_blog` call
  it (non-quiet, with a `note:` on stderr) when a page still lacks a
  canonical link, so unparseable pages can be diagnosed instead of vanishing
  with their `mktemp` file.
- **`gr::http_status <url>`** prints just the final status code (used by
  `gr::refresh_blog` to tell a 404 from other failures). It goes through
  `gr::throttle` but doesn't classify or `gr::pace_report` its response, so
  it doesn't show up in `.pacing.log`.

### Request pacing (`src/lib/http_pacing.sh`)

Static, configurable parameters around the two bot-detection mechanisms the
test-run data showed; nothing is learned across incidents (user decision,
after three real test runs — don't reintroduce adaptive tuning without new
evidence). History of the adaptive designs and the test runs: see
DESIGN-HISTORY.md › Request pacing. Run data and READMEs:
`~/.goodreads/research/pacing/run-*/` (machine-local, not committed).

**Two distinct waits, deliberately named apart** (user decision; neither is
called "delay", which fit both):
- **Request interval** — being a good citizen: minimum time between the
  starts of any two requests, from any process. Avoids the burst detector.
- **Challenge pause / probe pause** — serving the penalty after a bot
  challenge, for every process. Waits out a block; doesn't change the tempo.

**What the data showed (why the design is what it is):**
- *Burst detection* on a scale of ~10s: gaps of 0.7s and random 1-5s got
  blocked, 5-7.5s never were.
- *A clock-based challenge* after ~5.2 min of activity (sometimes ~10.2 min,
  ≈ 2×), independent of tempo: runs lasted ~5.2 min at 5s *and* 7.5s
  intervals. The block lasts just under 5 min (measured 293-298s); 30s or
  120s pauses never ended one, 300s usually did.
- Blocks have ragged ends: they may let 1-3 single requests through, then
  resume.
- The site sometimes escalates (a 21-minute block with let-throughs around
  13:00, likely load-shedding near midday). User decision: don't cater for
  that beyond making sure it can't permanently degrade the mitigation.
- Why not adaptive: every interval raise was a misfire (the clock-based
  challenge fires regardless of tempo), costing books per cycle; learning
  the block length degenerated during an escalation (learned 21, then 43
  minutes, from incidents that swallowed let-throughs and our own over-long
  pause).
- Expected throughput in the normal regime: ~50 books per 5.2-min run, then
  a 5-min pause — roughly 290 books/h.
- A new run may start with an early challenge: a block left over from a
  previous run that ended mid-block (deleting `.pacing` resets our side, not
  the site's), or the site's cycle phase.
- Still open: what drives the ~5-min rhythm. We never solve the JS challenge
  (the jar has no `aws-waf-token`), and `logged_out_browsing_page_count`
  stays constant (2 over 242 pages), so neither explains it.

**Mechanics:**
- **Burst avoidance**: `http_request_interval` (default 5s) plus 0-50%
  random jitter (`GR_HTTP_PACE_JITTER_PCT`) between request starts, any
  process. No raising/relaxing/floor/idle decay.
- **Incident**: an incident's first challenge pauses every process for
  `http_challenge_pause` (default 300s). Each further challenge in the same
  incident is a failed *probe* pausing `http_challenge_probe_pct` (default
  10%) of the time since the incident's first challenged request (minimum
  1s, `GR_HTTP_PACE_PROBE_MIN_MS`) — probes spread out gradually instead of
  overshooting a block that usually ends within minutes. After
  `http_challenge_max_probes` (default 30, ≈ 1.5h from a 300s start) failed
  probes, `gr::http_get` gives up (`GR_PACE_GIVE_UP`) and `gr::run_fetch`'s
  circuit breaker stops the run. A pause is only ever extended, never
  shortened, by a later challenge.
- **Incident end**: only after 3 successes in a row
  (`GR_HTTP_PACE_INCIDENT_END_SUCCESSES`) spanning at least 2 min
  (`GR_HTTP_PACE_INCIDENT_END_MS`), since a block can let single requests
  through, then resume; a challenge before that belongs to the same
  incident. The ending success logs `incident ended: blocked Ns, M failed
  probe(s)` (blocked = first challenged request → first of the ending
  successes). The next incident starts from the same fixed pause, so no bad
  phase on the site's side can degrade the mitigation beyond one incident.
- **Forgotten incidents**: an open incident with no activity (last request
  or pause end) for 30 min (`GR_HTTP_PACE_INCIDENT_FORGET_MS`, e.g. a run
  killed mid-block) is dropped, so a much later challenge starts fresh
  instead of counting as a probe with an enormous "time waited".
- **Stale responses**: a response to a request started *before* the last
  recorded challenge (e.g. parallel processes all hitting the same block)
  belongs to an already-recorded incident: it changes no state (no new
  challenge, not a success) and is only logged, with a `stale-` prefix.
- Every caller waits this out, including `auth status`'s live check —
  patience matters more than a fast failure (user decision). A caller that
  needs a shorter worst case gets different config values for its run, not
  a lower global default.

**Shared state**: `<data_dir>/.pacing` (key=value, integers, times in epoch
ms; field list at the top of `http_pacing.sh`), read-modify-written only
under `flock` on `.pacing.lock` (`gr::pace_locked`; unlocked if `flock`
isn't installed), written atomically via temp file + `mv` — so sequential
*and parallel* goodreads processes share one pacer. Missing/garbled values
default to 0/empty; unknown fields (from an older version) are dropped on the
next save, so the format is forward-compatible. Config keys are re-read on
every claim/report, so a `config set` takes effect on the next request, even
in a running process.

- `gr::throttle` (before every curl call in `gr::http_get`/`gr::http_status`,
  retries included) claims the next slot: waits until both `next_ms` and
  `cooldown_ms` have passed, then sets `next_ms = now + interval + jitter`.
  It re-checks after every sleep and never holds the lock across one, so a
  slot another process took, or a pause it recorded meanwhile, is honored.
  Routine interval waits are silent (they fire on almost every request and
  would otherwise flood a `fetch` status line — History: see
  DESIGN-HISTORY.md › Throttle message); a challenge pause is shown via
  `gr::term_status` (`waiting Ns -- bot-challenge pause (<challenge>)` or
  `... probe k/max failed ...`, possibly caused by another process). It
  ends with `return 0` because `gr::term_clear_line` fails off a terminal
  and would leak under `set -e`. `$1` (URL) is unused — a hook for possible
  per-host pacing.
- `gr::pace_report ok|challenge [description]` records a classified
  response (under the lock).

**Diagnostics — never used to decide a wait** (user decision, to help
uncover the bot detection's actual parameters):
- The state tracks the current and previous streak of same-kind responses
  (`streak_*`/`prev_streak_*`: kind, start/end, request count, min/avg/max
  actual gap between request starts, any process).
- `<data_dir>/.pacing.log`: append-only TSV with a header line, one line per
  classified response. Columns:
  - `time` — local time the response was recorded
  - `request_ms` — epoch ms the request started (its claimed slot)
  - `pid` — the goodreads process (`$$`)
  - `first` — 1 = that goodreads process's first request; its gap includes
    idle time between commands, not just pacing
  - `outcome` — `ok`/`challenge`; `stale-` prefix for a straggler of an
    already-recorded incident
  - `gap_ms` — time since the previous request start, any process (`-` if
    none)
  - `interval_ms` — the configured interval
  - `cooldown_s` — the pause imposed by this response (0 for ok), ms
    precision
  - `streak` — current streak as `kind:length`, e.g. `ok:12`
  - `note` — challenge description, or `incident ended: blocked Ns, M failed
    probe(s)`

  ~100 bytes per request; rotated (user decision) to `.pacing.log.1`,
  replacing the previous one, at 10 MB (`GR_PACE_LOG_MAX_BYTES`) — at most
  ~20 MB, ~200k requests of history.
- `first` can't be a plain variable: `gr::run_fetch` runs each item in its
  own subshell, where variables don't survive. It's decided against a short
  list of recent PIDs in the state (`instances`, max 16); `$$` is the main
  process's PID in every subshell.

### curl binary auto-detection (`gr::init_curl_cmd`)

Shared by `gr::http_get`/`gr::http_status`. Exists to use
[curl-impersonate](https://github.com/lwthiker/curl-impersonate)
automatically when available: a patched curl build that replicates a real
browser's TLS handshake (cipher suites, extension order, GREASE values) and
HTTP/2 frame settings, addressing AWS WAF's TLS/JA3-fingerprint layer —
plain curl's TLS signature is immediately recognizable as non-browser.
**Not a full fix**: no plain HTTP client, curl-impersonate included, can
pass AWS WAF's JS challenge (no JS engine to mint the `aws-waf-token`
cookie). It only makes the heuristic layers trigger less often — same
category as the fake book slug and request pacing, not a replacement for
challenge handling.

Priority order (user decision):
1. The `curl_bin` config key, if set at all — an explicit choice always
   wins, whatever it is (a binary name or a full command line).
2. The first of `GR_CURL_IMPERSONATE_CANDIDATES` found on `$PATH`
   (curl-impersonate's wrapper names: newest Chrome first, then Edge,
   Firefox, Safari last — the Safari wrappers only approximate Safari via
   the Chrome/BoringSSL binary; there's no genuine Apple-TLS port).
3. A `docker run` command crafted fresh per process around
   `GR_CURL_IMPERSONATE_DOCKER_IMAGE`'s `GR_CURL_IMPERSONATE_DOCKER_WRAPPER`,
   if `docker` is on `$PATH` *and* its daemon answers (`docker info`).
4. Plain `curl` (`GR_CURL_BIN_DEFAULT`), if on `$PATH`.
5. Else `error: no usable curl found -- install curl, curl-impersonate, or
   Docker`.

- `-A "$GR_USER_AGENT"` is added only when the resolved command is literally
  plain `curl`: impersonate targets bake in a User-Agent matching their fake
  TLS handshake plus other Chrome-shaped headers, and a different UA on top
  would itself be the kind of mismatch bot detection looks for.
- `curl_bin` may be a full command line (e.g. `docker run --rm -u 1000:1000
  -v /home/kai/.goodreads:/home/kai/.goodreads
  lwthiker/curl-impersonate:0.6.1-chrome curl_chrome116`): it's
  whitespace-split via `read -a` into `GR_CURL_CMD`, not `eval`ed — enough
  for a docker-run-style line, and it's the user's own local config, so no
  injection concern.
- **Memoized per process** (`GR_CURL_CMD_RESOLVED`), resolved lazily on the
  first network call — most commands never touch the network. **The
  memoization doesn't survive a subshell**, and `gr::run_fetch` runs each
  item's `fetch_fn` inside `$(...)`, so resolving there would re-probe
  (e.g. `docker info`) once per item. Hence `books_fetch_command.sh`/
  `blogs_fetch_command.sh` call `gr::offline || gr::init_curl_cmd || exit 1`
  *before* `gr::run_fetch`: subshells forked afterwards inherit the resolved
  arrays (a fork copies all shell state; an `exec`'d process would only see
  exported, never array, variables). Any future command that loops over
  network calls in subshells must do the same.
- **Docker specifics**:
  - `lwthiker/curl-impersonate:latest` is the **Firefox** build (`curl_ff*`
    only); the Chrome build needs the exact `0.6.1-chrome` tag, hence
    `GR_CURL_IMPERSONATE_DOCKER_IMAGE`.
  - A bind mount is required: `--rm` discards the container filesystem,
    including the cookie jar curl wrote, so without one the host jar silently
    stays empty. It must land at the *same absolute path* (`-v
    <data_dir>:<data_dir>`) so the literal `$COOKIE_JAR` and headers-file
    paths resolve on both sides — which is why the command is crafted per
    process from `gr::data_dir` (a hand-written `curl_bin` can't follow
    `--data-path`).
  - `-u $(id -u):$(id -g)`: the container runs as root by default, so
    anything written into the mount would come back root-owned (same fix as
    the repo `Makefile`'s dockerized bashly).
- **Installing curl-impersonate locally** (case 2): prebuilt release
  tarballs (e.g. `curl-impersonate-v0.6.1.x86_64-linux-gnu.tar.gz`) ship the
  real binary (`curl-impersonate-chrome`) plus browser-specific wrapper
  scripts (`curl_chrome116`, ...) that find the binary via `$0`'s directory —
  extract both into the same directory, and put it on `$PATH` for
  auto-detection (`command -v` only checks bare names). A copy lives in the
  repo's gitignored `.local/bin/` (same local-override convention as
  `.local/bin/bashly`), **not on `$PATH` by default** — used via an explicit
  `curl_bin` in practice. `curl_chrome116 --version` reports BoringSSL. A
  `curl_bin` pointing at a nonexistent path fails loudly with that path (no
  silent fallback).
- Set via `goodreads config set curl_bin <value>`; back to auto-detection via
  `goodreads config unset curl_bin`.

### Cookie jar and `before_hook`

- The cookie jar is **not** a parameter: `gr::http_get` reads `COOKIE_JAR`,
  set as a one-off prefix (`COOKIE_JAR=path gr::http_get "$url"`). An empty
  `COOKIE_JAR` means a cookie-less request — picking a default is
  deliberately not `gr::http_get`'s job.
- The default comes from `gr::init_cookie_jar` (`src/lib/http.sh`): sets the
  global `COOKIE_JAR` to `gr::generic_cookie_jar` unless already set. Called
  exactly once, from `before_hook()` (`src/before.sh`, bashly's `hooks`
  library, `bashly add hooks`), so it's set before any command runs and
  account-less consumers (`gr::refresh_book`, future ones) needn't call it.
  `before_hook` is the right hook because it runs after argument parsing
  (`gr::data_dir` needs `--data-path`); `initialize()` runs before it — too
  early. `src/initialize.sh`/`src/after.sh` were deleted (unused; bashly
  documents them as safe to delete).
- `gr::generic_cookie_jar`: a shared, account-less jar at
  `<data_dir>/cookies.txt` (created empty on first use), separate from any
  account's `accounts/<id>/cookies.txt`.
- `gr::identify_account_from_cookiejar` passes an explicit `COOKIE_JAR=`
  prefix (its account's jar) per call — that per-call override is what the
  env var is for.

### Shared library layout

`src/lib/*.sh`, all sourced automatically by bashly. Split by topic as each
area was built — follow the same pattern for future areas (shelves,
progress) rather than growing one file.
- `goodreads.sh` — generic bits used everywhere: `gr::data_dir`,
  `gr::offline`, the `gr::config_*` wrappers, status-line/terminal helpers
  (`gr::fetch_quiet`, `gr::status_line*`, `gr::term_*`), `gr::run_fetch`.
- `http.sh` — everything HTTP-request-specific. All `readonly` constants
  grouped at the very top (`GR_USER_AGENT`, `GR_CURL_BIN_DEFAULT`,
  `GR_CURL_IMPERSONATE_CANDIDATES`, `GR_CURL_IMPERSONATE_DOCKER_IMAGE`/
  `_WRAPPER`, `GR_HTTP_EXPECT_CANONICAL`) — the convention for any new
  constant, rather than next to whichever function uses it; then the cookie
  jar functions, `gr::init_curl_cmd`, `gr::http_get`, `gr::save_bad_response`,
  `gr::http_status`.
- `http_pacing.sh` — `gr::throttle`/`gr::pace_report` and the shared pacing
  state; its constants (`GR_HTTP_REQUEST_INTERVAL_DEFAULT`,
  `GR_HTTP_CHALLENGE_*_DEFAULT`, `GR_HTTP_PACE_*`, `GR_PACE_*`) likewise at
  its top.
- `goodreads_auth.sh` (account/session), `goodreads_books.sh` (book cache),
  `goodreads_blogs.sh` (blog post cache), `goodreads_challenges.sh`
  (challenges).
- `goodreads_config.sh` — the `config` command group's user-facing registry
  (`GR_CONFIG_KEYS`, `gr::config_describe`, `gr::config_default_display`);
  its own file since it's specific to the `config` commands, not needed by
  every area.
- `config.sh`/`ini.sh` — bashly's own library (`bashly add config`),
  untouched and wrapped rather than modified, so `bashly add config` can
  refresh them later. `send_completions.sh` is bashly-generated too.

### Local state and login sessions

- **Local state**: cached data lives in typed `*.json` files in a
  database-like directory structure under the data directory (see below).
- **Login sessions**: some actions require being logged in, others don't —
  implicit to each action, never specified by the caller. A
  login-requiring command calls `gr::require_current_account`
  (`src/lib/goodreads_auth.sh`) and gets the current account id or a clear
  error.
  - A logged-in session is represented by a cookie file.
  - There is a "current account", managed by the `auth` subcommands.
    Establishing a session (`auth import`) always *identifies the account
    from the session itself* — never from user input — and makes it current.
  - Session-specific data (shelves, reading progress, etc.) and the
    session's cookie file live together in an account-specific subfolder —
    the data directory is partitioned per account, not just a flat cache.

## Global flags

- `--data-path` — see "Data directory" below.
- `--offline` — skip live network access and use only cached data.
  `gr::http_get`/`gr::http_status` refuse with an error under it (so every
  network-backed operation fails fast rather than fetching);
  `gr::cookies_state` (`auth status`) reports `present (not checked —
  offline)` instead of a live check; the `fetch` commands skip curl
  auto-detection. Any future live "is this still good" check should respect
  it the same way.

## Data directory

Resolved by `gr::data_dir` (`src/lib/goodreads.sh`, created if missing), in
order: the `--data-path` global flag, else `$GOODREADS_DATA`, else
`~/.goodreads`. Layout:

```
$data_dir/
  config.ini                  # INI config (bashly's config library -- see below)
  cookies.txt                 # generic/account-less cookie jar (gr::generic_cookie_jar)
  current                     # plain text: id of the current account; absent = none selected
  .pacing, .pacing.lock       # shared request-pacing state + its flock file
  .pacing.log, .pacing.log.1  # TSV history of every classified response (diagnostics), rotated at 10 MB
  .last_response_headers      # headers (all hops) of the latest gr::http_get attempt
  .last_bad_response.{html,headers}  # latest challenge / unparseable page
  .last_request_blocked       # present while the latest request gave up on bot challenges (circuit breaker)
  .blogs_discovery_marker     # newest blog post id seen by the last successful discovery
  accounts/
    <id>/
      cookies.txt             # curl/Netscape cookie jar; absent/removed = logged out
      profile.json            # {"id", "username", "profile_url", "identified_at"}
      shelves/ ...            # future
      progress/ ...           # future
  books/
    <id>.json                 # one-line JSON cache of book <id> -- see "Book metadata cache"
  blogs/
    <id>.json                 # blog post cache -- see "Blog post cache"
  challenges/
    <id>.json                 # challenge definition -- see "challenges"
  research/                   # machine-local research data (e.g. pacing/run-*), not used by the code
```

**Account directories are keyed by numeric id only**, never
`<id>-<username>`: usernames can change. The username is still captured in
`profile.json`; re-`auth import` refreshes that without touching the
directory name or cached data.

### Config file

`config.ini` at the data directory root (`.ini` matches bashly's default
`CONFIG_FILE` name). Installed via bashly's built-in library (`bashly add
config` → `src/lib/config.sh` + `src/lib/ini.sh`, untouched). Its functions
work off a global `CONFIG_FILE` normally set once in a hook, but
`initialize()` runs before argument parsing, so `--data-path` isn't known
yet. Instead `gr::config_get`/`gr::config_set`/`gr::config_del`/
`gr::config_keys` (`src/lib/goodreads.sh`) set
`CONFIG_FILE="$(gr::data_dir)/config.ini"` on every call — **always use the
`gr::` wrappers**, never `config_get`/etc. directly, or `--data-path` is
silently ignored. `gr::config_get key [default]` / `gr::config_set key
value`; keys may be dotted (`section.key`) INI-style.

**Keys** (`GR_CONFIG_KEYS`, `src/lib/goodreads_config.sh`):

| key | default | meaning |
|---|---|---|
| `curl_bin` | auto-detected | curl command (see "curl binary auto-detection") |
| `http_request_interval` | 5 | min seconds between request starts, all processes, + 0-50% jitter |
| `http_challenge_pause` | 300 | seconds paused after an incident's first challenge |
| `http_challenge_probe_pct` | 10 | a failed probe pauses this % of the time waited in the incident |
| `http_challenge_max_probes` | 30 | give up on a request after this many failed probes |
| `fetch_max_consecutive_failures` | 3 | a `fetch` run stops after this many failures in a row (0 disables) |
| `book_cache_ttl` | 8640000 (100 days) | seconds a cached book counts as fresh for `fetch --all` |

Defaults live in constants next to their code (`http_pacing.sh`'s
`GR_HTTP_REQUEST_INTERVAL_DEFAULT`/`GR_HTTP_CHALLENGE_*_DEFAULT`,
`goodreads.sh`'s `GR_FETCH_MAX_CONSECUTIVE_FAILURES_DEFAULT`,
`goodreads_books.sh`'s `GR_BOOK_CACHE_TTL_DEFAULT`), passed at each
`gr::config_get` call site — the default-in-a-constant-plus-config-key
pattern to follow for new keys (and add them to `GR_CONFIG_KEYS`,
`gr::config_describe`, `gr::config_default_display`, and the `config
get`/`unset` completion list). Former key names are history only (see
DESIGN-HISTORY.md › Request pacing); none was given a fallback.

**`goodreads config {list,get,set,unset}`**:
- `unset`, not `remove`/`rm` like the other groups' deletion verb: a
  setting reverting to its default reads like `git config --unset`/`env
  -u`, not "removing" something.
- `GR_CONFIG_KEYS` is purely a catalog of every key goodreads reads, not a
  second source of truth for behavior. `gr::config_describe`/
  `gr::config_default_display` are case statements, not parallel arrays, so
  a key missing from one fails loudly instead of silently misaligning by
  index. They drive `config list`'s description and effective-default
  display.
- `config set` on an unknown key still works (plain `gr::config_set`
  passthrough) but prints a `note:` first — a warning, not an error, since
  the registry is a documentation aid, not a schema.
- `config unset --all` clears every key currently *set* (via
  `gr::config_keys`, the real on-disk keys), not every key in
  `GR_CONFIG_KEYS`.
- Tab completion of `get`/`unset`'s `key` is a hand-kept static word list,
  not derived from `GR_CONFIG_KEYS`: the generated completions script
  doesn't source the app's libs. It's attached to the command, since
  bashly `args:` entries can't carry `completions:` (only commands and
  flags can). **`config set` deliberately has no completions**: a
  command-level `completions:` block applies to *every* positional argument
  of that command, so it would offer key names as candidate *values* too.

### Command-group defaults

Every command group's `list` is its `default: force` command in
`bashly.yml` — `auth`, `blogs`, `books`, `challenges`, `config` (user
decision: "make list the default in all groups"). `default: force` (not
`default: true`) is what runs the command when the group is invoked with no
further tokens at all; plain `default: true` only covers an unrecognized
token falling through (bashly `v1.4.0`, `examples/command-default-force/`).
Safe since no `list` has a required argument. Group-level `--help` is
unaffected (marks the default `(default)`); bare top-level `goodreads` still
shows the root help.

### Tab completion: alias filtering

bashly's generated `send_completions` (`lib/send_completions.sh`, vendored,
never hand-edited) lists a command's long form and its alias (`ls`/`rm`/
`new`) side by side, with no YAML key to suppress it. The filter lives
repo-wide, not here: `bash-completion.d/.template.sh.in` (repo root) parses
each project's `long:short` pairs from its `bashly.yml` at shell startup
and re-registers completion with a wrapper that drops an alias whenever its
long form is also a candidate. This project's `src/completions_command.sh`
is plain `send_completions`. General recipe: `~/.claude/rules/bashly.md`.
A short form still completes once typed far enough that the long form no
longer matches (`blogs rm` → only `rm`).

## `auth` commands (implemented)

`auth import <cookie_file>`, `auth status [account]`, `auth list`, `auth
switch <account>`, `auth logout [account]`. No `auth login` — see below.
Source: `src/bashly.yml`, `src/lib/goodreads_auth.sh` (shared helpers),
`src/auth_*_command.sh` (one per leaf command).

**No automated credential login — don't attempt this again.** Goodreads'
"Sign in with email" is Amazon's Login-With-Amazon (LWA) portal
(`goodreads.com/ap/signin/<request-id>`). A real browser's login POST sends
no plaintext `password`, but `encryptedPwd` (client-side-encrypted) and
`metadata1` (an opaque device/behavior fingerprint), both computed by
Amazon's JS. Reproducing them means reverse-engineering Amazon's
anti-automation layer — not something to build, whoever's account it is.
`auth import` (a cookie file from a real browser session) is the only
supported way to start a session. History: see DESIGN-HISTORY.md › Login
automation.

**Account identification** (`gr::identify_account_from_cookiejar`): GET the
authenticated homepage and take the profile-menu link:
`(//a[contains(@class,"dropdown__trigger--profileMenu")])[1]/@href` →
`/user/show/<id>-<username>`. `dropdown__trigger--personalNav` alone is
ambiguous (shared by at least the notifications and profile-menu triggers).
If identification ever breaks (markup change), that's the one selector to
fix.

**bashly runs under `set -e`**: a non-zero command substitution in a bare
`x="$(fn)"` aborts the script before any following `if [[ -z "$x" ]]` runs.
So:
- helpers that signal "not found"/"nothing yet" (e.g. `gr::current_account`)
  always `return 0` — use `if/fi`, not `test && cmd` (a false test leaks a
  non-zero status; an `if` with no taken branch is exit 0);
- calls that legitimately fail (e.g. `gr::identify_account_from_cookiejar`)
  are guarded as `if ! x="$(fn)"; then ...`.

Keep this in mind for every new command.

**A `# shellcheck disable=...` as the literal first line of a file applies
to the entire file** (documented shellcheck behavior: a directive before the
first command is file-wide). The `# shellcheck disable=SC2154 # args is
bashly's global associative array` in the command fragments (`args` is
defined in the generated wrapper, invisible when linting a fragment) is
therefore preceded by a no-op `: # no-op, keeps the shellcheck directive
below line-scoped`. Whenever a shellcheck directive is a file's first line,
check it isn't suppressing that check file-wide — invisible in `make
lint-bashly` output precisely because it's a suppression.

**Session lifetime**: don't hardcode one. curl's Netscape cookie format
stores each cookie's expiry (5th column) — read it rather than guessing. On
the one account checked, Amazon's auth tokens (`at-main`, `sess-at-main`)
and most other cookies (`session-id`, `ubid-main`, `sst-main`, `x-main`,
`lc-main`) were valid for about a year; `_session_id2` (Rails' rolling
per-visit cookie, not the auth proof) only for hours. `auth status`'s live
check is how the tool actually finds out, per account.

**Live session check** (`auth status`, default on): `gr::cookies_state`
(`src/lib/goodreads_auth.sh`) — if the account's `cookies.txt` exists, it
copies the jar to a temp file and runs `gr::identify_account_from_cookiejar`
against the copy (never mutating the stored jar), reporting `valid`,
`expired or invalid — run 'goodreads auth import' to refresh`, or a
mismatch warning if the jar resolves to a different account. No jar →
`missing (logged out ...)`; `--offline` → `present (not checked —
offline)`. Always returns 0 (state is in the printed string) — same
`set -e` rule as above.
## Book metadata cache (implemented — CLI surface: `books`, see below)

Source: `src/lib/goodreads_books.sh`.

**Book URLs** (`gr::book_url <id>` → `https://www.goodreads.com/book/show/<id>`):
the title slug goodreads.com normally shows (`.../199698485-the-god-of-the-woods`)
is decorative — the id-only URL returns the same page (same `<title>`, same
`<link rel="canonical">`, which always carries a full slug regardless). So
book URLs are always built from the id alone. Book pages need no login:
fetched with the generic, account-less cookie jar `before_hook()` already
sets `COOKIE_JAR` to.

**Fake slug on the actual request.** `gr::refresh_book` fetches
`"$(gr::book_url "$id")-$(gr::random_book_slug)"` (e.g.
`.../show/<id>-a-blue-box`) so the request looks like normal browser
traffic rather than a bare numeric id. Deliberately done at the call site,
not inside `gr::book_url` — URL construction and this cosmetic concern stay
separate, and other callers don't necessarily want a fake slug.
`gr::random_book_slug` builds a random but grammatical three-word phrase:
- first word: `the` (then singular or plural at random), `a`/`an` (singular;
  `an` before a vowel-initial adjective), or a number word `one`..`twelve`
  (singular only after `one`);
- second: a generic adjective (colors, sizes, textures, `old`/`new`, ...);
- third: a generic object noun (`box`, `chair`, `lamp`, ...), pluralized
  when the first word requires it.

Consequence: the `.query.book_id` sanity check (below) compares only the
numeric prefix, since the route segment is `<id>-<slug>`.

**`gr::book_json <id> [--force]`** is the internal entry point: prints
one-line JSON for a book, backed by the on-disk cache `books/<id>.json`.
- Freshness: `gr::book_fresh <id>` — true if the file exists and is younger
  than `book_cache_ttl` **seconds** (top-level `config.ini` key via
  `gr::config_get`; default `GR_BOOK_CACHE_TTL_DEFAULT` = 100 days — book
  metadata rarely changes, and every scrape costs throttling risk). The age
  check is one `find "$book_file" -newermt "$threshold"` against a
  precomputed `date -d "-N seconds"` threshold (empty output = stale),
  after a plain `[[ -f ]]` existence check. The `|| true` on the `find`
  assignment stays: a `find` error must not trip `set -e`.
  `gr::book_fresh` is factored out so `books fetch` can ask "fresh?"
  separately (see `force` policies below).
- If not fresh (or `--force`), it **always** calls `gr::refresh_book`,
  checked with `|| return 1` (see the `set -e` lesson below). It doesn't
  check `--offline` itself (`gr::http_get` refuses then), and never falls
  back to stale or missing data when a refresh fails.
- Neither function holds the book JSON in a shell variable:
  `gr::refresh_book` writes straight to a file, and `gr::book_json`'s
  `jq -c . "$book_file"` both emits the guaranteed-one-line output and
  doubles as a validity check.
- **The cache file itself is pretty-printed with sorted keys** (`jq -S`, no
  `-c`) so `books/<id>.json` is human-readable and diffs cleanly between
  refreshes; only `gr::book_json`'s output is compacted. Don't add `-c` to
  the write side.

**`gr::refresh_book <id>`** fetches the page (`gr::http_get` with
`GR_HTTP_EXPECT="$GR_HTTP_EXPECT_CANONICAL"`, so a 2xx page without a
canonical link counts as a bot challenge — see Architecture), always
fetches when called (no freshness logic of its own — the wrapper decides
*whether*, refresh just does), creates `books/` itself (`mkdir -p`, so it
also works standalone), and prints the cache file path on success. It
builds the book JSON from three sources:

1. **Our own fields** — `book_id` (the requested id, a string per this
   project's id convention) and `canonical_url` (`<link rel="canonical">`;
   see below for how it differs from `url`). A missing canonical link is an
   error and saves the page via `gr::save_bad_response`.
2. **Next.js page data** (`<script id="__NEXT_DATA__">`), used for:
   - **Sanity check**: `.query.book_id` is the Next.js route parameter that
     served the page; its numeric prefix (up to the first `-`) must equal
     the requested id, checked *before* anything is cached. This really
     catches mismatches (wrong URL construction, a redirect, a misdirected
     fetch) that would otherwise be cached under the wrong id.
   - **Book-level fields**: `.props.pageProps.apolloState` is a
     GraphQL-normalized cache with one `"Book:<ref>"` entry per book
     referenced *anywhere* on the page (e.g. "other editions" widgets), so
     pick the entry whose `.legacyId` matches the requested id. Fields:
     - `legacyId` — kept as a native JSON number (the source's type; cheap
       insurance in case it ever diverges from the string `book_id`).
     - `url` — `.webUrl`, this edition's own self URL (always the
       requested id).
     - `title` — `.title`, the *clean* title without series annotation
       (JSON-LD's `name` keeps the annotation, see below).
     - `description` — `["description({\"stripped\":true})"]` (bracket
       access: that's the GraphQL query-cache key verbatim). Deliberately
       the stripped variant; the plain `description` contains raw HTML
       (`<br />`, `<b>`), and this pipeline keeps markup out of string
       values.
     - `published` — `.details.publicationTime`, *this edition's* date.
     - `publisher`, `asin` — `.details.*` as-is.
     - `isbn`, `isbn10`, `isbn13` — `isbn` is always an array: the
       cleaned, non-empty, **deduped** union of `.details.isbn` and
       `.details.isbn13`, sorted longest first (`[]` if neither exists).
       `isbn10`/`isbn13` are its 10-/13-character entry, or absent. Dedup
       matters because Goodreads fills `.details.isbn` with the same
       13-digit value as `.details.isbn13` for editions without a true
       ISBN-10 (e.g. POD edition `229004405`), so `isbn10` is either a real
       ISBN-10 or absent, never a copy of `isbn13`. The rationale also
       lives as a comment inside the jq program.
       History: see DESIGN-HISTORY.md › Book cache: ISBN fields.
     - `genres` — array of slug strings from each
       `.bookGenres[].genre.webUrl` (e.g. `"harry-potter"` from
       `.../genres/harry-potter`); the slug alone is enough, no name/url
       objects.
     - `series` — from `.bookSeries[]`: bind `.userPosition` to a variable
       *before* resolving `.series.__ref` to its `"Series:..."` entry
       (otherwise it's lost once `.` becomes the Series object), giving
       `{name: .title, series_id, url: .webUrl, position}`. `position` is
       this book's index in that series (e.g. `"1"`); `series_id` is the
       leading digits of the series `webUrl` (`45175` from
       `.../series/45175-harry-potter`).
     - `contributors` — `.primaryContributorEdge` +
       `.secondaryContributorEdges[]` as `{role, name, url}` (`role` e.g.
       `"Author"`/`"Illustrator"`/`"Translator"` — JSON-LD's `author` has
       no roles). **Deliberately not included**: the rest of each
       `Contributor:` entry, notably its `description` (a full HTML author
       biography, several KB for a well-known author) — author metadata,
       not book metadata; skip unless an author entity is built later.
   - **Work-level fields, nested under `work`** (the original creative work,
     via the book's `.work.__ref`). Nested, not flat-merged, *because* they
     are scoped to the work rather than this edition:
     - `work.legacyId` — the Work's own id (native number), different from
       the book's; without it nothing says which work `work.*` describes.
     - `work.url` — `.details.webUrl`.
     - `work.title` — `.details.originalTitle` (named to parallel `title`;
       nesting already says "the work's", so no `original_` prefix).
     - `work.published` — `.details.publicationTime`, the work's first
       publication, which can predate the edition's `published` by decades.
     - `work.awards` — `.details.awardsWon[]` as `{award_id, name, url,
       date, designation, category}`: `award_id` = leading digits of the
       award `webUrl` (`159` from `.../award/show/159-mythopoeic-fantasy-award`),
       `date` = `.awardedAt` as a year, `designation` as-is
       (`"WINNER"`/`"NOMINEE"`), `name` whitespace-squeezed (source has
       double spaces), `category` only if genuinely present — the source
       has both `null` and `""` for "none", so each award object goes
       through `drop_empty` (drops `null` *and* `""`), not just
       `drop_nulls`.
     - The top-level `awards` field is JSON-LD's own folded string (e.g.
       `"Mythopoeic Fantasy Award Children's Literature (2008), ..."`),
       left untouched; the structured data lives at `work.awards`, so the
       two never collide. History: see DESIGN-HISTORY.md › Book cache:
       awards placement.
   - **`clean_or_null` on every apolloState string that reaches the
     output** (`title`, `description`, `contributors[].name`,
     `series[].name`, `work.title`, award `name`, ISBN values):
     `squeeze_ws` (collapse whitespace runs, trim) plus `""` → `null` so
     `drop_nulls` drops it. Needed because apolloState wins the final merge
     (below): JSON-LD's own cleanup pass can't help a field apolloState
     also provides, and apolloState has real dirty values (e.g.
     `"James  Patterson"`). Applied at each field's construction site, not
     as a post-merge pass. (`publisher`/`asin`/urls are not cleaned.)
   - **Epoch-ms timestamps are converted per field, matching real
     precision**: `published`/`work.published` → `YYYY-MM-DD`
     (`epoch_to_date`; these carry genuine day precision, e.g. Harry
     Potter's `work.published` = `1997-06-26`); award `date` → `YYYY` only
     (`epoch_to_year`; `awardedAt` is always `<year>-01-01`, a placeholder,
     and Goodreads itself only displays a year). Don't switch awards to
     full dates — that would be fabricated precision.
   - **id-from-URL extractions** (`series_id`, `award_id`, genre slugs) use
     `capture(...)` wrapped in `try ... catch null`, so a surprising URL
     degrades to a missing value instead of failing the whole refresh.
   - **Absent fields are dropped, not kept as `null`** (`drop_nulls`,
     applied to the top level and separately to `work` before nesting).
     Arrays survive that filter: `series`, `genres`, `contributors`,
     `isbn`, `work.awards` are present as `[]` when empty — "no awards" is
     meaningful data, not an absent field. (A book's `work.title` may equal
     its `title`; not a rule to special-case.)
3. **The page's schema.org/Book JSON-LD** (`<script type="application/ld+json">`),
   through a `jq 'walk(...)'` cleanup of every string: squeeze whitespace
   runs (Goodreads' markup has e.g. `"Liz    Moore"`) and decode
   `&lt; &gt; &quot; &#39; &apos; &amp;` (Goodreads leaves literal entities
   even inside the `<script>` block). Source of `name` — **left exactly as
   Goodreads provides it**, series annotation included (e.g. `"The Giver
   (Giver, #1)"`); `title` is the clean alternative. What schema.org/Book
   alone provides: `name`, `image`, `bookFormat`, `numberOfPages`,
   `inLanguage`, `awards` (folded string), `author` (array of
   `{"@type": "Person", name, url}`), `aggregateRating`, sometimes `isbn`.
   `numberOfPages`/`aggregateRating`/`bookFormat` are JSON-LD-only (see
   Open design questions).

**`canonical_url` vs `url` — don't conflate them.** `canonical_url` is the
*work's* preferred edition and **can be a different book id** than the one
requested (e.g. id `25098993`, "Das Herz des Piraten", has a canonical URL
for id `1744452`, in the older `<id>.Title_With_Underscores` slug style;
`url`/webUrl uses the newer `<id>-title-with-dashes` style). `url` is always
this edition's own URL, matching the requested id (guaranteed by the sanity
check). "The edition someone read" → `url`; "the work in general" →
`canonical_url`. The canonical edition is deliberately **not**
auto-resolved/cached (it would silently turn one lookup into two fetches
under a different id, with no consumer needing it yet — see Open design
questions).

**Merge**: `{book_id, canonical_url} * $ld[0] * $apollo[0]` — flat, except
the nested `work`; JSON-LD first, apolloState last, so apolloState wins any
key collision (jq's `*` lets the right operand win). No collision exists
today (`isbn` is also apolloState's and wins; `awards` no longer collides),
but the order stays as cheap insurance. `@context`/`@type` are kept, so the
result is still valid JSON-LD, just extended with our own fields (a plain
`url` property is standard schema.org; `@id` is intentionally not used).

**Failure handling in `gr::refresh_book`**:
- All five temp files (HTML, cleaned JSON-LD, `__NEXT_DATA__`, the
  apolloState sub-object, the final JSON) are created up front and removed
  by **one** `trap ... EXIT` — traps replace each other rather than
  stacking, so one trap per `mktemp` would only clean up the last file.
- Every stage that can fail (fetch, canonical link, `__NEXT_DATA__`, id
  check, apolloState match, JSON-LD, final build) is checked explicitly and
  returns 1 *before* the final `mv`; the final build also fails on an empty
  result (`|| [[ ! -s "$tmp_book" ]]`). Each error message is preceded by
  `gr::term_clear_line` so it never garbles a live status line (see
  `books fetch`).
- **Lesson: don't rely on ambient `set -e` for correctness that must hold
  however a function is called.** A caller using the function inside
  `&&`/`||`/an `if` condition disables `errexit` for the whole nested call
  chain, and `jq -c .` on an empty file exits 0 with empty output — so
  implicit-only checks let a failed refresh silently blank a good cache.
  Check explicitly wherever a silent wrong success (not just a crash) would
  be the failure mode. History: see DESIGN-HISTORY.md › Book cache: `set -e`
  and silent cache blanking.
- Testing: prefer replaying a saved page over hitting the live site
  repeatedly — each real request risks the bot challenge (see
  Architecture).

## `books` commands (implemented)

`books fetch [book_id...] [--blog|-b <blog_id>...] [--challenge <challenge_id>]
[--all|-A] [--update|-U] [--batch|-B]`, `books list|ls [book_id...] [--limit|-l n]`
(the group's default command), `books get <book_id> [--json|-J]
[--update|-U]`, `books remove|rm [book_id...] [--all|-a]`. Source:
`src/bashly.yml` plus one `src/books_*_command.sh` per leaf command, thin
wrappers over `gr::book_json`/`gr::book_fresh`/`gr::book_dir`/`gr::book_file`.

Completions: `books list`/`get` offer cached book ids at command level
(bashly `args:` entries can't carry `completions:`, only commands and flags
can); `books fetch --blog` and `--challenge` offer cached blog/challenge ids
on the flag itself. These `ls "${GOODREADS_DATA:-$HOME/.goodreads}/..."`
candidates ignore a `--data-path` on the same command line (honoring it
would mean parsing `COMP_WORDS`).

### `books fetch`

**No discovery, unlike `blogs fetch`** — no goodreads.com page lists "all
books"; a book only becomes known through an explicit id. So `fetch` takes
ids from: explicit `book_id...`, `--blog <blog_id>` (repeatable; every book
in that post's `book_sections`), `--challenge <challenge_id>` (every book in
any blog post linked to that challenge), or `--all` (every cached book). The
first three combine and are deduped (`sort -n -u`) into one pool — books
repeat across posts (a challenge's posts share many books), so the dedup
matters; `--all` is mutually exclusive with them; none of the four is a
usage error.

**`--challenge`** resolves the challenge's `.blogs[].blog_id`
(`gr::require_challenge_file`, same lookup and `error: no challenge <id>` as
`challenges get`), merges them into the `--blog` ids (deduped), then goes
through the exact same `--blog` expansion — no separate code path. A
challenge without linked posts prints `note: challenge <id> has no linked
blog posts` (like `--blog`'s `note: blog post <id> has no books to
extract`) — a valid empty result, not an error. A blog post that can't be
fetched (`gr::blog_json` fails) aborts the command.

**`force` policy** (`force_policy`, computed once, passed to `fetch_one` via
`gr::run_fetch`) — a string, not a boolean, because `--all` needs a third
behavior (user decision: only touch the network when an id needs it):
- **`""`** (explicit ids, no `--update`): cached at any freshness → skipped
  (`-> already cached`, exit 2); missing → `gr::book_json "$id"` (`->
  fetched`).
- **`"force"`** (`--update`, with or without `--all`): always
  `gr::book_json "$id" --force`; `-> refreshed` if it was cached, `->
  fetched` otherwise.
- **`"ttl"`** (`--all` without `--update`): every cached book is checked
  via plain `gr::book_json "$id"`, which refetches only if stale.
  `fetch_one` calls `gr::book_fresh` first purely to report `-> already
  cached (fresh)` (counted as skipped) vs. `-> refreshed` —
  `gr::book_json`'s return value can't tell the two apart.

So `--update`/`-U` is the only way to bypass a book's TTL on demand; `--all`
alone honors it. **`-A`/`-U` are capitals on both `books fetch` and `blogs
fetch`** so they read consistently (user decision); other commands' `--all`
stays `-a`. History: see DESIGN-HISTORY.md › `books fetch`: rename
from `update` and default changes. There is no `removed_remotely` outcome for books
(`gr::refresh_book` has no such concept, unlike blog posts).

Summary line: `Fetched/refreshed N book(s), N already cached, N failed[, N
not attempted].`; exits 1 if the run stopped early.

**`get --update`/`-U`** forces `gr::book_json "$id" --force` — the
single-item way to bypass the TTL.

### Fetch progress: status line (shared with `blogs fetch`)

Progress is a single self-updating status line, not a scrolling per-id
list; `--batch`/`-B`, or stdout not being a terminal, suppresses it (user
decision). Helpers in `lib/goodreads.sh`, nothing books/blogs-specific:

- **`gr::fetch_quiet <batch_flag>`** — **succeeds** (exit 0) when the line
  should be suppressed: `--batch` given, or `[[ ! -t 1 ]]` (a `\r`-based
  line would corrupt a redirected/piped log). Communicates via exit status,
  not stdout. Call it exactly as
  `quiet=""; if gr::fetch_quiet "${args[--batch]:-}"; then quiet=1; fi`:
  - never `quiet="$(gr::fetch_quiet ...)"` — inside a command substitution
    stdout is the capture pipe, so `[[ -t 1 ]]` would always be false and
    the line would never draw;
  - never a bare `gr::fetch_quiet ... && quiet=1` — its exit status is 1 in
    the normal interactive case, which trips `set -e`.
  History: see DESIGN-HISTORY.md › Fetch status line (round three).
- **`gr::status_line <message> <quiet>`** — `\r\033[K` (clear to end of line,
  so a shorter message leaves no tail) + message, no newline, to stdout;
  no-op when quiet.
- **`gr::status_line_clear <quiet>`** — clears the line without replacing
  it; no-op when quiet.
- **`gr::term_clear_line`** / **`gr::term_status <msg>`** — the stderr
  counterparts for generic code (`gr::http_get`, `gr::throttle`,
  `gr::refresh_*`) that can't see any command's `--batch` state: they check
  `[[ -t 2 ]]` themselves. `gr::term_status` overwrites in place on a
  terminal, else prints a normal persisted line (a log keeps every
  message). Deliberately not threaded through `$quiet` — wrong layer; the
  only cost is a no-op clear sequence on an interactive terminal under
  `--batch`.
- **`gr::run_fetch <quiet> <fetch_fn> <force> <id...>`** — the per-id loop.
  Shows `[<n>/<total>] <id>...` *before* each call (visible while a slow
  fetch runs) and `[<n>/<total>] <outcome>` after, when there is one.
  **Calling convention for `fetch_fn`** (`fetch_fn <id> <force> <quiet>`):
  return 0 = ok, 2 = skipped, anything else = failed; print outcome text
  to stdout on 0/2; on failure print nothing to stdout and report to
  stderr. `fetch_fn` runs inside `outcome="$(...)"`, i.e. a subshell with
  stdout captured, so:
  - it must receive `quiet` as an argument (its own `[[ -t 1 ]]` would be
    false);
  - state memoized inside it doesn't survive — hence both fetch commands
    call `gr::init_curl_cmd` up front, before `gr::run_fetch`;
  - anything it prints to stdout, including its own `gr::status_line_clear`
    before `-> failed`, lands in the captured outcome rather than on the
    terminal; the line is in practice already cleared by the
    `gr::term_clear_line` preceding every error in
    `gr::http_get`/`gr::refresh_*`.
  The call sits in an `if` so a non-zero return (routine `2` = skipped)
  doesn't abort the command under bashly's `set -e`.
  Totals: `$GR_FETCH_OK`/`$GR_FETCH_SKIPPED`/`$GR_FETCH_FAIL`, plus
  `$GR_FETCH_ABORTED` = number of ids never attempted, **empty (not 0)**
  unless the run stopped early, so callers use it as a flag
  (`${GR_FETCH_ABORTED:+, N not attempted}` in the summary, exit 1; `blogs
  fetch --all` also skips its second pass).
  **Stops early** right after a failure that left `gr::blocked_marker_file`
  behind (bot-challenge retries exhausted — the next item would only sit
  through the same backoff), or after `fetch_max_consecutive_failures`
  failures in a row (config key, default
  `GR_FETCH_MAX_CONSECUTIVE_FAILURES_DEFAULT=3`, `0` disables; catches
  unparseable pages not recognized as a challenge). A success resets the
  streak; a skip neither resets nor counts. A marker left from an earlier
  run is removed at the start. Re-running resumes, since cached ids are
  skipped. Totals are left to the caller because call sites word their
  summaries differently (`blogs fetch` prints up to three).
  **Ends by clearing the line, not with a newline** (user decision), so the
  caller's summary, printed immediately after, replaces the last status
  update.

**Live messages during a fetch** — `fetch_one` sends only stdout to
`/dev/null` (`gr::book_json ... > /dev/null`) and never captures stderr, so
anything explaining a slow call shows live. Current division of labor:
- routine pacing waits are silent (`gr::throttle`);
- a bot-challenge cooldown wait is shown via `gr::term_status` by
  `gr::throttle`, overwriting in place (see Architecture);
- conclusive failures (`gr::http_get`'s give-up message, every `error:` in
  `gr::refresh_book`/`gr::refresh_blog`) are preceded by
  `gr::term_clear_line` and printed as persisted lines — added
  unconditionally, since every error path is reachable from the fetch loop.
History: see DESIGN-HISTORY.md › Fetch status line.

### `books list`

- **Sorted by title, not by date** (unlike `blogs list`): a book's
  `published` is the edition's date, not when it entered the cache, so
  there's no meaningful recency order. Sort key: `title // name`,
  case-insensitive (`ascii_downcase`).
- Columns (user decision): `id, published, author(s), title, pages, rating,
  url`; `id` and `pages` right-aligned (`column -t -R 1,5`). No `series`
  column (keeps the table narrow; `books get` shows it) and no challenge
  column (books have no such field).
  - `author(s)`: all `contributors[].name` joined, `trunc_authors(30)`.
  - `title`: `strip_tagline`, then `trunc(60)`.
  - `pages`: `.numberOfPages`; `rating`: `.aggregateRating.ratingValue`,
    bare number (no `★`, no count — little room); `?` when absent (also for
    `published`).
  - `url`: built fresh as `"https://goodreads.com/book/show/" + .book_id`
    (id only, no slug, no `www.` — requested short form; a book URL works
    identically without `www.`, unlike a blog URL), not the cached `.url`,
    which carries a title slug.
- **`trunc(n)`** replaces the cut tail with a single `…` (not `...`), so a
  truncated value never exceeds `n`.
- **`trunc_authors(n)` cuts at a name boundary** (user decision): if the
  joined list fits, unchanged; if even the first name alone exceeds `n`,
  plain `trunc(n)` on the whole string (the one allowed mid-name cut);
  otherwise the longest prefix of whole names that fits, plus `", …"` (e.g.
  `"Alan Moore, David Lloyd, Steve Whitaker, Siobhan Dodds"` at 40 →
  `"Alan Moore, David Lloyd, Steve Whitaker, …"`).
- **`strip_tagline`** (user-suggested heuristic, not a real parse — a
  tag-line can't be reliably told from a title containing a colon): drop
  from the *first* colon on only if the whole title is longer than 30
  characters **and** the part before the colon is shorter than the part
  after (a real tag-line is normally the longer half). E.g. `"Stupid TV, Be
  More Funny: How the Golden Era of The Simpsons Changed Television—and
  America—Forever"` → `"Stupid TV, Be More Funny"`; `"All About Love: New
  Visions"` (28 chars) stays whole. Display only — the cache and `books
  get` keep the full title.
- `--limit n` shows the alphabetically first `n` (validated as a positive
  integer) plus a "Showing n of N" note; default is unlimited (no "most
  recent N" concept to cap by). No `--since`/`--until`/`--all`/`--reverse`
  — meaningless for a title-sorted list, not copied from `blogs list` just
  for symmetry. Explicit `book_id...` args narrow the set (missing ones
  noted on stderr as `-> not cached`, not fatal).
- Implementation: one `cat "${files[@]}" | jq -s '...'` pipeline, same shape
  and performance reason as `blogs list`.

### `books get`

- Plain `gr::book_json <id>` (no `--force`): the book cache has a finite
  TTL, so a stale entry is refetched transparently; `--update` forces.
- `--json` `cat`s the pretty-printed cache file (not `gr::book_json`'s
  compacted output), same as `blogs get --json`.
- Default rendering: one jq call builds `{meta, series}`, formatted in bash
  (same shape as `blogs get`).
- `meta` lines, each present-only (absent parts contribute nothing, no
  stray separators — `map(select(. != null and . != ""))`), in order:
  1. title (`title // name`);
  2. byline: `by <contributors> · <published>[ · work first published
     <work.published>, only if it differs] · <numberOfPages> pages ·
     <ratingValue> (<ratingCount> ratings)` — rating a bare number, no `★`,
     no thousands separators (user decision);
  3. `Genres: ...`; 4. `ISBN: ...` (the `isbn` array);
  5. `URL: <url>` — deliberately last (user decision), directly above the
     series table.
- **`series` is its own table** (user decision), printed under `Series:`,
  indented two spaces, only if the book has series: `series_id`
  (right-aligned), `title` (`name` + ` #<position>` when present), `url`
  built fresh as `"https://goodreads.com/series/" + .series_id` — the cached
  `series[].url` is inconsistently shaped (sometimes with slug, sometimes
  bare id) and uses `www.`.
- `description` last, after a blank line, as `Description: <text>` (same
  label style as `URL:`/`Genres:`/`ISBN:`).

### `books remove`

Same shape as `blogs remove`: `book_id...` or `--all` (mutually exclusive,
one required), per-id `-> removed` / `-> not cached`, a summary, exit 1 if
any requested id wasn't cached.

## Blog post cache (implemented — CLI surface: `blogs`, see below)

Source: `src/lib/goodreads_blogs.sh`.

**Purpose**: groundwork for reading-challenge support. A challenge's badges
link to `goodreads.com/blog` posts (e.g. "CommunityPicks" → a themed
book-list post), but that mapping is only available behind step-up auth
(certain endpoints require the Amazon login to be less than an hour old,
which a long-lived `auth import` session can't satisfy; research notes in
`~/.goodreads/research/reading-challenges/notes.md`, machine-local, not
committed). Blog posts themselves are public (no login; fetched with the
generic cookie jar). Hence a human-in-the-loop workflow: scrape and store
posts, flag the ones shaped like big book listings (`challenge_potential`),
and let the user confirm which belong to a challenge (`challenge`, via
`blogs challenge`, and the `challenges` commands linking posts).

**Cache TTL is infinite** (user decision): a published post doesn't change,
so "cached" and "fresh" are the same question. `gr::blog_json <id>
[--force]` fetches only if the file is missing or `--force` is given;
`gr::blog_fresh` is the (trivial) counterpart of `gr::book_fresh`.
`gr::refresh_blog` always fetches when called — same split as
`gr::book_json`/`gr::refresh_book`. A `removed_remotely` stub is returned
like any other post.

**Blog post URLs** (`gr::blog_url <id>` →
`https://www.goodreads.com/blog/show/<id>`): the bare-id URL gets a 301 to
the `<id>-slug` form (followed by `gr::http_get`'s `-L`); a gone id gets a
real 404.

**Remotely deleted posts** (goodreads.com does delete old posts): cached
content must survive and not look like a plain "never fetched" miss (user
decision). On a failed `gr::http_get`, `gr::refresh_blog` asks
`gr::http_status` (`src/lib/http.sh`; status code only, shares offline/
cookie-jar/throttle handling but not the challenge retry loop) whether it
was a `404`:
- `404` → `gr::mark_blog_removed`: adds `removed_remotely: true` +
  `removed_remotely_detected_at` (ISO 8601 UTC) to the existing file,
  touching nothing else; a no-op if already marked (the timestamp is set
  once — no value in re-stamping "still gone"). Without a cached file it
  writes a stub `{blog_id, url, removed_remotely,
  removed_remotely_detected_at}`, so the file-exists check naturally stops
  re-attempting a dead id. Returns success.
- anything else → `error: could not fetch blog post <id> ... (status N)`,
  return 1, nothing written — never corrupt a good cache on failure.

**Sanity check**: the leading digits of the page's `<link rel="canonical">`
must equal the requested id (blog posts are server-rendered Rails views, no
`__NEXT_DATA__`). As for books, `GR_HTTP_EXPECT_CANONICAL` is passed to
`gr::http_get`, a missing canonical link saves the page via
`gr::save_bad_response`, and every `error:` is preceded by
`gr::term_clear_line`.

**Fields** (rebuilt from scratch on every refresh with `jq -S -n`, nulls
dropped):
- `blog_id`, `url` (the canonical link);
- `title` (`<h1 class="gr-h1 gr-h1--serif">`, whitespace-squeezed);
- `author`, `published` (`YYYY-MM-DD`) — parsed from the byline "Posted by
  `<author>` on `<Month> <Day>, <Year>`" (via `date -d`; dropped if
  unparseable);
- `like_count` — leading number of the `/rating/voters/<id>` link text;
- `book_sections`, `challenge_potential`, `challenge` (below).

**The article body's HTML is not persisted** (user decision: structured
fields only). It is extracted to a temp file (`--output-format=html` of
`div.newsShowColumn`) because: its presence is the "is this a real post"
check (alongside the title), and `challenge_potential` greps it for CSS
class names, which only exist in real HTML. A file, not a variable: bodies
can exceed 500KB (see the `--arg` lesson below).

**`book_sections`**: the post's books (`book_id` + `title`), grouped the way
the post groups them. Listing posts often split books into sub-lists under
plain `<h1 style="text-align:center">` headings interleaved with the grids
(e.g. "204 Retellings" by source mythology; "I Love the 90s" by year) —
even small posts may have one. Posts without headings get a single
`{section: null, books: [...]}` group, so the general case is just a flat
list. Flatten `book_sections[].books[]` for all ids. History: see
DESIGN-HISTORY.md › Blog cache: `book_ids` → `book_sections`.

Extraction (one xidel xquery3 call + one jq program):
- Every `<a href=".../book/show/<id>...">` inside the body, with the nearest
  *document-order* preceding section heading
  (`($a/preceding::h1[...])[last()]` — heading and grid are
  siblings/cousins at varying depth, so a tree-structural query wouldn't
  find it).
- **Title = the `alt` of the cover image whose class contains
  `AcrossImage`** (`fourAcrossImage`/`threeAcrossImage`), not just the
  first `<img>` in the link: a sibling `amazonBadge` wrapper can hold its
  own promo `<img>` (e.g. "Kindle Unlimited") *before* the cover, and
  `string()` on a multi-node result takes the first. History: see
  DESIGN-HISTORY.md › Blog cache: "Kindle Unlimited" titles.
- Titles are `clean_or_null`ed, then `strip_series_ref` removes a trailing
  `"(Series Name, #N)"` — only when the parenthetical ends in a digit, so a
  real parenthetical title survives (and never strips down to empty).
- **Books without a cover title are dropped.** Inline prose mentions (plain
  links, no image) have no reliable title in the markup; the same book
  usually also appears in its section's grid, with a title.
- Dedup by `book_id`: the first occurrence with a title wins, else the
  first occurrence (then dropped by the rule above if untitled). The
  titled occurrence is, in practice, also the one in the book's real
  section.
- Grouping is a `reduce` over books sorted by their original document
  position (`idx`, assigned before dedup), appending each to the existing
  group for its section or opening a new one — **not** `group_by`, which
  would re-sort groups alphabetically and destroy the post's reading order.
- **`--extract-kind=xquery3`** is required: xidel's default `-e` language is
  plain XPath, which has no `let` (errors without the flag).
- **`GR_XIDEL_JSONIQ_FLAG`**: xidel ≥ 0.9.9 disables JSONiq `{...}` object
  literals under xquery3 unless `--json-mode=jsoniq` is given — without it
  the query silently returns an `"_error"` blob that then breaks the
  downstream `jq --argjson`. xidel 0.9.8 has no `--json-mode` (prints
  "Unknown option" but exits 0) and doesn't need it. Support is detected
  once at load time by grepping `xidel --help`, not by a version check.

**`challenge_potential`**: a number `0`..`1`, currently only ever exactly
`0` or `1` (a fractional confidence score is planned once the heuristic is
refined — user decision). `1` only when both hold:
1. **at least `GR_CHALLENGE_LISTING_MIN_BOOKS` (40) books** in
   `book_sections` — excludes small roundups/promo posts that use the grid
   widget for a few picks. 40 sits in a real gap in the data (flagged posts
   jumped from 12 and 33 books straight to 48+). A floor only excludes
   too-small posts; a high count alone never proves anything.
2. **at least one plain, unmodified cover-grid image** in the body:
   `class="fourAcrossImage"` or `class="threeAcrossImage"` exactly — not the
   `--audiobook` BEM modifier (`class="fourAcrossImage--audiobook"`). This
   also covers "uses the grid widget at all". It excludes all-audiobook
   listings (e.g. post 3157, "72 Reader-Approved Audiobooks...") while
   keeping real lists that include a few audiobooks (post 3129 has 8
   audiobook covers among 128 plain ones).

Rules from the history: **don't harden against one counterexample with a
stronger rule than it needs, and check every new exclusion rule against
the whole set of confirmed positives** (known challenge posts such as
3127, 3129), not just the negative that motivated it. Mixing grid widgets
with `oneAcrossImage`/`bookInfoFullRow` entries is **not** an exclusion
signal (3127, real challenge material, does it). History: see
DESIGN-HISTORY.md › Blog cache: `challenge_potential` heuristic.

**Still not proof** of belonging to any specific challenge — unrelated big
listicles (e.g. 3043, "204 Retellings") use the same widget. It's a
candidate signal for the human-in-the-loop workflow; confirmation is
`challenge`, below.

Since the body isn't persisted, changing the heuristic requires a real
re-fetch of every cached post (`blogs fetch --all --update`) to recompute
it; a pure rename/type change can be done as a data migration instead.

**`challenge`**: the manual override, **tri-state**: `true`, `false`, or the
key **absent** (never stored as `null` — "undecided" is a distinct third
state, and jq reads a missing key as `null` anyway; user decision). Set via
`blogs challenge <blog_id...> (--yes | --no | --auto)`; `--auto` runs
`del(.challenge)`. Never computed by scraping: `gr::refresh_blog` reads the
old value (or absence) from the existing file *before* rebuilding and
carries it forward — without that, the full rebuild of every refresh
(e.g. `blogs fetch --all --update`) would wipe all manual decisions.
`challenge_potential` is always recomputed.

**Effective status** is defined in one place, `GR_CHALLENGE_JQ_DEFS` (a bash
string of two jq `def`s):
- `gr_challenge_status`: `.challenge` if present (`!= null`), else
  `challenge_potential >= GR_CHALLENGE_POTENTIAL_THRESHOLD` (0.5; named
  rather than hardcoded, for when values become fractional).
- `gr_challenge_marker`: `°` explicitly not a challenge, `*` explicitly one,
  `?` no override but the machine guess crosses the threshold, space
  otherwise. Built on `gr_challenge_status`: by its `elif` branch
  `.challenge` is already ruled out as `true`/`false`, so the status there
  is the machine guess alone.
Commands needing either (`blogs list`'s marker/potential columns, `blogs
get`'s potential line) prepend it to their program
(`"$GR_CHALLENGE_JQ_DEFS"'...'`, two adjacent bash string tokens → one jq
argument) instead of re-implementing the rule inline, so the copies can't
drift apart.

**Why two fields, not one**: merging `challenge` into `challenge_potential`
(pinning it to 0/1 once decided) was rejected — refresh would still need
the same carry-forward read, a single field would hide which part is
machine- vs human-owned, and "never decided" would be indistinguishable
from "assessed as 0". Separate fields let `gr::refresh_blog` overwrite
`challenge_potential` unconditionally.

**Never pass large content to `jq` via `--arg`**: it becomes a literal argv
element, and a big listicle's body (> 500KB) exceeds the OS argument-list
limit (`jq: Argument list too long`). Use a temp file + `--rawfile`. All
fields currently passed via `--arg`/`--argjson` are small. History: see
DESIGN-HISTORY.md › Blog cache: `body_html` and `--arg`.

**A `trap ... RETURN` set inside a function is global, not scoped to that
call** — it stays installed and fires again on the next function return
anywhere up the stack, referencing now-out-of-scope locals (harmless under
bashly's `set -e`-only mode since `rm -f ""` is a no-op, but an `unbound
variable` crash under `set -u`, and fragile either way). So every such trap
clears itself as its last action: `trap 'rm -f "$x"; trap - RETURN' RETURN`
(`gr::refresh_blog`, `gr::mark_blog_removed`, `blogs challenge`, the
challenge helpers). `gr::discover_blog_ids` instead creates and removes a
temp file per page, since a function-level trap would only clean up the
last page's file. **Still latent**: `goodreads_auth.sh`'s
`gr::identify_account_from_cookiejar` and `gr::cookies_state` use
non-self-clearing `trap ... RETURN` — fix if touched again.

## `blogs` commands (implemented)

`blogs fetch [blog_id...] [--all|-A] [--update|-U] [--batch|-B]`,
`blogs list [blog_id...] [--all | --since <date> --until <date> --limit <n>] [--reverse]`
(alias `ls`, the group's `default: force` command),
`blogs get <blog_id> [--json|-J] [--update|-U]`,
`blogs challenge <blog_id...> (--yes | --no | --auto)`,
`blogs remove [blog_id...] [--all]` (alias `rm`).
Source: `src/bashly.yml` (command tree), one `src/blogs_*_command.sh` per
leaf command (same pattern as `auth`). `fetch` is the only command with
real logic behind it in `src/lib/goodreads_blogs.sh`
(`gr::discover_blog_ids`); the others are thin wrappers over
`gr::blog_json`/`gr::blog_dir`/`gr::blog_file`.

Conventions shared by every `blogs` command (and `books`/`challenges`):
- Mutual exclusivity between flags/args is checked by hand in bash —
  bashly doesn't enforce it (both can be set as far as arg parsing is
  concerned).
- A `repeatable: true` arg/flag reaches the command as one space-joined
  string in `args[...]`, not an array; it's deliberately word-split with an
  unquoted `for x in $y` (fine for ids, which never contain spaces — see
  `challenges create --badge` for the `%q`/`eval` variant needed when
  values can).
- Blog-id tab completion (`list`, `get`, `books fetch --blog`,
  `challenges edit --add-blog`) is an `ls` of
  `${GOODREADS_DATA:-$HOME/.goodreads}/blogs`. bashly's `args:` entries
  can't carry `completions:` (only commands and flags can), so for
  positional ids it's attached to the command itself. It ignores a
  `--data-path` given on the same command line (honoring it would mean
  parsing `COMP_WORDS` in the completion snippet).

**Progress during `fetch`** (all three branches below) is the same
self-updating status line as `books fetch`, suppressed by `--batch`/`-B` —
see "`books` commands" for `gr::run_fetch`/`gr::status_line`/
`gr::status_line_clear`/`gr::fetch_quiet` (nothing books-specific). curl is
resolved (`gr::init_curl_cmd`) up front, before `gr::run_fetch`'s per-item
subshells, since memoization wouldn't survive them. Individual fetch
failures are reported and tallied, not fatal; `fetch` exits 1 only when
`gr::run_fetch` aborted the run (consecutive-failure limit), and an abort
during `--all`'s new-post phase also skips its cached-post re-check (it
would hit the same problem).

### `fetch`

One command whose behavior branches on what's passed (user decision; it
replaced separate `refresh`/`discover` commands and later an `update`
command — History: see DESIGN-HISTORY.md › blogs fetch). In priority order:

1. **One or more `blog_id`s**: each goes through `fetch_one` (called via
   `gr::run_fetch`) with the `""` force policy, or `"force"` with
   `--update`. An uncached post gets a plain `gr::blog_json <id>` (`->
   fetched` — this doubles as "add a post by id", no separate `add`
   command). An already-cached post is skipped (`-> already cached`, no
   network) unless `--update`/`-U`, which force-refetches it
   (`gr::blog_json <id> --force`, `-> refreshed`, or `-> confirmed
   removed remotely` on a 404). Skip-if-cached is the default (user
   decision). Mutually exclusive with `--all` (error).
2. **`--all`/`-A`**: a **full** discovery pass (`gr::discover_blog_ids
   --full`) plus a check of every post that was cached *before this run
   started*, via `fetch_one`'s `"ttl"` policy, or `"force"` with
   `--update` (`refresh_force`). The blog cache TTL is infinite (a
   published post never changes — see "Blog post cache"):
   `gr::blog_fresh` is just the cache file's existence check, so under
   `"ttl"` every cached post reports `-> already cached (fresh)` without
   touching the network (the `"ttl"` refetch branch in `fetch_one` is
   currently unreachable). So plain `--all` can't re-verify that existing
   posts still exist — accepted for consistency with `books fetch --all`
   honoring its TTL (user decision: "may make the flag absurd, but
   consistent"). `--all --update` is the "sync everything, confirm
   nothing's gone" mode. Ids discovered in this same run are not
   re-checked (they're fresh from moments earlier). `--all` is also the
   only mode that reports cached ids **missing from the current listing**,
   because only a `--full` scan is guaranteed complete. That report says a
   missing post isn't necessarily deleted (it may just have aged off the
   listing's page range) and suggests `fetch <id> --update` — plain
   `fetch <id>` would just skip an already-cached id.
3. **Neither** (plain `blogs fetch`): discovery only — scans `/news`
   (`gr::discover_blog_ids`, short-circuiting at the discovery marker,
   below) and fetches whatever is new with the `""` policy. No
   missing-posts report: a short-circuited scan can't tell an older,
   unscanned id from one that disappeared. Use `--all` for that.

Both discovery branches diff the scan against the on-disk cache
themselves: `cached_ids` (built once from `blogs/*.json`) and `comm -23`
give `new_ids` (and, for `--all`, `missing_ids`). `gr::discover_blog_ids`
never filters against the cache — it only answers "what does the listing
currently show", as efficiently as possible. The caller-side diff is
required, not cosmetic: a marker-less (or marker-lost) scan can return ids
that are already cached, which would otherwise be mislabeled `-> fetched`.

`outcome_text`: a successful `gr::blog_json` doesn't distinguish "fetched
real content" from "confirmed gone, marker written" (both are success —
see `gr::refresh_blog`), so `fetch_one` checks the file's
`removed_remotely` afterward and reports `-> confirmed removed remotely`
instead of `-> refreshed`/`-> fetched`. Shared by all three call sites
(explicit ids, newly discovered ids, `--all`'s cached sweep). (In
`fetch_one`, the local `was_cached` is `0` when the file *exists* — the
name is inverted; the output labels are right: cached → `refreshed`,
uncached → `fetched`.)

### Discovery (`gr::discover_blog_ids`)

Paginates `/news?content_type=articles[&page=N]` (`gr::news_url`). The
`content_type=articles` filter is deliberate: without it the listing also
shows `/interviews/show/<id>.<name>` pages (separate id space and layout,
no book list, not scraped here) and yields zero additional `/blog/show/`
ids, so filtering costs nothing. `GR_NEWS_DISCOVER_MAX_PAGES` (50) is a
safety cap against a non-terminating listing; the real listing is ~17-18
pages. One temp file per page, removed right away (a function-level
`RETURN` trap would only clean up the last page's file).

**Id extraction is scoped to real listing cards**: only lines matching
`/blog/show/<id>` *and* `editorialCard__image--fullHeight` (the listing
card's cover-image class, always on the same line as its href). A
page-wide `grep` would also pick up an unrelated promo banner link in the
page header, which comes before the listing in document order and would be
mistaken for the newest post (History: see DESIGN-HISTORY.md › Discovery
marker bugs). Ids are then deduplicated order-preservingly (`awk
'!seen[$0]++'`, not `sort -u`), since position relative to the marker
matters.

**The discovery marker** (user decision): `gr::blogs_discovery_marker_file`
= `$(gr::data_dir)/.blogs_discovery_marker`, a plain-text file holding one
blog id (same small-state-file convention as `gr::throttle`'s
`.last_request_at`) — the id at the top of page 1 as of the last
**successfully completed** discovery. The listing is recency-ordered, so a
plain `blogs fetch` stops paginating when it meets that id; only ids
*before* it on that page (in document order) count as new, plus all ids of
earlier pages. `--full` ignores the marker and walks the whole listing
(same as a marker-less first run). Pagination ends on either:
- the marker appearing on a page (the common case), or
- a page contributing no id not already seen *this run* (the fallback:
  `--full`, first run, or the marker's own post having left the listing).

The marker is updated by **every** successful discovery, `--full`
included ("this marker is only ever updated by running a blog discovery",
user decision). The write is the last thing the function does, success
path only — a page-fetch failure returns 1 before it, so a failed
discovery can be repeated against the old marker (explicit requirement).
The marker is authoritative about "what discovery last saw", independent
of what was added to/removed from the cache by other means. (Replaces an
earlier design that seeded the scan with the whole cached-id set —
History: see DESIGN-HISTORY.md › Discovery marker.)

The function must end in `result="$(… | grep -v '^$')"; echo "$result"`,
not a bare trailing `grep -v`: with nothing new, `grep` exits 1 ("no lines
selected"), which would become the function's status and make every
caller's `gr::discover_blog_ids … || exit 1` fail spuriously.

### Gotchas for `*_command.sh` files and the generated executable

**Never span a string literal across two physical lines in a
`*_command.sh` file.** bashly prepends a fixed indent to every physical
line of a command file when inlining it into the generated script's
function body. Harmless for code, but a continuation line of a multi-line
string gets that indent as part of its runtime *value* — invisible in the
source. Build newline-joined strings on one line instead, e.g.
`"${cached_ids}${cached_ids:+$'\n'}${id}"` (as `blogs_fetch_command.sh`
does). `src/lib/*.sh` files are included verbatim, so this only affects
command files. When a command file's runtime behavior contradicts its
source, diff it against the corresponding function body in the generated
`goodreads` script. (History: see DESIGN-HISTORY.md › bashly re-indent
bug.)

**Don't regenerate `bin/goodreads` (`make bin/goodreads`) repeatedly while
a long-running invocation is still executing.** A single overwrite is fine
(the running process keeps reading the old content through its open file
descriptor), but several successive overwrites during one run have
desynced the process's read position and executed garbage (a stray
`logs_usage: command not found`). Let background runs finish before
regenerating. (History: see DESIGN-HISTORY.md › Regenerating while
running.)

### `list`

One line per post, sorted by `published`, most recent first (user
decision). Default: the 15 most recent; `--limit <n>` (positive integer)
changes the count; `--all` shows everything and is mutually exclusive with
`--since`/`--until`/`--limit` ("everything" plus a filtered/capped view is
meaningless). Explicit `blog_id...` args narrow the candidates to exactly
those (uncached ones: `<id> -> not cached` on stderr, not fatal) and bypass
the cap like `--all`; combining ids with `--since`/`--until` is allowed
(it narrows further). `--since`/`--until` are parsed liberally via `date -d`
(like `gr::refresh_blog`'s byline dates), so "yesterday", "2 weeks ago",
etc. work.

`--limit` semantics depend on the active date bound (user decision — "the
15 most recent" isn't what's wanted once a bound narrows the range):
- Neither bound, or `--until` only: keep the `n` *newest* matches.
- `--since` only: keep the `n` *oldest* matches (closest to `--since`).
- Both: no cap — the range already says which posts are wanted; a
  `--limit` alongside both is rejected (`error: --limit has no effect once
  both --since and --until are given…`), never silently ignored.
- `--until` before `--since` is rejected (`error: --until (...) is before
  --since (...)`) rather than producing an empty range.

`--reverse` flips the final, already-capped selection (reversing before
capping would change *which* posts are shown). The trailing truncation
note ("Showing the N oldest/most recent of M matching post(s) — pass --all
to see the rest") says "oldest" when `--since` alone drove the cap, and is
printed only when a cap actually truncated something — tracked by one
`bypass_limit` variable covering `--all`, explicit ids and both-bounds
uniformly (deriving it from `$all`/`$blog_ids` alone would miss the
both-bounds case).

**Implementation**: `cat "${files[@]}" | jq -s '...'` — all candidate
files slurped into one array; filter, sort, cap and `--reverse` are one jq
pipeline (`jq -s` accepts concatenated pretty-printed documents as-is).
Prepends `GR_CHALLENGE_JQ_DEFS`. Emits `{total, lines}`: `total` is the
post-filter, pre-cap count (for the truncation note); `lines` is TSV
already in final display form (effective challenge marker and a
`[removed remotely]` title suffix folded in by jq). Output:
`{ printf 'id\tpublished\ttitle\tbooks\tchallenge\turl\n'; jq -r '.lines[]' <<< "$result"; } | column -t -s $'\t' -R 1,4`.
`column -t` sizes each column to its widest value (no fixed-width
assumption to outgrow); the header goes through the same pass so it
aligns too. `-R 1,4` right-aligns `id` and `books` (user decision);
`challenge` stays left-aligned since it's a compound value-plus-marker
label, not a pure number. (History: see DESIGN-HISTORY.md › blogs list.)

Columns: `id, published, title, books, challenge, url` (user decision on
order; `url` rightmost). `title` therefore needs real padding; util-linux
`column` (2.37.2 here) measures UTF-8 (curly quotes, em dashes) correctly,
not by bytes — a property of this build, re-check on a much older
util-linux. `url` is built as `"https://www.goodreads.com/blog/show/" +
.blog_id` (short id-only form, user decision; goodreads resolves it like
the slug form — see `gr::blog_url`), not the cached slug `.url`. `www.` is
kept for blog urls: bare `goodreads.com/blog/show/<id>` 301-redirects to
add `www.` (on top of the id→slug redirect), whereas book urls behave
identically with or without `www.` (hence `blogs get`'s book urls drop it).
An observed goodreads.com routing asymmetry, not something this project
controls.

Sort/filter key: `.published`, falling back to `"0000-00-00"` (sorts
before every real date) when absent — only a `removed_remotely` stub lacks
it; such posts display `?` and sort last. When `--since`/`--until` is
active, posts without a date are excluded (`in_range` requires
`.published != null`) — an unknown date can't satisfy an explicit range.
Note: `sort_by(x) | reverse` also reverses the order of same-key ties
(unlike a stable descending sort); tie order among same-day posts is
unspecified anyway, so this isn't worked around.

`challenge` column: `(.challenge_potential // 0 | fmt2dp) + " " +
gr_challenge_marker` — raw potential rounded to 2 decimals, then the
marker `°`/`*`/`?`/space (explicitly not / explicitly yes /
machine-guessed / neither; see "Blog post cache"), value first (user
decision). `fmt2dp` is a `def` local to this command (presentation only,
not in `GR_CHALLENGE_JQ_DEFS`). jq has no printf-style formatting and
`tostring` drops trailing zeros (`0.1` → `"0.1"`), so `fmt2dp` scales to
whole "cents", rounds, splits whole/fractional and zero-pads the fraction.
Book count is `[.book_sections[]?.books[]?] | length` — the `?`s make a
stub (no `book_sections`) count as `0` instead of erroring. Missing title
shows `(no title)`.

No cached posts at all: prints a hint to run `goodreads blogs fetch
<blog_id>` (exit 0); nothing matching the filters: "No cached blog posts
match those filters."

### `get`

Fetches on demand via `gr::blog_json` (stdout discarded; only its side
effect + exit status matter). `--update`/`-U` uses `gr::blog_json "$id"
--force` instead (e.g. to re-check for a 404) — the only way besides
`fetch <id> --update`. Default output is a pretty book listing (user
decision — that's what someone running `get` wants to read). `--json`
`cat`s the cache file (pretty-printed, sorted keys), not `gr::blog_json`'s
compact one-line stdout (which is meant for programmatic callers).

The renderer is one jq call (with `GR_CHALLENGE_JQ_DEFS`) emitting
`{removed, meta, sections, rows}`, formatted in bash:
- `meta`: title, url, `author · published · N likes` (absent pieces
  dropped via `map(select(. != null))`, so no stray `· ·`), and
  `<marker> Challenge potential: <raw value>` — always shown (user
  decision), at full precision (no column-width constraint here, unlike
  `list`), with `(manually marked as a challenge listing)` / `(manually
  marked as NOT a challenge listing)` appended when `.challenge` is set.
- `sections`: `{header, count}` per `book_sections` group (`Section
  (count):`, or `Books (N):` for an unsectioned post).
- `rows`: every book of every section flattened into one
  `book_id\ttitle\turl` TSV list, in original order.
- A `removed_remotely` stub gets its own short branch, `{removed: true,
  meta: [...]}` (id, detection date, url) — a stub has none of the normal
  fields (see `gr::mark_blog_removed`).
- No sections: "No books found in this post."

Book rows are an id-first table (user decision), `column -t -s $'\t' -R 1`
(id right-aligned like `list`'s), `url` rightmost (user decision), built
as `"https://goodreads.com/book/show/" + .book_id` without `www.` (see
`list` for the tested blog/book asymmetry). Alignment is done **once,
globally, across all sections**: `column -t` runs over the whole flattened
`rows` list into an array, then a `while` loop over `sections` slices
`count` consecutive lines per section (running `idx`). Per-section
`column -t` would size columns differently per section. Each section is
followed by a blank line (user decision), including the last (harmless).
(History: see DESIGN-HISTORY.md › blogs get.)

### `challenge`

Sets or clears a post's `.challenge` (tri-state manual override, separate
from `challenge_potential` — see "Blog post cache") on one or more cached
posts. `blog_id` is repeatable (same shape as `fetch`/`remove`); none given
is an error. Exactly one of `--yes`/`--no`/`--auto` is required, checked by
hand; no flag is rejected too — there's no sensible default for recording
an explicit human decision. Uncached ids are reported (`<id> -> not
cached`) and counted as failures without aborting the rest (exit 1 if any
failed) — not fetched on the command's own initiative, since marking an
unseen post makes no sense (History: see DESIGN-HISTORY.md › blogs
challenge / remove (renames)). `mark_one` + loop, same shape as `blogs
remove`'s `remove_one`.

Implementation is a merge onto the existing cache file (`jq -S '. +
{challenge: true}'` / `'. + {challenge: false}'` / `'del(.challenge)'`,
temp file + `mv`), not a `gr::refresh_blog`-style rebuild, so every other
field (including `challenge_potential`) is untouched. `--auto` uses `del`,
not `= null`: the tri-state is true/false/**absent**.

### `remove`

Same `blog_id...`/`--all` shape as `fetch`: explicit ids or `--all` (every
cached post, from `gr::blog_dir`), mutually exclusive, and an error if
neither (`blog_id` is optional because it's `repeatable`). `--all` folds its
id list into the same `blog_ids` path as explicit ids, so `remove_one` is
the only place that removes. Per-id outcome plus a summary line. An id that
isn't cached is a usage error: `remove` exits 1 if anything requested
wasn't found (unlike `fetch`, where network failures are tolerated). No
confirmation prompt, even for `--all` (same non-interactive precedent as
`auth logout`; revisit only if asked).

## Reading challenges (implemented — CLI surface: `challenges`)

**Challenges are manually curated, not scraped.** Challenge detail (which
books count toward which badge) is behind a step-up-auth wall no
long-lived session can satisfy (see "Blog post cache"), so there's no
discovery scan. The user records a challenge's title/time window, then
links the `blogs`-cached posts and book-count badges that apply
(`challenges create`/`edit`).

**Schema** (`challenges/<id>.json`, pretty-printed, sorted keys, like
`books`/`blogs`): `challenge_id`, `title`, `start`, `end` (plain
`YYYY-MM-DD`; parsed liberally via `date -d` at the CLI layer), `blogs`
(array of `{blog_id, name}`), `count_badges` (array of `{count, name}`).
Both lists may legitimately stay `[]` forever (user decision). They're
lists of objects, not bare ids/integers, so each entry can carry the
`name` of the badge it earns. `name` is optional: `null` when not given,
never `""` (absence as a real state, like blogs' `.challenge`).

### Challenge ids

**`challenge_id` is a purely local string** (bound via `--arg`, so always
a JSON string even when numeric-looking) — there's no goodreads id to key
off. **Derived from `start`/`end`** (user decision) by
`gr::generate_challenge_id` (`src/lib/goodreads_challenges.sh`, called by
`gr::create_challenge`):
- **Seasonal** (per `gr::challenge_season` — the same rule
  `gr::default_challenge_title` uses, so id and default title always agree
  on "seasonal"): `<year>Q<quarter>`, e.g. `2026Q3` for a challenge whose
  `end` is within a month of `2026-09-30` (`<quarter>` = 1-4, the
  `GR_QUARTER_END_MONTHDAY` index + 1; `<year>` is the matched
  quarter-end's year). On collision, `-<n>` from **2** (`2026Q3-2`, …) —
  the bare id is "the first one".
- **Non-seasonal**: `<start year>-<n>`, from **1** (no bare `<year>` id).

Availability is checked against the real `challenges/*.json` files (no
counter state), so **an id is reused once its challenge is removed** —
accepted: these ids are predictable, content-derived labels (slug-like),
and a re-created challenge naturally lands on the same one. (History: see
DESIGN-HISTORY.md › Challenge ids.)

**Ids are fixed at creation; `edit` never renames them**, even if a new
`start`/`end` changes the quarter/year or seasonality. This is the risk
`[[feedback-stable-ids-over-mutable-slugs]]` warns about, accepted per
user decision: after a significant edit an id may no longer reflect the
window. Cosmetic as long as nothing relies on an id's shape matching the
data.

**`create --id <id>`** bypasses generation (`gr::create_challenge`'s 4th
parameter), checked first in `challenges_create_command.sh`: an existing
id fails with `error: challenge <id> already exists`; an id containing `/`
fails (`error: --id must not contain '/': <id>`) because it becomes a
filename component verbatim (`gr::challenge_file`) — the only id-taking
input in the project that becomes a new path from raw user input. No other
format constraint (`--id book-club-pick` is fine).

### Storage helpers

**`gr::add_challenge_blog`/`gr::add_challenge_count_badge` are upserts**
keyed by `blog_id`/`count`: an existing entry only gets its `name` replaced
in place (preserving add/display order); an empty name is stored as
`null`. `count_badges` is re-sorted by `count` after every write
(ascending display regardless of add order); `blogs` keeps add order, which
is meaningful there (roughly the order a human worked through the
challenge). `gr::remove_challenge_blog`/`gr::remove_challenge_count_badge`
return 1 without writing when the id/count isn't present (used for
`edit`'s per-item report). `gr::clear_challenge_blogs`/
`gr::clear_challenge_count_badges` (via `gr::clear_challenge_array`) set
the list to `[]`.

**Every write is a merge onto the existing file** (read, jq-transform the
relevant part, temp file + `mv`), never a full rebuild — same principle as
`blogs challenge`. Only `gr::create_challenge` writes from scratch (`jq -n
-S`, empty lists). `gr::update_challenge` treats `""` as "leave unchanged"
for each of `title`/`start`/`end` — safe since none is ever legitimately
empty. `gr::require_challenge_file` prints the path or fails with `error:
no challenge <id>`.

**jq can't reference `$end`**: `end` is a jq keyword; `.end` and an object
key `end:` compile fine, but `--arg end …` + `$end` fails (`syntax error,
unexpected end, expecting IDENT`). The jq-side binding is named `end_date`
wherever a challenge's end is passed into jq (`gr::create_challenge`,
`gr::update_challenge`, `gr::challenges_overlapping`); the bash variable
and the JSON field stay `end`.

**`GR_CHALLENGE_STATUS_JQ_DEF`** (`goodreads_challenges.sh`): shared jq
`def challenge_status($today)` → `planned`/`ongoing`/`finished`, prepended
to `challenges list`'s and `get`'s jq programs so the computation can't
drift between them. Unrelated to `GR_CHALLENGE_JQ_DEFS`
(`goodreads_blogs.sh`, a *blog post's* challenge-listing flag) despite the
name. Plain lexical `YYYY-MM-DD` comparison against `$today` (passed once
via `--arg`). Never stored — it changes as time passes.

## `challenges` commands (implemented)

`challenges create` (alias `new`) `[--id <id>] [--title <title>] [--start <date>] [--end <date>] [--badges <specs> | --badge <spec>... | --no-badges] [--blogs <specs> | --blog <spec>... | --no-blogs] [--no-goals]`,
`challenges list` (alias `ls`, the group's `default: force` command),
`challenges get [challenge_id] [--json|-J]`,
`challenges edit <challenge_id> [--title <title>] [--start <date>] [--end <date>] [--blogs <specs> | --add-blog <spec>... --remove-blog <blog_id>...] [--badges <specs> | --add-badge <spec>... --remove-badge <count>...]`,
`challenges remove [challenge_id...] [--all]` (alias `rm`).
Source: `src/bashly.yml`, one `src/challenges_*_command.sh` per leaf
command. Managing a challenge's blogs/badges is part of `edit` (user
decision: it's still "changing a challenge", and one call can make several
changes) — there are no nested `challenges blogs`/`badges` groups
(History: see DESIGN-HISTORY.md › challenges command surface).
Challenge-id completion (`get`, `edit`, `books fetch --challenge`) is an
`ls` of the data dir's `challenges/`, attached to the command for
positional args (same `args:`-can't-complete and `--data-path` caveats as
blog ids, see "`blogs` commands").

### `create`

Parses `--start`/`--end` via `date -d`, rejects end-before-start, validates
everything (badge counts, explicit blog posts) *before* creating anything
so a bad value can't leave a half-set-up challenge, then calls
`gr::create_challenge` and the per-item `gr::add_challenge_count_badge`/
`gr::add_challenge_blog` upserts. Prints `Created challenge <id>: <title>
(<start> to <end>)` (the only way to learn an auto-generated id), then
`Book-count badges: …` and `Linked blog posts: …` lines when non-empty.

**`--title`/`--start`/`--end` are optional**, defaulting towards "keep
making quarterly challenges" (`gr::default_challenge_*`):

- **`--start`** (`gr::default_challenge_start`): the day after the latest
  challenge's (`gr::latest_challenge`, largest `.end`) end, if a
  default-length successor starting there wouldn't have ended by today
  (one test covering both "latest is ongoing" and "latest recently
  ended"); otherwise the start of the current calendar quarter (no prior
  challenge, or the trail went cold). **Fails** if the latest challenge
  hasn't started yet (planned): `error: the latest challenge (challenge
  <id>, <start> to <end>) hasn't started yet -- can't auto-select --start
  from it. Pass --start explicitly.` — there's nothing sensible to chain
  off, and the quarter-start fallback could land on top of an earlier
  challenge. (E.g. two no-arg `create`s make this quarter's and next
  quarter's challenge; a third fails.)
- **`--end`** (`gr::default_challenge_end`): the first quarter-end
  (Mar-31/Jun-30/Sep-30/Dec-31) on or after `--start` that's at least
  `GR_CHALLENGE_MIN_DAYS` (42 = 6 weeks) away, else the one after — e.g.
  `--start=2024-09-15` → `2024-12-31`, not `2024-09-30`.
- **`--title`** (`gr::default_challenge_title`): `"<Season> Challenge
  <year>"` when the challenge is seasonal (`gr::challenge_season`: the
  actual end — given or defaulted — is within one calendar month of a
  quarter-end, `gr::quarter_near`, **and** the challenge is at least 6
  weeks long), else `"Unnamed Challenge"`. Seasons are
  Winter/Spring/Summer/Fall for Jan-Mar/Apr-Jun/Jul-Sep/Oct-Dec (user
  decision, not astronomical seasons). `<year>` is the matched
  quarter-end's year: an end of `2025-01-15` is near `2024-12-31` (Fall) →
  `2024`.

- **`--badges <specs>`**: comma-separated book-count badges, each
  `<count>` (unnamed) or `<count>:<title>`, default
  `2:Page-Turner,3:Speed Reader,5:Book Boss` (`default_badges` in the
  command script; `Book Boss` has a real space; 3 = Speed Reader, 5 = Book
  Boss — History: see DESIGN-HISTORY.md › challenges create). Counts
  must be positive integers (`^[1-9][0-9]*$`), validated before creating.
  **No `default:` in `bashly.yml`**: bashly applies a YAML default whenever
  the value comes out *empty*, not only when the flag is absent, so it
  would turn an explicit `--badges ""` (opt out of badges) back into the
  default. `[[ -v args[--badges] ]]` (key presence, not value) tells "not
  given" from "given empty".
- **`--badge <count>[:<title>]`**: repeatable alternative, one badge per
  occurrence; mutually exclusive with `--badges` (error). **Reassembled
  with `eval`**, unlike ids: titles contain spaces (`"7:Marathon
  Reader"`), and bashly's generated parser joins repeated values after
  escaping each with `printf '%q'`, so `eval "badge_specs=(${args[--badge]})"`
  restores the original per-occurrence strings, spaces intact.
- **`--no-badges`**: no badges (same as `--badges ""`, without knowing the
  trick). Combined with `--badges`/`--badge` it's superfluous, not
  conflicting: a warning, then the explicit badges win (resolution checks
  `--badge`/`--badges` before `$no_badges`). `--badges` + `--badge`
  together remain a hard error (two incompatible ways to state the list).
  The warning (`warn_superfluous_no_flag`, shared with blogs) names only
  flags actually typed: it checks `[[ -v args[...] ]]` for each "no" flag
  (`--no-badges`, `--no-goals`; both may be given) and for which of
  `--badges`/`--badge` was given, e.g. `warning: ignoring --no-badges and
  --no-goals, because --badges was given explicitly`.

- **`--blogs <specs>`**: same `<id>`/`<id>:<title>` comma-separated shape
  (no `default:`, same `[[ -v ]]` reason), with the repeatable `--blog
  <id>[:<title>]` alternative (mutually exclusive, same `%q`/`eval`
  round-trip). Differences from badges:
  - **Every explicitly given post is fetched via plain `gr::blog_json`**
    (cache hit if cached — no TTL — else a network fetch), to confirm it
    exists (failure aborts before creating: `error: could not fetch blog
    post <id>`) and, when no title is given, to default the entry's name
    to the post's own `.title` (`jq -r '.title // empty'`; a
    `removed_remotely` stub has none → unnamed).
  - **Default list** (neither `--blogs` nor `--blog`, no `--no-blogs`):
    computed by `gr::default_challenge_blogs`, and each auto-selected post
    also gets the post's own title as its name (via `gr::blog_json`,
    always a cache hit) (user decision — an untitled association was
    unexpected).

  `gr::default_challenge_blogs "$start" "$end" "$today"`: every *cached*
  post (it can't find unfetched ones) published from
  `GR_CHALLENGE_BLOG_WINDOW_BEFORE_START_DAYS` (7) days before `start`
  through `GR_CHALLENGE_BLOG_WINDOW_BEFORE_END_DAYS` (14) days before `end`
  **or today, whichever is earlier**, with raw `challenge_potential >=
  GR_CHALLENGE_BLOG_DEFAULT_MIN_POTENTIAL` (0.7), oldest first. It uses the
  raw likelihood score, not the (manually overridable) `gr_challenge_status`
  boolean, since this is a likeliness threshold — deliberately higher than
  `GR_CHALLENGE_POTENTIAL_THRESHOLD` (0.5, "is this a challenge listing at
  all"), a different question from "auto-link it to a new challenge". It
  needs start/end/today resolved, so it runs later in the script than the
  badge handling.

  **The today cap is deliberate**: challenges reveal badges and their
  posts gradually over their run (at creation typically only 3-5 are
  known; later posts can appear well after), so posts past today don't
  exist yet. Also, `challenge_potential` can't reliably predict Goodreads'
  editorial curation on the (auth-walled) challenge hub — structurally
  identical same-day posts can differ, with no discoverable distinguishing
  feature. So the default is a rough, correctable starting point;
  `challenges edit` (`--add-blog`/`--remove-blog`/`--blogs`, and the badge
  equivalents) keeps a challenge in sync as more is revealed.
- **`--no-blogs`**: same superfluous-not-conflicting treatment as
  `--no-badges` (`blogs_given`, set by either flag, is checked before
  `$no_blogs`).

**`--no-goals`** = `--no-badges --no-blogs`: it forces the script's local
`no_badges`/`no_blogs` to `1` up front, before the superfluous checks, so
it triggers the same warning; `warn_superfluous_no_flag` looks at the
literal flags in `args`, so `--no-goals --badge 2` warns `ignoring
--no-goals, because --badge was given explicitly` (never mentioning the
untyped `--no-badges`). Everything after that only looks at
`$no_badges`/`$no_blogs`.

**`gr::challenges_overlapping`**: with an *auto-selected* `--start` (never
an explicit one — that's the documented way to force a window), creation
is refused if the window overlaps an existing challenge (listing the
collisions, suggesting `--start`). Normally unreachable through the
defaulting rules (the planned-latest case fails earlier with a more
specific message); kept as a safety net against hand-edited files or
future changes to the defaults.

**GNU `date` quirks** (handled in `gr::last_day_of_prev_month`/
`gr::last_day_of_next_month` and `gr::days_between`):
- A chained relative string (`"$d +1 day +1 month -1 day"`) is not applied
  left to right: for `2024-03-31` it gives `2024-05-01`, not
  `2024-04-30`. `gr::last_day_of_next_month` uses three separate `date -d`
  calls, each re-parsing the resolved intermediate date (so a challenge
  ending `2024-04-30` counts as near `2024-03-31` → "Winter Challenge
  2024").
- A local-time `epoch / 86400` day count is off by one across a DST
  change (`2024-03-25` → `2024-04-01` in `Europe/Berlin` gives 6, not 7);
  `gr::days_between` uses UTC (`date -u`).

### `list`

No filtering/paging flags (unlike `books`/`blogs list`): challenges are
few and hand-curated. Sorted by `start` (chronological). Columns: `id,
title, start, end, status, blogs, badges` (`blogs`/`badges` = list
lengths), `column -t -R 1,6,7` (id and counts right-aligned). Status via
`GR_CHALLENGE_STATUS_JQ_DEF`.

### `get`

**`challenge_id` is optional** (user decision). Omitted, it defaults to
`gr::next_ending_challenge` — the challenge with the smallest `.end >=
today`, i.e. the next to finish, whether ongoing or planned (whichever ends
soonest wins). If none (all ended), `gr::latest_challenge` (largest `.end`,
the most recently ended). No challenges at all: `error: no challenges yet.
Run 'goodreads challenges create' to add one.` Both helpers return
`<id>\t<start>\t<end>` (only `<id>` used here; the rest is for
`gr::default_challenge_start`). Defaulting runs before
`gr::require_challenge_file`, so explicit ids are validated as usual.

Pretty output follows `books get`'s shape (one jq call with
`GR_CHALLENGE_STATUS_JQ_DEF` emitting an object, formatted in bash): meta
`[title, "<start> to <end> (<status>)"]`, then `Blogs (N):` and `Badges
(N):` tables (each `column -t -R 1` + `sed 's/^/  /'`, like `books get`'s
series table), each omitted when empty. Blogs columns: `blog_id`, `name`
(or `(unnamed)`), url (`https://www.goodreads.com/blog/show/<id>`); badges
columns: `count`, `name` (or `(unnamed)`). `--json` `cat`s the file.

### `edit`

Requires at least one of `--title`/`--start`/`--end`/`--blogs`/
`--add-blog`/`--remove-blog`/`--badges`/`--add-badge`/`--remove-badge`
(else usage error). **All parsing and validation happens before any
write**, so a bad entry can't half-apply the edit (dates, the resulting
window, `--blogs` fetches, badge counts, `--remove-badge` counts). The
*resulting* window is validated: whichever of existing/new `start` and
`end` apply after the edit (changing only `--end` must still be after the
existing `start`). `gr::update_challenge` merges `--title`/`--start`/
`--end`, and is only called when at least one was given.

- **`--add-blog <blog_id>[:<name>]`** / **`--add-badge <count>[:<name>]`**
  (repeatable): same spec shape and `%q`/`eval` round-trip as `create`'s
  `--blog`/`--badge`. `--add-badge` counts must be positive integers.
  `--add-blog` does **not** fetch or validate the post, and an entry
  without a name gets no default name (unlike `--blogs`). Each is an
  upsert (existing id/count → name replaced in place), reported as `<id>
  -> blog <blog_id> added/updated ("<name>")` / `<id> -> <count>-book
  badge added/updated ("<name>")` (parenthetical only with a name).
  `--add-blog` completes cached blog ids.
- **`--blogs <specs>`** / **`--badges <specs>`**: replace the whole list,
  same comma-separated `<id|count>[:<title>]` syntax as `create`; an
  explicit empty string clears it (`[[ -v args[...] ]]`). Every `--blogs`
  post is fetched (cached or remote) to confirm it exists. An entry without
  a title keeps the name that blog id/count already has on this challenge
  (user decision; an explicit title always wins); failing that, a blog
  entry defaults to the post's own title and a badge stays unnamed. No
  default list (nothing to default to on an edit) and no repeatable
  `--blog`/`--badge` variant (`--add-blog`/`--add-badge` cover that).
  Parsed into the same arrays `--add-*` fill; at write time the list is
  cleared first (`gr::clear_challenge_blogs`/
  `gr::clear_challenge_count_badges`, reported `<id> -> blogs cleared` /
  `badges cleared`), then each entry is re-added via the per-item upsert
  and report. Refused (before any write) when combined with
  `--add-*`/`--remove-*` of the same kind — replace plus incremental change
  has no obvious meaning.
- **`--remove-blog <blog_id>`** / **`--remove-badge <count>`**
  (repeatable; `--remove-badge` values validated as positive integers up
  front): per-item outcome (`<id> -> blog <blog_id> removed` / `<id> ->
  blog <blog_id> not on this challenge`, `<id> -> <count>-book badge
  removed` / `<id> -> no <count>-book badge on this challenge`) plus a
  summary (`Removed N blog(s).` / `Removed N badge(s).`); exit 1 if any
  requested removal wasn't present (like `blogs remove`).
- Write order: title/start/end update, blogs clear (`--blogs`), blog adds,
  badges clear (`--badges`), badge adds, blog removals, badge removals.
  Not semantically load-bearing — an add and a remove of the same kind
  can't target the same key in a way where order matters.

### `remove`

Same shape as `books`/`blogs remove` (`challenge_id...` or `--all`,
mutually exclusive, error if neither, per-id outcome `-> removed` / `->
not found` plus a summary, exit 1 if anything requested wasn't found),
over `gr::challenge_dir`/`gr::challenge_file`. No counter state to roll
back: a removed challenge's id becomes available again to a later `create`
that derives the same id (see "Challenge ids").

## Open design questions

- Still unused from `apolloState`'s Book/Work entries: affiliate/purchase
  links (`.details.links` — commercial, not descriptive, probably skip),
  `characters`/`places` (Work-level, borderline — `{name, webUrl}` and
  `{name, countryName, webUrl, year}`), `choiceAwards` (Work-level,
  separate from `awardsWon` — empty on both books tried so far, shape
  unconfirmed), `bestBook` ref (Work-level — the edition Goodreads
  considers "best/most popular"; a possible alternative to
  `canonical_url`, which can be arbitrary/inconsistently formatted).
  `bookFormat`/`numberOfPages` are still JSON-LD-only — revisit if JSON-LD
  turns out unreliable for them. `editions.webUrl` deliberately **not**
  added — it's `https://www.goodreads.com/work/editions/<work.legacyId>`,
  so storing it would be redundant.
- Whether/when to auto-resolve+cache the *canonical* edition's own JSON
  when a requested book's `canonical_url` points elsewhere (deliberately
  not automatic yet — see "Book metadata cache").
- Command surface for shelves and reading progress (books, blogs and
  challenges are done).
- How challenge-*goal* book selection should work — picking specific books
  toward a badge, given the blog posts/book counts `challenges` records.
  `challenges` only manages that metadata; it doesn't select or recommend
  books yet.
- Which further settings belong in `config.ini` (the `config`
  `list`/`get`/`set`/`unset` commands exist now, covering `curl_bin`,
  `http_request_interval`, `http_challenge_pause`,
  `http_challenge_probe_pct`, `http_challenge_max_probes`,
  `fetch_max_consecutive_failures`, `book_cache_ttl`).

## TODO

- Rename the config keys `http_challenge_probe_pct` and
  `http_challenge_max_probes` (the user finds the names not ideal; not
  urgent).
- Small code issues found while restructuring this file (none affects
  current behavior):
  - `blogs_fetch_command.sh`: `was_cached` means the opposite of its name
    (0 when the file exists); the output labels are right.
  - `challenges list`'s empty-state hint still asks for `--title
    <title> --start <date> --end <date>`, though all three are optional.
  - `gr::discover_blog_ids` ends in `result="$(… | grep -v '^$')"`,
    which would trip `set -e` if it were ever called outside a `||`
    context (all current callers use `|| exit 1`).
  - `challenges edit --remove-blog` has no blog-id completion, unlike
    `--add-blog`.
  - `fetch_one` (books/blogs) calls `gr::status_line_clear` before
    `-> failed`, but runs inside `outcome="$(...)"`, so the clear
    sequence lands in the captured outcome, not the terminal — harmless
    (every error path already runs `gr::term_clear_line`), but it bends
    the "print nothing to stdout on failure" convention.
