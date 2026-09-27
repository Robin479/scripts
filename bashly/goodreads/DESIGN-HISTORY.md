# DESIGN-HISTORY.md — bashly/goodreads

Tried-out and discarded ideas, superseded designs, and the incidents and bug
hunts behind the current design. The current design is in `CLAUDE.md`; this
file is background, so sessions don't re-try what already failed. Key and
constant names are given as they were at the time.

## WAF challenge detection

- **The original symptom: HTTP 202 + empty body.** AWS WAF answers bot-like
  traffic with HTTP 202, an empty body and `x-amzn-waf-action: challenge`.
  `gr::http_get` originally ran curl `-sLf`; `--fail` doesn't catch a 202
  ("success"), so it reported success with empty output. Seen three times:
  a 144-book bulk fetch paced 0.7s apart got real content for exactly 2
  books, then empty bodies for the rest; two follow-up batches (same pacing)
  got 3 real, then empty, each time — a burst allowance of ~3 requests, then
  a hard block lasting well beyond any short retry window, with some memory
  across attempts (a fresh batch didn't get a fresh allowance). The first
  fix retried on "2xx **and** empty body", a branch separate from the
  `--fail` real-failure case.
- **Non-empty challenge pages (2026-09-26).** A `books fetch --challenge` run
  (curl-impersonate via Docker) fetched 28 books, then ~30 in a row failed
  *immediately*, at normal throttle pace and without retries, with `no
  canonical link found`: non-empty, non-book pages passed the empty-body
  check and failed only in the parser. The pages couldn't be identified at
  first — the block had lifted by the time it was probed, and the bodies had
  been discarded with their `mktemp` files. That's why `gr::save_bad_response`
  / `.last_bad_response.{html,headers}` were introduced. The first saved
  response (19:34 the same day) confirmed it: HTTP 202 from CloudFront,
  `x-amzn-waf-action: challenge`, a 2.4 KB JS-challenge interstitial (served
  because curl-impersonate looks like a browser that can run it). Changes:
  `-f` replaced by `-D .last_response_headers` plus classification of the
  final response block (WAF header / 202 / empty 2xx → challenge), the
  blocked marker, and `gr::run_fetch`'s circuit breaker. Later the same day
  429/503 and the `GR_HTTP_EXPECT` body check (`GR_HTTP_EXPECT_CANONICAL` for
  book/blog pages) were added as further challenge signals, so a non-book
  page is retried instead of failing in the parser.
- Verified then with a stubbed `curl_bin` replaying scripted responses:
  challenge-with-body then real → retried and cached; persistent challenge →
  one item's retries, then stop; 3 junk pages → stop, bad response saved;
  junk/real/junk/junk → streak reset, no stop; 404 → fast failure; plus one
  real Docker-curl fetch (headers file written through the bind mount, owned
  by the user).

## Request pacing

The current design (static interval, fixed first pause, percentage probes,
nothing learned) is the fourth iteration. Research data of the three real
test runs, with READMEs: `~/.goodreads/research/pacing/run-2026-09-26T2233/`,
`run-2026-09-27T0914/`, `run-2026-09-27T1128/` (machine-local, not
committed).

### Iteration 0: per-process throttle + per-URL retry backoff

- **`gr::throttle <url>`** (then: before every curl call, retries included)
  slept so that it never returned sooner than a random point between
  `http_request_interval_min` and `_max` seconds (originally
  `min_request_delay`/`max_request_delay`, later `http_request_delay_min`/
  `_max`; defaults 3/10) after its own previous return. State: a plain
  integer-seconds file, `<data_dir>/.last_request_at` — on disk because each
  invocation is its own process. **No locking** ("single-user CLI,
  concurrent invocations aren't worth guarding against") — a stance later
  reversed by the shared, flock-guarded pacer. Verified then: a fresh state
  file passes immediately, a second call waits out the rest of the window, a
  call after the window (e.g. a later process) returns immediately.
  `.last_request_at` is obsolete and safe to delete.
- **Spacing briefly lowered to 1/5, then reverted to 3/10.** Two real
  10-book batches at 1/5 (with the fake book slug already in place) had zero
  WAF challenges, which read as "the fake slug does the real work". Not
  isolated (both changes landed close together), and the user then got
  apparently blacklisted running 1/5 for real — so the two-batch result was
  treated as not representative (too small a sample against a heuristic,
  possibly IP-reputation-based system). Reverted straight to 3/10 (user
  decision), no tightening without new evidence.
- **Retry backoff per URL**, from the config key `http_retry_delays` (later
  renamed `http_challenge_cooldowns`; comma-separated seconds, default in
  `GR_HTTP_CHALLENGE_COOLDOWNS_DEFAULT`), read fresh on every call. Default
  history:
  - `5,15` (~20s total): too short — the block outlasts it easily.
  - `10,30,90` (~130s): a deliberately modest middle ground, reasoning that
    `auth status`'s live check "shouldn't hang for minutes by default".
  - `20,100,480` (600s): that reasoning was explicitly overridden (user
    decision) after repeated WAF throttling — patience matters more than a
    fast failure, even for `auth status`; a caller needing a shorter worst
    case should override the config for its run, not lower the global
    default.
  - Verified: a `gr::config_set http_challenge_cooldowns "1,2"` override is
    picked up on the next call, giving exactly 3 attempts over ~3s.
- Why it was replaced: stopping a batch after exhausting retries is fine as
  a last resort, but no way to leave a big fetch running unattended; the
  backoff restarted for every URL and the random gap ignored what had just
  happened, although the site judges all our traffic, across invocations.

### Throttle message

`gr::throttle` used to print `throttling request to <url> — waiting Ns
before continuing` on every wait. That's routine pacing firing on nearly
every request, and during a `fetch` status line it produced exactly the
"wall of text" the status line replaced (a user restarted a `fetch --update`
right after the WAF-retry fix and got one `throttling request to ...` line
per book, since each routine wait outlasts the fetch itself). Silenced
outright rather than routed through the status line: `gr::throttle` is
generic and can't know whether a status line is active (e.g. `auth status`
has none). The URL argument, once used only in that message, stayed as an
unused hook for per-host pacing.

### Iteration 1: shared adaptive pacing (2026-09-26)

Introduced `src/lib/http_pacing.sh` (user direction): one flock-guarded
`.pacing` state file shared by all processes (replacing `.last_request_at`),
and the two waits named apart — *request interval* vs. *challenge cooldown*
(neither called "delay" any more).
- **Interval**, learned: × 1.5 on the first challenge of a new incident (old
  value remembered as `failed_interval_ms`); × 0.9 after
  `http_request_interval_relax_after` (default 25) successes in a row, never
  below 1.25 × `failed_interval_ms`, so it settles just above the last
  failing tempo; idle decay × 0.9 per `http_request_interval_idle_period`
  (default 1800s) without requests (a cooldown's end counting as activity),
  `failed_interval_ms` too, and streaks/open incidents forgotten, so no
  floor is permanent. Clamped to `http_request_interval_min`..`_max`
  (defaults 3/120s at the time); fresh state started at 6s.
- **Cooldown ladder**: `http_challenge_cooldowns`, one step up per further
  challenge within an incident (default then
  `30,120,300,600,1200,1800,1800,1800`); a new incident started one step
  below the last level if the previous incident took a single challenge,
  else at the same level (`cooldown_level`, `last_incident_challenges`,
  `gr::pace_cooldown_level`). **An incident ended at the first success.**
- **Only a streak's first challenge touched the interval** (a fix, user's
  own catch): a challenge right after a too-short cooldown only says the
  block is still on. Escalating on it too raised the interval twice and set
  `failed_interval_ms` to the already-raised value — a floor the interval
  could never get back below.
- Stale responses, 429/503 and `GR_HTTP_EXPECT` as challenge signals, the
  diagnostics (streaks, `.pacing.log` with rotation) date from here and
  survive.
- **Config key renames** (user direction, no fallbacks — none was ever set
  in the real config): `http_retry_delays` → `http_challenge_cooldowns`;
  `http_request_delay_min`/`_max` → `http_request_interval_min`/`_max`
  (`_max` changed meaning: the learned interval's ceiling, not the random
  gap's upper end); the briefly-existing `http_pace_decrease_after`/
  `http_pace_idle_period` → `http_request_interval_relax_after`/
  `_idle_period`.
- Verified with a timestamp-logging stub `curl_bin` against a scratch build
  and data dir (`http_request_interval_min=1`, cooldowns `2,4,6`,
  relax_after 3): interval holds, then relaxes after 3 successes, gaps
  within interval..1.5×interval; a junk page is retried after the cooldown
  and raises the interval 1.5×; two *parallel* processes both sit out each
  shared cooldown (2s, then 4s, escalated globally) with no request sent
  meanwhile; a persistent block (429, 202, 202, junk) exhausts the ladder in
  4 attempts, sets the marker and stops the fetch; with cooldowns `1,2,3,4`,
  five incidents (3 challenges, 1, 1, 2, 1) used levels 1→2→3, 3, 2, 1→2, 2;
  the log's `first` marker is set once per process across per-item
  subshells; challenge, challenge, success raises the interval once; idle
  decay counts from the cooldown's end; relaxing stops at 1.25 ×
  `failed_interval_ms`.

### Test run 1 (2026-09-26 22:33 – 09-27 08:53): "slower avoids challenges" disproved

`books fetch --update --challenge 2026Q4` (~420 books, killed about half-way),
single process, Docker curl-impersonate, empty config: ~10h, 312 requests
(242 ok, 70 challenges, 46 "incidents").
- Incidents came every ~5-15 min (median ~10-11) regardless of interval. At
  8-16s, 21-29 successes (5-16 min) between them; at the 120s cap only 1-8,
  and per request the slow phase was challenged *more* (~25% vs ~5%;
  confounded with "later in the run" — shows slower didn't help, not that
  it's worse). Throughput fell from ~85 to ~16 books/h.
- × 1.5 on every new incident climbed to the 120s cap within ~1.5h (by
  ~00:05) and never relaxed (longest run at the cap: 12 successes; relaxing
  needs 25). At the cap the 30/120s cooldowns were no longer than the
  interval gap anyway.
- 23 of 46 "incidents" had only 1-2 successes before them: the block let a
  request through after a cooldown, then resumed. Each counted as a new
  incident, wrongly raising the interval and retreating the cooldown level.
- The first challenge came at request #2: most likely a block left over from
  an earlier run that had ended mid-block (~21:56) — deleting `.pacing`
  resets our side, not the site's.
- No `aws-waf-token` in the jar; `logged_out_browsing_page_count` stayed at 2
  over 242 pages — neither explains the rhythm.

### Iteration 2 (2026-09-27, after run 1)

User direction: an incident ends only after 3 successes in a row; the
interval rises only on a *quick* incident (preceded by a success run shorter
than the new key `http_request_interval_raise_below`, default 300s — 1 raise
instead of 7 in run 1's fast phase); `http_request_interval_max` 120 → 60s;
`http_request_interval_min` 3 → 5s. The last follows the user's working
hypothesis of *two* detection layers: a burst detector with a ~10s window
(0.7s spacing blocked after 2-3 requests, a 1-5s random gap got blacklisted,
3-10s mostly worked), which a ≥6s tempo stays under, plus a tempo-independent
periodic challenge; relaxing must not probe back into the burst range.
Verified with the stub: 3 ok + challenge within 5s (test threshold) raises
1 → 1.5s; 8 ok spanning >5s + challenge doesn't; challenge, 1 ok, challenge
is one incident (cooldown level 1 → 2, interval raised once).

### Test run 2 (2026-09-27 09:14 – 10:31): the ~5-minute rhythm

Same command, fresh `.pacing`: 248 ok, 10 challenges, ~190 books/h.
- Success runs lasted 5.2, 5.3, 5.4, 5.6 and once 10.2 min (36-76 requests at
  5-7s) before a challenge — tempo made no visible difference, no sign of
  burst detection.
- A 30s or 120s cooldown never ended a block (3/3); 300s usually did.
- Twice a block let 1-3 requests through within 20s, then resumed; the
  3-successes rule took the second one as a new *quick* incident and wrongly
  raised the interval 5.0 → 7.5s, leaving a false `failed_interval_ms` floor.
- The 300s raise threshold sat right on the rhythm (a 322s run only just
  escaped a raise).

Changes (user direction): the 3 ending successes must span ≥ 2 min; the
threshold became 120s and was renamed `http_request_interval_raise_below` →
`http_burst_detection_window` (the user found "raise_below" confusing — it's
the window within which a challenge is blamed on burst detection rather than
the site's clock); cooldowns dropped the 30/120s steps:
`300,600,1200,1800,1800,1800` (~2h, 7 attempts per URL). Verified with the
stub: 3 and 4 quick successes keep the incident open, one more after
backdating the first by 130s closes it, and the next challenge (run longer
than the 5s test window) leaves the interval alone.

### Iteration 3: probes and a learned block length (user's design)

An incident is the site's clock-based block running its course; after the
first pause each request is a *probe* of whether it ended, and doubling the
time between probes (5 → 10 → 20 min) mostly overshoots a block that lasts a
few minutes with ragged ends. So: the first pause = learned block length
`block_ms` (the previous incident's actual length, first challenge → first
ending success; starting at `http_challenge_initial_pause`, default 200s;
× 0.9 if a single pause was enough; clamped 30s-1h); probes pause
`http_challenge_probe_pct` (10%) of the time waited so far (200s → 20s, 22s,
24s, ...; 30 probes ≈ 58 min); give up after `http_challenge_max_probes`
(30) failed probes instead of a fixed attempt count. Removed
`http_challenge_cooldowns` and the cooldown-level retreat; new state
`block_ms`, `incident_started_ms`; the ending success logged `...; next first
pause Ns`; `cooldown_s` got ms precision. Verified with the stub (first pause
40s): pause + one failed 4s probe → learned 44.3s; next single-pause incident
→ 39.9s; with `max_probes=2` the 2nd failed probe gives up and the circuit
breaker stops the fetch.

### Test run 3 (2026-09-27 11:28 – 14:18) and the simplification

- 11:29: the first challenge came after 3 successes (24s), was taken as a
  burst trip and raised the interval 6 → 9s, leaving a 7.5s floor for the
  whole run. All three runs began with an early challenge — pointing to the
  site's cycle phase rather than bursts.
- 11:29-13:00, steady regime (~200 books/h): runs of 5.2-5.3 min (33-34 books
  at 7.5s) or 10.2-10.4 min (63-64, ≈ 2 × 5.2); blocks measured 293-298s
  (upper bounds). The learned first pause alternated between enough (then
  shrunk 10%) and one failed ~27s probe.
- 13:00-14:18, escalation (~78 books/h): one incident lasted 21.5 min with 16
  failed probes and two single let-throughs; the learned first pause jumped
  to 1290s, and the next incident then measured 2598s (43 min) — both
  artifacts, the measurement swallowing let-throughs and our own over-long
  pause.
- User's interpretation: burst detection plus a ~5-min clock-based challenge
  are the real, stable mechanisms; the midday escalation was probably the
  site fending off load and shouldn't be catered for beyond not letting it
  permanently degrade the mitigation.

Simplified (user direction) to the current static design: fixed
`http_request_interval` (5s + jitter), fixed `http_challenge_pause` (300s),
probes at `http_challenge_probe_pct`, give-up at `http_challenge_max_probes`,
incident-end rule unchanged, a 30-min forget for idle open incidents, nothing
learned. Removed: `http_request_interval_min`/`_max`/`_relax_after`/
`_idle_period`, `http_burst_detection_window`, `http_challenge_initial_pause`,
`block_ms` and `failed_interval_ms`. Verified with the stub (interval 1s,
pause 5s, max 3 probes): gaps 1-1.5s; pause enough → incident ends with 0
failed probes; 2 failed probes (1s minimum probe pause) → ends; the 3rd
failed probe gives up and stops the fetch; an open incident backdated 31 min
is forgotten and a new challenge gets the fresh pause.

(Run 3's README still refers to a CLAUDE.md section "Update 2026-09-27
(simplification)"; that material now lives here and in CLAUDE.md
"Architecture › Request pacing".)

## curl binary auto-detection

- `curl_bin` was originally treated as one literal token, so a multi-word
  value tried to exec a nonexistent binary whose name contained spaces;
  fixed by whitespace-splitting via `read -a`.
- **Per-item re-resolution**: `gr::init_curl_cmd` memoizes in a variable, but
  `gr::run_fetch` runs each item in a `$(...)` subshell, so the memo was
  discarded after every item. A stub `docker` logging every invocation showed
  a 4-book `fetch` running the `docker info` check four times. Fixed by
  resolving once in `books_fetch_command.sh`/`blogs_fetch_command.sh` before
  `gr::run_fetch`; re-verified: one `docker info` plus four `docker run`
  calls for a 4-book run.
- The research behind it (outside sources): plain curl's TLS signature is
  immediately recognizable as non-browser (a layer separate from the
  empty-body handling); no plain HTTP client can pass the JS challenge.
- Docker gotchas found by trying: `:latest` is the Firefox build; without a
  bind mount at the same absolute path the host cookie jar silently stayed
  empty; without `-u uid:gid` files came back root-owned.
- Verified: `curl_chrome116 --version` reports BoringSSL; a real fetch
  through it returns real book data; a nonexistent `curl_bin` path fails
  with "No such file or directory" from that exact path (proving the config
  value drives the call).

## Hooks and cookie jar

- Verified via `bash -x` on the generated script that `before_hook` →
  `gr::init_cookie_jar` → `gr::generic_cookie_jar` → `gr::data_dir` fire in
  that order before any command logic. `initialize()` was rejected as too
  early (before argument parsing, so no `--data-path`) — the same reason the
  config library's one-time `CONFIG_FILE` hook pattern doesn't work here.

## Tab completion

- Alias filtering (`ls`/`rm`/`new` shown next to their long forms) was first
  done in this project's own `src/completions_command.sh`; it moved to the
  repo-wide `bash-completion.d/.template.sh.in`, and this project's hook went
  back to plain `send_completions`. Verified against real `eval "$(goodreads
  completions bash)"` output across command levels: bare TAB after
  `books`/`challenges`/`auth` shows only long forms; `blogs r` drops `rm`
  (both match); `blogs rm` leaves `rm` alone.
- A command-level `completions:` block on `config set` was rejected: in the
  generated script `config set <TAB>` and the `value` slot resolved to the
  same candidate node, so key names would be offered as values.

## Login automation

Tried and abandoned: POSTing the visible static-HTML fields of the LWA
sign-in form as-is, including a plaintext `password`, got a generic "Enter a
valid email or mobile number" rejection **and got the test account banned**.
A HAR capture of a real successful browser login then showed `encryptedPwd`
and `metadata1` instead of `password`. Not to be attempted again.

## Account identification

The selector was first based on `dropdown__trigger--personalNav`, which
turned out ambiguous (also on the notifications trigger); the
`dropdown__trigger--profileMenu` class was verified against a real
authenticated page from a user-supplied HAR.

## `set -e` and shellcheck incidents

- `set -e`: helpers signalling "not found" via non-zero (e.g.
  `gr::current_account` with no session) aborted the script at a bare
  `x="$(fn)"` during the `auth` implementation, before the empty check ran;
  hence the always-`return 0` / `if ! x=...` rules.
- The first-line `# shellcheck disable=SC2154` in every `auth_*_command.sh`
  was silently suppressing SC2154 file-wide. Temporarily stripping it and
  re-linting showed nothing else had been masked; fixed with a leading `:`.

## Session lifetime

Data point (2026-08-29, one real account): `at-main`/`sess-at-main` and most
other cookies valid ~1 year; `_session_id2` only hours.
## Book cache: URLs, fake slug and the id sanity check

- The id-only book URL was checked against the full-slug URL for the same
  book: both HTTP 200, identical `<title>`, identical canonical link. That
  is why `gr::book_url` builds URLs from the id alone.
- The `.query.book_id` sanity check caught a real mismatch while it was still
  an exact comparison: a leftover test fixture, fetched via the full-slug URL
  before the id-only convention existed, had `.query.book_id` ==
  `"199698485-the-god-of-the-woods"` instead of `"199698485"`, and was
  rejected.
- When `gr::refresh_book` started requesting through a random fake slug
  (`.../show/<id>-a-blue-box`), `.query.book_id` always became
  `<id>-<slug>`, so the check was changed from an exact match to comparing
  only the numeric prefix.

## Book cache: TTL

- `book_cache_ttl` initially defaulted to 7 days. Raised to 100 days once
  scraping got more expensive because of throttling risk; book metadata
  doesn't change often enough to justify refreshing it that often.
- `gr::book_fresh` was originally inlined in `gr::book_json`, and used the
  single `find -newermt` call to handle "missing" and "stale" at once. It
  was factored out so `books fetch --all` could report "fresh" vs
  "refreshed", and now has an explicit `[[ -f ]]` check before the `find`.

## Book cache: `set -e` and silent cache blanking

- In an early version of `gr::refresh_book` some stages relied on `set -e`
  instead of explicit checks. A test harness called `gr::book_json` inside
  an `&&` list. That disables errexit for the whole nested call chain, and
  `jq -c .` on an empty file exits 0 with empty output, so a failed refresh
  silently blanked a good cache file. Found by testing exactly that
  `&&`-wrapped call. Fixed with explicit per-stage checks before the final
  `mv`, and `gr::book_json` checking `gr::refresh_book` with `|| return 1`.
- End-to-end verification afterward covered fetch, parse, merge, cache,
  re-reading via `gr::book_json`, the sanity-check mismatch, `work`
  nesting and its null-stripping, empty `series`/`work.awards`, and the
  failure paths (no canonical link / no `__NEXT_DATA__` / no apolloState
  match / no JSON-LD), all leaving no stray file.
- `gr::refresh_book` used to rely on `gr::book_json` having created
  `books/`. Calling it standalone, which its doc comment allows, failed with
  a plain `mv` error, so it now does `mkdir -p` itself.

## Book cache: apolloState whitespace (`clean_or_null`)

- An anomaly sweep over the 144-book test corpus (2026-08-31) found
  double-space author names in the final output (`"James  Patterson"`,
  `"Bill  Bryson"`, `"Rachel  Lyon"`). The whitespace/entity cleanup only
  ran on the JSON-LD side. Because the merge is `$ld * $apollo`
  (apolloState wins), even fields JSON-LD did clean, like `description`,
  lost their clean version to apolloState's dirty one. Fixed by applying
  `clean_or_null` at each apolloState string field's construction site.

## Book cache: ISBN fields

- Originally `.details.isbn` was stored as `isbn`. The same 144-book sweep
  found a self-published/POD edition (id `229004405`) whose `.details.isbn`
  was a 13-digit value identical to `.details.isbn13`, since Goodreads fills
  it that way when there's no true ISBN-10. That would have been a bogus
  "ISBN-10".
- First fix: rename it to `isbn10` and add an `isbn10_or_null` jq def that
  dropped `.details.isbn` unless it was exactly 10 characters, plus a
  top-level `isbn` array combining the non-null `isbn10`/`isbn13`.
- Current design, replacing `isbn10_or_null`: `isbn` is the cleaned, deduped
  union of both source fields (sorted longest first), and
  `isbn10`/`isbn13` are simply its 10-/13-character entries.

## Book cache: awards placement

- An earlier design put the structured awards array at a top-level
  `awards` key. That collided with JSON-LD's own top-level `awards` (a
  folded string, e.g. `"Barry Award Mystery (2025), Anthony Award ..."`),
  and the merge had to be ordered with `$apollo_json` last specifically so
  the structured array won. Moving the structured data to `work.awards`
  (the work, not the edition, wins awards) removed the collision. The
  top-level `awards` is JSON-LD's untouched string again. The merge order
  was kept as insurance.
- Award dates were once full `YYYY-MM-DD`. Every one of Harry Potter's 30
  awards resolved to `<year>-01-01`, so they were switched to year-only.
- The `category` handling was checked on Harry Potter's 30 awards: 14 have
  a real category, and the 16 without one correctly lack the key.
- Concrete test books for null/array handling: Harry Potter (2 series, 30
  awards); "Das Herz des Piraten" (`"series": []`,
  `"work": {"awards": [], ...}`, and `work.title` equal to `title`).

## Book cache: research artifacts

- A saved schema.org/Book JSON-LD example from the initial research lived
  at `/tmp/goodreads-book-jsonld.json` in a prior session. It was never
  committed, so regenerate one from a live fetch if needed.

## `books fetch`: rename from `update` and default changes

- The command was originally `books update` and always force-refetched
  every given id. It was renamed to `fetch` (user direction), in two steps:
  1. Explicit ids stopped force-refetching: a cached id (at any freshness)
     is skipped, and only a missing one is fetched. `--all` still
     force-refreshed every cached book unconditionally.
  2. Later, for per-command consistency, `--all` was also changed to honor
     the TTL (policy `"ttl"`), so `--update` became the only TTL bypass.
- `-A`/`-U` (capitals) were chosen for these renamed fetch commands so
  `--all` reads consistently next to `--update`. Other commands keep `-a`.
- `--challenge` was checked against the real `2026Q3` challenge's 8 linked
  posts. Several books appear in 3 of them, and the deduped set (850 unique
  ids) matched a manual concatenate-and-dedupe of all 8 posts' lists. The
  existing `--blog` dedup handled it with no challenge-specific logic.
- An early `gr::run_fetch` called `$fetch_fn` as a bare statement. Under
  bashly's `set -e`, a mixed cached/uncached id list silently stopped after
  the first cached id, because the "skipped" return `2` aborted the whole
  command. Fixed by calling it inside an `if`.

## Fetch status line

These were five rounds of user-reported bugs, in order.

- **Round one: captured stderr swallowed retry warnings.** `fetch_one`'s
  first version captured the call's stderr
  (`err="$(gr::book_json ... 2>&1 > /dev/null)"`) to print it only on
  failure, after `gr::status_line_clear`. A slow call that eventually
  succeeded therefore lost its only explanation: a WAF bot-challenge retry,
  which could then take up to `20+100+480` s ≈ 10 min. Symptom:
  `books fetch --blog <id> --update` sat on `[1/9] <id>...` for minutes
  with no output, apparently hung. It was diagnosed only via `ps`/`pstree`,
  which showed a `sleep 100` child (the middle value of the then-current
  `GR_HTTP_CHALLENGE_COOLDOWNS_DEFAULT`). Fix: stop capturing stderr (only
  stdout goes to `/dev/null`). To avoid a live warning landing mid-line,
  `gr::term_clear_line` (checks `[[ -t 2 ]]`, deliberately not tied to
  `$quiet`) was added and called by `gr::http_get` before its retry
  warning.
- **Round two: routine throttle messages flooded the output.** Uncaptured
  stderr also unmasked `gr::throttle`'s routine wait message, which fired on
  nearly every request (the spacing was longer than one item's
  processing), so the output was a scrolling wall again. Fix: silence
  routine throttle waits entirely (expected pacing, not worth announcing),
  and keep only the anomalous WAF backoff visible. Verified with a stubbed
  slow-then-successful fetch and `time`.
- **Round three: the status line had never drawn at all.** `gr::fetch_quiet`
  originally echoed `"1"` or nothing and was read via
  `quiet="$(gr::fetch_quiet ...)"`. Inside the command substitution, stdout
  is the capture pipe, so its `[[ -t 1 ]]` was always false and `quiet` was
  always set. Every fetch command had run in `--batch`-equivalent mode since
  the feature was built. The round one and two tests called the helpers
  directly, never through the real `$(...)` call site, so they validated the
  downstream logic but missed this. Lesson: testing a helper directly is not
  the same as testing how it's actually invoked. Confirmed with a real pty
  (`python3 -c 'import pty; pty.fork()...'`; neither redirection nor
  `script` gives one in this environment): the old version produced zero
  status-line bytes on a real terminal. Fix: communicate via exit status,
  called as a real `if` (a bare `... && quiet=1` would trip `set -e` in the
  interactive case). Re-verified by pty for both `books fetch` and
  `blogs fetch`: `\r\033[K[n/total] id...` / `\r\033[K[n/total] id -> outcome`
  per item, and one real newline before the summary.
- **Round four: retry warnings piled up.** Once the line worked,
  `gr::http_get`'s persisted retry warning was too noisy. A sustained block
  hits every item, each retrying several times, which produced many
  near-identical `warning: empty response for ... retrying in Ns` lines.
  Fix: `gr::term_status`, which overwrites in place on a terminal and prints
  a persisted line otherwise. The retry warning went through it, and the
  final "kept returning an empty response" error still used
  `gr::term_clear_line` first. Verified with a stubbed `curl` returning an
  empty body. (Later superseded by the shared adaptive pacer: the visible
  message is now `gr::throttle`'s cooldown wait via `gr::term_status`, and
  `gr::http_get` no longer prints per-retry warnings; see CLAUDE.md
  Architecture.)
- **Round five: parse errors garbled the line.** Parse/validation failures
  inside `gr::refresh_book`/`gr::refresh_blog` (e.g. "no canonical link
  found") still garbled the status line. Their `echo "error: ..." >&2` had
  no clear first, since rounds one and four had only covered
  `gr::http_get`'s own messages. Fix: `gr::term_clear_line` before every
  such error in both functions, added unconditionally rather than auditing
  which paths can fire during a fetch loop (all of them can).
- The status line originally ended with `printf '\n'`. Per user direction it
  now ends with `gr::status_line_clear`, so the summary replaces the last
  update.

## `books list` / `books get` column and layout evolution

- `books list` columns went through several user-directed changes:
  - `published` moved between `id` and `title`;
  - `author(s)` moved in front of `title`, and `pages`/`rating` were added
    after it;
  - `series` was dropped to keep the table narrow;
  - `author(s)` truncation went from 30 to 40 and back to 30;
  - `rating` briefly carried a `★`, later removed. The same happened in
    `books get`'s byline.
- `trunc_authors` was checked on `V for Vendetta`'s 4 authors (55 chars →
  `"Alan Moore, David Lloyd, Steve Whitaker, …"` at 40), and on a synthetic
  single name over 40 chars to confirm the mid-name fallback.
- `strip_tagline` was checked against several real cached titles.
- `books get`: `URL:` was originally the second `meta` line, right after
  the title. It was moved to last per user direction. `series` was
  originally one joined `meta` line and later became its own table.
  Checked against a real standalone book: no `Series:` block at all.
- The cached `series[].url` inconsistency (slug vs. bare id) was found on a
  real book with two series entries. Omitting `www.` was tested for
  `/book/show/` but not separately for `/series/`. It is kept consistent
  anyway.

## Blog cache: purpose and CLI

- The blog cache was first built without any CLI surface, as the "scrape
  and store" half of the challenge workflow, before flagging/matching
  existed. The CLI surface later became the `blogs` group.
- The research behind `challenge_potential`: book count plus cover-grid
  layout correlates with "big listicle", not specifically with
  "challenge". That's why it's a candidate filter, not proof.

## Blog cache: `book_ids` → `book_sections`

- The first version stored a flat `book_ids` array (ids only, no titles or
  grouping). `book_sections` replaced it as a strict generalization
  (flatten `book_sections[].books[]` to recover the old shape).
- `book_sections` originally kept inline prose mentions with
  `title: null`. Real posts mix both forms for the same book: an early
  untitled inline mention, then the same id with a title in its section's
  grid. Dedup preferred the titled occurrence. Current code drops untitled
  books entirely, and also strips trailing `"(Series, #N)"` references from
  titles (`strip_series_ref`).
- Section headings were checked on multiple real posts, including a small
  "weekly recommended books" post with a single heading.

## Blog cache: "Kindle Unlimited" titles

- The title originally came from the first `<img>` anywhere inside the book
  link. `blogs get`'s pretty rendering surfaced several books titled
  literally "Kindle Unlimited" (in JSON they had gone unnoticed). Cause:
  each cover-grid entry is preceded by a sibling
  `<div class="amazonBadge amazonBadge--fourAcrossImage__missing">`
  promotional-badge wrapper. It is usually empty, but when it has an
  `<img>`, that image comes first in document order, and `string()` takes
  the first node. Fixed by requiring the image class to contain
  `AcrossImage`.
- Applied retroactively: 13 of the then-172 cached posts had at least one
  such title. All were re-fetched, and none remained afterward.

## Blog cache: `challenge_potential` heuristic

- **Origin**: a plain boolean `likely_challenge_listing` whose sole
  condition was "body uses the `threeAcrossImage`/`fourAcrossImage` grid".
  It was renamed and changed to a number per user direction ("we will
  refine the rules for the value later, just convert current true and false
  to 1 and 0 for now"). The heuristic was unchanged. The rename was applied
  to the then-172-post cache as a pure data migration
  (`true/false` → `1/0`), not a re-fetch, since the value didn't change.
  `.challenge` didn't exist yet.
- **Count floor (40)**: added after post 3182 ("The Week in Books...", a
  33-book weekly roundup) was still flagged. The threshold was chosen from
  the data: sorted by book count, flagged posts jumped from 12 and 33 (both
  small roundups/promos) to 48+ (all genuine big listicles). This doesn't
  contradict the earlier finding that "count alone doesn't work": a
  *high* count doesn't prove a positive, and a floor only excludes.
- **Reverted "mixed widget" condition**: 3182 mixes its 8 grid picks with a
  second section of `oneAcrossImage` + `bookInfoFullRow` entries (an
  editorial `bookDescription` per book). The reasoning was that a real big
  listicle never mixes the two, so an exclusion was added. It was checked
  against four known-good posts (3140/3184/3043/3145), none of which mixed.
  It was wrong: post 3127 ("Readers' Hit New Books of the Year (So Far)"),
  one of the actual Summer Challenge's 8 badge-linked posts (per the gated
  achievement data from the HAR capture), mixes exactly the same way. The
  condition also added nothing for 3182, which the count floor already
  excluded (33 < 40). It was reverted outright, not turned into a ratio:
  3182 had ~2 of 33 one-per-row books and 3127 had ~11 of 143, too similar
  to separate. Lesson: don't harden against one counterexample with a rule
  stronger than it needs, and check new exclusions against confirmed
  positives too.
- **Audiobook condition, first version**: added after post 3157 ("72
  Reader-Approved Audiobooks for Every Bookish Mood"). It was a clean
  72-entry grid past the floor but not challenge material (user
  direction). The user suggested the tell was square cover art. The markup
  already says so: every cover carries the `--audiobook` BEM modifier, so
  no image inspection was needed. The first version excluded on *any*
  `--audiobook` occurrence and was checked only against 3127 (zero
  occurrences). It broke post 3129 ("The Goodreads Staff...Share Top Book
  Recommendations", the StaffShelves badge, real challenge material), which
  has 8 audiobook covers among 128 plain ones. That repeated the mixed-widget
  mistake, even though the lesson had just been written down. Fixed by
  requiring at least one plain-class cover (3157: zero; 3129: 128). This
  check also subsumed the original "grid present" condition, which was then
  folded into it.
- Every heuristic change was re-applied to the whole cache with a full
  re-fetch (`blogs fetch --all`, at the time), since the body HTML isn't
  persisted.
- Before any hardening, post 3043 ("204 Retellings") had already shown
  that unrelated big listicles use the same grid widget.

## Blog cache: `challenge` override and marker

- The list marker was originally a binary `*`/space. It was replaced by the
  four-state `°`/`*`/`?`/space per user direction.
- Verified that marking a post and then force-refreshing it over the
  network left `challenge` untouched while `challenge_potential` was
  recomputed.

## Blog cache: `body_html` and `--arg`

- The article body HTML used to be persisted as a `body_html` field. It
  was passed to `jq --arg`, which failed on a real 204-book post
  (> 500KB) with `jq: Argument list too long`, because `--arg` values
  become argv elements. Fixed at the time with a temp file +
  `--rawfile`. Later `body_html` was dropped from the cache entirely (user
  direction: structured fields only), so it no longer reaches `jq`. It's
  still extracted to a temp file for the presence check and the
  `challenge_potential` class grep.
- It was verified that a listing post's book list is almost entirely
  `<img alt>` cover-grid elements, which a plain-text extraction would
  drop. That's why the body is extracted with `--output-format=html`.

## Blog cache: `trap ... RETURN` leak

- `gr::refresh_blog` and `gr::mark_blog_removed` once set
  `trap 'rm -f ...' RETURN` without clearing it. The trap, still
  referencing their out-of-scope locals, fired again when the caller
  (`gr::blog_json`) returned. Under bashly's `set -e` without `set -u` this
  was harmless (`rm -f ""`). A manual test driver using `set -u` crashed
  with `unbound variable`. Fixed with self-clearing traps
  (`...; trap - RETURN`). `goodreads_auth.sh`'s two RETURN traps were left
  as-is (out of scope, harmless under bashly).
## blogs fetch

- **`refresh` + `discover` → one command.** Originally two separate
  commands; collapsed into one whose behavior branches on the arguments
  (explicit ids / `--all` / neither), per user direction. It formalized
  what had been done ad hoc via one-off research scripts (see the "news
  catalog" research notes) into a reusable command.
- **`update` → `fetch`, and skip-if-cached.** The explicit-id path used to
  be a command named `update`, which *always* force-refetched a given id
  regardless of cache state. Renamed to `fetch` together with the switch
  to "skip already-cached ids unless `--update`/`-U`", per user direction.
- **`--all` stopped force-refreshing everything.** `--all` alone used to
  unconditionally force-refresh every cached post, which also re-verified
  each one still existed remotely. Changed (user follow-up) to honor the
  cache TTL, for consistency with `books fetch --all`. Since the blog TTL
  is infinite, plain `--all` now never touches cached posts — a known,
  accepted loss ("may make the flag absurd, but consistent with `books
  fetch --all`"); `--all --update` restores the old behavior.
- **Plain `blogs fetch` lost its "no longer listed" report.** An earlier
  version printed missing-from-listing ids on the plain path too. Dropped
  once the scan short-circuits: an incomplete scan can't tell an unscanned
  older id from a vanished one. Only `--all` (full scan) reports it now.
- **`outcome_text`** was added after testing against a nonexistent id
  (999999) printed a misleading "Refreshed blog post 999999." although
  nothing was fetched (the 404 had just written the removed marker).

## Discovery marker

- **Superseded design: `$1`-seeded pagination.** `gr::discover_blog_ids`
  used to take an optional `$1` — a newline-separated set of already-known
  (cached) ids — and seeded its per-page "no new ids" termination check
  with it, so plain `blogs fetch` stopped once it reached ids the cache
  already had instead of walking the full ~18-page listing. It worked: a
  routine run against a fully populated 172-post cache dropped from all
  ~18 pages (several minutes, throttled) to ~2 seconds. In that design the
  plain path filtered against the cache inside the function; only `--all`
  diffed against `cached_ids` itself. Replaced (user direction) by the
  single-id marker: simpler than carrying and re-diffing the whole known-id
  set on every page, and it doesn't depend on the caller's known-id set
  being accurate.
- **Caller-side cache diff became necessary.** With the marker, the
  function no longer filters against the cache. Without the diff in
  `blogs_fetch_command.sh`, a marker-less first run (or the marker's-post-
  deleted fallback) returned already-cached ids that were reported as `->
  fetched` although `gr::blog_json` only served the on-disk copy (no
  wasted network call, just a wrong label). Verified against the real
  172-post cache before and after the fix.
- **Failure leaves the marker untouched** — verified with `--offline`
  forcing a failure: the on-disk marker was unchanged and a later
  successful run continued from it. Explicit requirement: "allow repeating
  a failed discovery with still the old marker."
- `--full` discovery was confirmed to take 17-18 pages against the live
  site when run to completion (hence the 50-page safety cap).
- Without the `content_type=articles` filter, a test showed zero
  additional `/blog/show/` ids, only `/interviews/show/` pages.

## Discovery marker bugs

Two bugs found by testing against the live listing:

1. **Promo banner mistaken for the newest post.** The first version
   extracted ids with a page-wide `grep -oE '/blog/show/[0-9]+'`. The page
   header carries an unrelated promotional banner link (a
   `topFullImage`/`BigBooksFall26_eb`-style React prop, not part of the
   article feed) pointing at some blog post and sitting before the real
   listing in document order, so it was taken as the listing's first
   (newest) entry. In a real fetched page it pointed at the *oldest* post
   visible in the listing. This likely also explains the much older
   finding of "one single stray id past the real page range" (the basis of
   the fallback termination condition): the header renders on every page,
   even out-of-range ones, so such a page can echo nothing but the banner
   link. Fixed by only matching lines that also carry
   `editorialCard__image--fullHeight` (the listing card's cover image
   class, always on the same line as its href; the banner never has it).
2. **Spurious failure with nothing new.** The first live re-run of a
   short-circuited `blogs fetch` with nothing new since the marker exited
   1 with no message. Traced via `bash -x` to the function's last line,
   `sort -n -u <<< "$all_ids" | grep -v '^$'`: with no output `grep` exits
   1, which became the function's status, and callers'
   `gr::discover_blog_ids … || exit 1` treated it as failure. Fixed by
   capturing into a variable and `echo`ing it.

## bashly re-indent bug

Found while building `discover`'s already-cached/catalog set difference.
Its first version built the cached-ids list as
`cached_ids="$cached_ids\n$(...)"` split across two source lines; in the
generated executable this became `cached_ids="$cached_ids\n  $(...)"` —
bashly's per-line indent injected into the string value, giving every id a
stray two-space prefix, invisible in the source. `comm` then never matched
any cached id: a live run reported **all 166** ids as new and
force-refetched every one, including the 33 already cached (instead of the
~133 genuinely new). No error or warning; caught by noticing the fetched
count didn't match expectations and diffing the command file against the
generated function body. Fixed with the one-line
`"${cached_ids}${cached_ids:+$'\n'}${id}"` form.

## Regenerating while running

Regenerating `bin/goodreads` mid-run was done several times during the
`blogs` feature's development without disrupting a several-minutes-long
`blogs fetch --all` (a single overwrite is served from the already-open
file descriptor). But repeated overwrites during one long invocation once
left a stray `line 2845: logs_usage: command not found` at the very end of
its output — a corrupted read from the process's read position no longer
matching any one version of the file. It landed after all real work (fetch
loop, summary counts, missing-ids report) had printed correctly; the final
file count, per-post success count and JSON validity all checked out. Real
corruption nonetheless, which could land somewhere that matters with
different timing — hence the "let background runs finish" rule.

## blogs list

- **Sort order**: originally sorted by id; changed to `published`, most
  recent first, per user direction.
- **`--limit` vs date bounds**: the direction-dependent cap (oldest-n for
  `--since` only, no cap and `--limit` rejected with both bounds) was
  introduced per user direction that "the 15 most recent" isn't what's
  wanted once a bound narrows the range.
- **TSV + `sort`/`awk`/`head`/`tac` → `jq -s`.** An earlier version built
  one TSV row per file (one `jq -r` call each) and did sort/cap/reverse in
  bash. Working but roundabout; replaced by a single `jq -s` pipeline over
  the slurped array, on direct feedback that it was overcomplicated.
- **Fixed-width `printf` → `column -t`.** An earlier version aligned
  columns with hand-picked widths (e.g. `%-7s` for id), which silently
  break once a value outgrows them; replaced by `column -t` on direct
  feedback. `-R 1` (id) and `-R 4` (books) right-alignment were each added
  in their own turn per user direction.
- **Challenge column**: originally two separate leading marker/potential
  columns before `id`; merged into one `challenge` column; its order was
  later swapped from symbol-then-value to value-then-symbol (user
  direction).
- **Column order**: `url` moved to the rightmost position per user
  direction; `title` previously was the trailing column (needing no
  padding). The UTF-8 width handling of util-linux `column` 2.37.2 was
  tested directly with real titles (curly quotes, em dashes).
- **`www.` asymmetry** tested directly: bare `goodreads.com/blog/show/<id>`
  301-redirects to add `www.`; `goodreads.com/book/show/<id>` and the
  `www.` form behave identically without redirect.

## blogs get

- Default output used to be the raw JSON; changed to the pretty book
  listing per user direction (`--json` keeps the old behavior).
- The challenge-potential line used to be shown only when
  `gr_challenge_status` was true; changed to always show the value itself
  (user direction), not just a derived yes/no.
- Book rows used to be `  - Title  [book_id]`; replaced by an id-first
  `column -t` table (user direction), then `url` added as rightmost column
  (user direction). The blank line after each section was also added per
  user direction.

## blogs challenge / remove (renames)

- **`mark` → `challenge`.** `blogs challenge` was renamed from an earlier
  single-id-only `mark` command (user direction), taking the repeatable-id
  shape of `fetch`/`remove`.
- **`delete` → `remove`.** `blogs remove` was `delete` (alias already
  `rm`); renamed to match every other `remove` command. The `blog_id...`/
  `--all` shape was added afterward to match `fetch`. Before, `blog_id` was
  `required: true`, so a bare `blogs remove` was impossible; with
  `repeatable` (optional in bashly) the "nothing given" error is checked by
  hand. Same `delete` → `remove` rename for `challenges remove` (and
  `books remove`).

## Challenge ids

- **Sequential ids → date-derived ids.** Challenges originally had
  sequential integer ids from a `.next_challenge_id` state file, which
  never recycled a removed id. Replaced (user direction) by
  `gr::generate_challenge_id`'s `<year>Q<quarter>` / `<year>-<n>` scheme,
  which checks existing files only — verified that creating `2026Q3`,
  removing it and re-creating an equivalent challenge yields `2026Q3`
  again. See git history for the sequential scheme's details.

## challenges command surface

- **Nested `challenges blogs`/`challenges badges` groups folded into
  `edit`.** An earlier version had a three-level tree (`challenges` >
  `blogs`/`badges` > `add`/`remove`). Per user direction, this became
  `edit`'s `--add-blog`/`--remove-blog`/`--add-badge`/`--remove-badge`
  flags (and later `--blogs`/`--badges`), so e.g. `edit <id> --add-blog
  <blog_id>:<name> --remove-badge <count>` does in one call what took two.

## challenges create

- **Default badge titles swapped.** An earlier default was
  `3:Book Boss,5:Speed Reader`; corrected by the user to
  `3:Speed Reader,5:Book Boss`, along with the existing real challenge(s)
  created with the mixed-up names.
- **Blog titles default to the post's title.** Explicitly given blog posts
  used to be added unnamed when no title was given (bare numeric id); now
  they're fetched and named after the post. The auto-selected default
  blogs were also added unnamed at first; changed per user direction since
  an untitled association was unexpected.
- **Planned-latest failure.** Example that motivated the explicit error:
  three successive no-arg `create`s on 2026-09-19 (under the old
  sequential ids) made #1 (current quarter) and #2 (chained into next
  quarter); #3's "latest" was #2, still planned, so it failed with
  `error: the latest challenge (challenge 2, 2026-10-01 to 2026-12-31)
  hasn't started yet …` instead of falling back to a quarter start that
  would have collided with #1. Before that rule, the planned-latest case
  was caught only by the `gr::challenges_overlapping` check, which was
  verified against a hand-crafted overlapping challenge file.
- The `--start` default's single test was confirmed to cover both "latest
  still ongoing" and "latest recently ended".
- `--badge` round-trip verified with `--badge "2:Page Turner" --badge
  "7:Marathon Reader" --badge 10` → three badges, spaced titles intact.
- The `default:`-applies-to-empty-values bashly behavior was confirmed
  directly (reason `--badges`/`--blogs` have no YAML default).
- **Today cap and curation evidence**: real challenges were observed to
  have only 3-5 of their eventual badges/posts known at creation; and real
  data showed structurally identical same-day posts, one curated into the
  challenge hub and one not.

## challenges edit

- Verified that a malformed `--remove-badge` fails the whole command
  before anything (including `--title`/`--add-blog` given in the same
  call) is written.
- `--blogs`/`--badges` (replace-whole-list) were added later; the rule
  that untitled entries keep their existing title on the challenge was a
  user decision.

## challenges get

- The optional `challenge_id` default was verified to prefer a planned
  challenge ending sooner over an already-ongoing one ending later.
