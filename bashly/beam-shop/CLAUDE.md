# CLAUDE.md — bashly/beam-shop

This file provides project-specific guidance to Claude Code for the `beam-shop`
bashly project. It's layered on top of the repo-wide `CLAUDE.md` at the repo
root, which covers the `make`/`bin`/`bashly` build machinery.

## Purpose

`beam-shop` scrapes book cover images from the webshop www.beam-shop.de (a
Shopware 5 storefront) and organizes them on disk, primarily so they can be
browsed/picked manually. Built for one initial series (Perry Rhodan's classic
"Erstauflage" line — ~3400 issues, released weekly, split across ~46
sub-categories the shop calls "cycles"), but kept generic/config-driven so
other series can be added later without code changes.

Status: `categories` (raw shop taxonomy discovery), `series` (logical series
definitions + the human-browsable view), and `covers` (`fetch`/`resize`) are
all implemented, with a `config` command group mirroring `bashly/goodreads`'
own. No CLI surface exists yet beyond what's listed here.

## Architecture

- **Interaction stack**: `curl` for HTTP, `xidel` for HTML extraction, `jq`
  for JSON, `sha256sum` for placeholder-cover detection, ImageMagick's
  `convert` for resizing. Same tool choices as `bashly/goodreads`, for
  consistency — no other scraping/HTTP libraries.
- **`src/lib/http.sh`** is a straight adaptation of `bashly/goodreads`'s own
  `http.sh` (`gr::` renamed to `bs::`): the same curl-auto-detection cascade
  (`curl_bin` config key -> curl-impersonate on `$PATH` -> a crafted `docker
  run` -> plain `curl` -> hard error), the same empty-body-is-retryable
  handling (`http_retry_delays`), and the same on-disk `.last_request_at`
  throttle (`bs::throttle`). One real difference: **default throttle spacing
  is 3-8s** (`BS_HTTP_REQUEST_DELAY_MIN/MAX_DEFAULT`), not goodreads' 3-10s —
  chosen to match www.beam-shop.de's own `robots.txt` (`Crawl-delay: 3`,
  confirmed present, and `/serien-abo/`/`/media/image/` both confirmed *not*
  disallowed). No cookie jar at all (unlike goodreads) — nothing this tool
  touches needs a login.
- **`bs::http_download`** (new, no goodreads equivalent) is `bs::http_get`'s
  sibling for binary assets — same offline/throttle/retry handling, writes
  straight to a file via `curl -o` instead of stdout, used for cover images.
- **Status-line progress** (`bs::status_line`/`bs::status_line_clear`/
  `bs::fetch_quiet`, `beam_shop.sh`): adapted from `bashly/goodreads`'s own
  `gr::status_line`/`gr::status_line_clear`/`gr::fetch_quiet`, used by
  `covers fetch`, `covers resize`, `series relink`, and `series refresh` —
  all can run for a long time on a large initial backfill (one throttled
  request per page/product for fetch; one `convert` per file, per
  resolution, for resize), so something needs to visibly show it isn't
  hung. **Deliberately always writes to stderr, not stdout** (unlike
  goodreads' versions, which use stdout) — `bs::fetch_category`,
  `bs::series_relink`, and `bs::resize_series` are all called via `$(...)`
  command substitution at their call sites to capture a real return value
  (a count, an outcome string), and stdout status-line noise would leak
  into that captured string, corrupting it (confirmed directly: an earlier
  version of this code did exactly that, producing a garbled "series pr
  relinked (...)" summary line once the escape sequences it had captured
  got echoed back out). stderr is never captured by a bare `$(...)`, so
  this is structurally safe regardless of how a function ends up being
  called. `bs::fetch_quiet` auto-detects via `[[ -t 2 ]]` (is stderr a
  terminal) for the same reason, on top of an explicit `--batch` flag
  where a command exposes one (`covers fetch`/`covers resize`/`series
  refresh`; `series relink` doesn't, it only auto-detects).

### Categories vs. series, and why both exist

The shop's own category tree does not reliably match "one series" — see
"Site quirks" below for the concrete cases that forced this split:

- **Categories** (`src/lib/beam_shop_categories.sh`, `categories` command
  group): the shop's raw taxonomy, keyed by its own numeric category id
  (visible as `?c=<id>` on product URLs and `data-categoryId` in the sidebar
  nav markup). `categories/<id>.json`: `{category_id, name, url, parent_id}`.
  Fetching/pagination always happens against a category — that's the unit
  the site actually paginates (`?p=N`).
- **Series** (`src/lib/beam_shop_series.sh`, `series` command group): a
  user-defined logical entity (`series/<id>.json`:
  `{series_id, name, category_ids (ordered), item_pattern, resolutions}`)
  backed by one or more category ids. For Perry Rhodan this is all 46 cycle
  category ids, in chronological order — auto-sorted by the numeric range
  each cycle's own name/slug already encodes (`bs::parse_range_start`: the
  leading number of a trailing `N-M` suffix, e.g. `3350` from `"PEGASOS
  3350-3399"` / `pegasos-3350-3399`), overridable via `series edit --order
  given` when that heuristic doesn't apply. This produces **one** unified
  series folder rather than one per cycle. `series create`/`series edit`
  (split the same way `bashly/goodreads`' `challenges create`/`challenges
  edit` are — create takes a full spec, edit merges with whatever's already
  there) manage this definition; see "`series` commands" below.
- **Item numbering**: derived per-product from its title via the owning
  series' `item_pattern` (an extended regex with one capture group — well,
  currently `grep -oP`, so really a PCRE lookbehind/capture; e.g. Perry
  Rhodan uses `(?<=Perry Rhodan )[0-9]+`), defaulting to the first run of
  digits (`BS_ITEM_PATTERN_DEFAULT='[0-9]+'`) when a series doesn't set its
  own. A product whose title doesn't match stays unclassified
  (`series_id`/`item_number` both `null` in its `products/<id>.json`) rather
  than being forced in — not every product in a category is necessarily a
  numbered series item. **A real, easy-to-hit misconfiguration**: `grep -o`
  always prints the *whole* match, never a parenthesized capture group, so
  a pattern like `^Perry Rhodan ([0-9]+):.*` — a completely reasonable
  thing to write if you're used to tools that let you pull out group 1 —
  "extracts" the entire title, not the number inside the parentheses.
  `bs::classify_item_number` (`beam_shop_covers.sh`) guards against this
  directly: if the match isn't purely numeric, it's treated the same as no
  match at all (unclassified, plus a warning naming the exact fix — use a
  lookbehind instead) rather than being passed on to `tonumber`. This used
  to crash `bs::fetch_one_product` outright and — worse — truncate that
  product's `products/<id>.json` to empty, since the write wasn't atomic
  (confirmed directly against a real, hand-hit case: fixed by writing to a
  temp file and `mv`-ing it into place, so any future write failure, for
  any reason, still can't corrupt an existing record). `bs::series_relink`
  also learned to require `item_number != null` explicitly (not just
  `cover_status == "final"`) after the same incident — before that fix, an
  unclassified-but-otherwise-fine "final" product got linked into the view
  under a bogus `00000-...` name (`printf '%05d'` on the literal string
  `"null"`, which is what `jq -r '.item_number'` prints for a JSON `null`)
  instead of being correctly left out.

  **A category mapping to a series is necessary but not sufficient for a
  product to belong to it — the item_pattern match has the final say**,
  confirmed against a real, hand-hit case: a book about ship modeling
  turned up in a Perry Rhodan cycle category, and an earlier version of
  `bs::finalize_product`/`bs::record_fetch_failure` stamped `series_id:
  "perry-rhodan"` on it anyway (only `item_number` came out `null`) purely
  because its *category* mapped there — wrong: it isn't "part of the
  series with an unknown number", it just isn't part of the series. Both
  functions now clear `series_id` back to empty whenever
  `bs::classify_item_number` comes back empty, so a non-matching title
  gets `series_id`/`item_number` both `null`, matching the documented
  design above. This wasn't just cosmetic: `series list`'s item count
  (`select(.series_id == $id and .cover_status == "final")`, no
  `item_number` check) counted every such stray product too, before this
  fix.

  **Product↔series is n:1 by construction, not just convention** —
  `products/<id>.json` has a single scalar `series_id` field, and
  `bs::series_for_category` returns only the first series it finds whose
  `category_ids` includes a given category (`return 0` on first match),
  so a product can never end up classified into two series today. Two
  series definitions overlapping on the same category id isn't validated
  against anywhere, though — should that ever happen, every product in
  that shared category would silently go to whichever series
  `bs::series_for_category` happens to hit first (alphabetical-by-filename
  glob order over `series/*.json`), with no warning. The user has asked
  for this to become a real n:m relationship eventually ("it feels more
  correct... it's unlikely this will ever happen") — **explicitly
  deferred, not designed**; don't start on it unprompted. When it does
  come up: the schema change (`series_id` scalar → array, or a separate
  join concept) ripples into `bs::finalize_product`/
  `bs::record_fetch_failure` (classification), `bs::series_relink`/
  `bs::series_audit`/`bs::series_remove`/`bs::find_series_item` (all
  currently `grep -rlF "\"series_id\": \"$id\""`-prefiltered, assuming a
  scalar), and `series list`'s item-count query.
- **The translation layer**: canonical storage
  (`products/<id>.json`/`images/<id>.<ext>`) is always keyed by the shop's
  own stable product id (its `data-ordernumber`, "SW" prefix stripped) —
  this is what dedup/"already fetched" logic uses, and survives any
  reclassification. Each product's JSON carries its resolved
  `series_id`/`item_number` as a forward link. `series/<id>/` is a
  **derived, fully rebuildable view** (`bs::series_relink` — deletes and
  recreates the whole folder every time, so it never accumulates stale
  entries): one pair of symlinks per classified `final` product, named by
  zero-padded item number *alone* (e.g. `00049.jpg`/`00049.json`) — no
  title/slug in the filename, per explicit direction — pointing back at
  the canonical `images/`/`products/` files. `readlink` on a view entry
  recovers the product id; the product's own JSON recovers its series
  position (including the real title, still in there, just not in the
  filename).

### Placeholder-cover detection

Confirmed directly (not-yet-released items can, but don't always, show a
placeholder instead of real art — issue 3399, releasing in ~3 weeks at the
time this was built, already had real unique art; issue 3400, releasing
further out, showed a generic graphic with German text baked in reading
"Dieses Cover dient als Platzhalter. Der Roman wird mit dem Original-Cover
ausgeliefert."). The placeholder gets its own per-ISBN-hashed media URL just
like a real cover (`/media/image/<hash>/<isbn>.jpg`), so URL shape alone
can't tell them apart — detection is content-based (`sha256` of the
downloaded bytes), via two independent mechanisms in
`beam_shop_covers.sh`:

1. **A known-hash seed** (`BS_KNOWN_PLACEHOLDER_HASHES`), extensible via the
   `known_placeholder_hashes` config key (comma-separated, merged with the
   built-in list) — catches a placeholder on the very first product it's
   ever seen on. Two confirmed real hashes are seeded: the full-resolution
   image (`0a504b002eb1359f1b178c25fcd32818fec2d7a47adf1d8dbb885f965ca2ba7f`,
   what `bs::fetch_one_product` actually downloads — see below) and the
   `_600x600` thumbnail variant of the same file
   (`4eaafbe8709bc38712d0956fdb96dd26cf47339367beb52e4b910bb27cc2d007`, kept
   in case a future change starts saving that resolution instead). **This
   exact placeholder is reused across Perry-Rhodan sub-brands** — confirmed
   byte-identical between Perry Rhodan Erstauflage 3400 and Perry Rhodan Neo
   394 at the `_600x600` size — so the known-hash list isn't
   Erstauflage-specific.
2. **Cross-product hash-collision detection** (`bs::register_image_hash`,
   backed by `image_hashes.json`: `{sha256: [product_id, ...]}`) — any hash
   shared by 2+ distinct products is, by construction, not a unique cover.
   Catches any *other* placeholder variant the seed list doesn't know about
   yet (a different series' own placeholder, say), with no hardcoded
   per-series knowledge needed. **Retroactive**: the first product to use a
   given hash is initially `final`; the moment a second product collides
   with it, both flip to `placeholder`.

Either mechanism sets `cover_status: placeholder` on `products/<id>.json`.
This status changes two behaviors: `bs::fetch_category`'s early-exit
pagination ("stop once an already-cached product is hit") only stops on a
`final` product — a cached `placeholder` is always re-checked on the next
run, so real art that later replaces a placeholder gets picked up
automatically (cheap: releases are numerically monotonic, so unfinished
items only ever form a contiguous run at the very front of page 1); and
`bs::series_relink` skips `placeholder` products entirely when building the
view.

### Cover image source: `og:image`, not the listing thumbnail

`bs::fetch_one_product` fetches each product's own detail page and takes its
cover from `<meta property="og:image">` — confirmed (via raw HTML, not a
summarized fetch) to be the full-resolution image, and confirmed to agree
with two other places on the same page that carry the identical URL
(`data-img-original` on the zoom widget, and the lightbox anchor's `href`).
Deliberately **not** the small `_200x200`/`_200x200@2x` thumbnail already
present in the category listing page's own `data-srcset` — that would save
one request per new product, but at a resolution unlikely to be a good
persistent copy, and its sha256 wouldn't match the known placeholder hashes
above (a different rendition hashes differently). The extra per-product
request is one-time (a product's detail page is only fetched when it's not
already cached `final`), so a routine "pick up this week's new issue" run
costs one extra request, not per-cycle-page.

## Site quirks specific to www.beam-shop.de (Shopware 5, "Beam" theme)

- **Category discovery is not a clean top-down tree walk.** Shopware's
  sidebar (`<a class="navigation--link ..." data-categoryId="..."
  href="..." title="...">`) only ever reveals a category's own direct
  children *and* its siblings at its own level — confirmed directly:
  fetching a series page (e.g. Perry Rhodan Erstauflage) shows its ~47
  cycles *and* its sibling series within the same genre, but fetching a
  genre page (`/serien-abo/science-fiction/`) does **not** show sibling
  genres, and the bare `/serien-abo/` landing page shows **no**
  category-tree links via this class at all. `bs::extract_nav_links`
  handles the "already inside the tree" case; the genre list itself only
  exists in the **sitewide mega-menu** (`<a class="menu--list-item-link"
  href="...">`, present in every page's header, no `data-categoryId` at
  all) — `bs::extract_menu_links`, used only for the discovery root,
  synthesizes an id from the url's own trailing slug since there's no real
  Shopware id to use.
- **Fixed bug: a category's own nav link carries extra CSS classes whenever
  it has sub-categories** (e.g. `class="navigation--link link--go-forward"`,
  or `"navigation--link is--active has--sub-categories link--go-forward"`
  for the current page's own entry), never just the bare `navigation--link`
  — confirmed directly on Perry Rhodan Erstauflage's own link within
  `/serien-abo/science-fiction/`. `bs::extract_nav_links`'s original XPath
  (`//a[@class="navigation--link"]`, an *exact* attribute-string match)
  silently excluded every such link — which, since only a category with its
  own children gets the extra classes, meant **any category acting as a
  parent (not just Perry Rhodan) vanished from `categories list` entirely**:
  Atlan, Heliosphere 2265, Maddrax, NEBULAR, Ren Dhark, Star Trek, Raumschiff
  Promet, Warhammer eBooks, and all three Perry Rhodan sub-brands were all
  silently missing from `categories list science-fiction`'s original ~24-row
  output. Fixed by matching the class *token* instead of the whole
  attribute (`contains(concat(" ", normalize-space(@class), " "), "
  navigation--link ")`) — `categories list science-fiction` now correctly
  returns 33 rows including Perry Rhodan Erstauflage (id 43), NEO (id 97),
  and Miniserien & Sonderbände (id 376). **No URL-bootstrap escape hatch is
  needed for Perry Rhodan after this fix** — plain id-by-id drilldown
  (`categories list` → `categories list science-fiction` → `categories list
  43`) reaches all ~47 cycles. `categories list <full https:// url>` (via
  `bs::category_id_for_url`/the url-detection branch in
  `bs::category_children`) remains as a general escape hatch for anything
  genuinely only reachable from the mega-menu (nothing currently requires
  it, but it costs nothing to keep).
- **Pagination**: a category listing page's own `.listing[data-pages="N"]`
  attribute gives the total page count directly — no need to detect
  "empty page" as an end condition. Default sort is by issue number
  **descending** (newest first), which is what makes the early-exit
  incremental-fetch design work.
- **Product ids**: `data-ordernumber` (e.g. `SW319079`) on each
  `.product--box`, "SW" prefix stripped for `bs::products_dir` keys. Not all
  ordernumbers look alike: older/print-digitized cycles use short sequential
  numbers (`SW319079`), while at least the currently-active "Pegasos" cycle
  (native digital/ebook editions) uses a long ISBN-embedded ordernumber
  (`SW9783845364001110164`) — confirmed this is **not** a pre-order-vs-
  released distinction (an already-released older issue in the same cycle
  still has the long form), just two different real numbering generations
  in the same catalog. Both are treated identically — just opaque stable
  keys.

## Global flags

- `--data-path` — see "Data directory" below.
- `--offline` — skip live network requests, serve only cached data.
  `bs::http_get`/`bs::http_download` both refuse immediately when set.

**Tab completion filters a short-form alias (`ls`/`new`/`rm`) out of the
candidate list whenever its own long form is *also* a candidate at that
same position** — bashly's generated `send_completions`
(`lib/send_completions.sh`, fully generated/vendored, never hand-edited)
lists a command's long form and its alias as two equally-weighted plain
words, so a bare TAB after e.g. `series` would otherwise show `create`
*and* `new`, `list` *and* `ls`, `remove` *and* `rm` side by side. This
project's own `src/completions_command.sh` is plain, unmodified
`send_completions` — the fix is not project-specific code any more, it's
a genuinely *global* rule applied once for every bashly project in this
repo: `bash-completion.d/.template.sh.in` (repo root) parses each
project's own `long:short` alias pairs straight from its `bashly.yml` at
shell-startup time and re-registers completion with a filtering wrapper
automatically, with no per-project code at all. See that file's own
header comment for the mechanism, and `~/.claude/rules/bashly.md` (a
global Claude Code rule, not part of this repo) for the general recipe
this is one instance of. Verified directly against the real
`eval "$(beam-shop completions bash)"` output: a bare TAB after
`series`/`categories`/`config` shows only long forms, and typing a short
form's own text (e.g. `ls`, which no longer prefix-matches `list`) still
completes to it normally.

## Data directory

Resolved by `bs::data_dir` (`src/lib/beam_shop.sh`): `--data-path`, else
`$BEAM_SHOP_DATA`, else `~/.beam-shop`. Layout:

```
$data_dir/
  config.ini                     # INI config (bashly's vendored config library)
  .last_request_at               # bs::throttle state
  image_hashes.json              # sha256 -> [product_id, ...], drives placeholder detection
  categories/<id>.json           # raw shop category cache: {category_id, name, url, parent_id}
  categories/.children-of-<id>   # cached child-id list for one parent (or "root"), fresh for category_cache_ttl
  categories/.synced-<id>        # marker: a fetch has walked category <id> to its true end at least once (see "Resumable backfills")
  products/<id>.json             # canonical product metadata (see below)
  images/<id>.<ext>               # canonical downloaded cover, keyed by product id
  series/<id>.json               # series definition: {series_id, name, category_ids, item_pattern, resolutions}
  series/<id>/                    # derived, rebuildable symlink view (bs::series_relink); entries named <00000-padded-item-number>.<ext>/.json, no title/slug
  series-resized/<id>/            # covers resize output (single-profile mode), never touches originals/view
  series-resized/<id>/<spec>/     # covers resize output (per-resolution mode), one subfolder per resolutions[] entry
```

`products/<id>.json` fields: `product_id`, `category_id` (which category it
was fetched from), `title`, `source_url` (the og:image url, or the source
listing url for a `failed` record where no image url was ever confirmed),
`image_sha256` (`null` for `failed`), `fetched_at` (ISO 8601 UTC, meaning
"last attempted" for a `failed` record, not "successfully cached"),
`series_id`/`item_number` (nullable — unclassified if the title didn't
match the owning series' `item_pattern`, or the category has no series
mapping at all), `cover_status` (`final`/`placeholder`/`failed`; a
`failed` record also carries `failure_reason`, a short human-readable
string — see `bs::record_fetch_failure`, `beam_shop_covers.sh`, and
`bs::category_has_failures`'s effect on `bs::fetch_category`'s early-exit,
both under "`covers` commands" below).

**Config file**: same pattern as `bashly/goodreads` — `bs::config_get/set/
del/keys` (`beam_shop.sh`) wrap bashly's vendored `config_get`/etc.,
pointing `CONFIG_FILE` at the resolved data dir on every call (needed
because `--data-path` isn't parsed yet when `initialize()` would otherwise
run once). `BS_CONFIG_KEYS` (`beam_shop_config.sh`) is the `config
list`/`get`/`set` registry — a catalog only; real defaults are asserted
where each key is actually used (`http.sh`, `beam_shop_categories.sh`,
`beam_shop_resize.sh`).

## `categories` commands

`categories list [parent_id_or_url] [--refresh]`, `categories get
<category_id>`. See "Site quirks" above for the discovery-root-is-the-
mega-menu specifics and the class-token selector fix. Plain drilldown
(`categories list` → `categories list <genre-id>` → `categories list
<series-id>`) is enough to reach any series, including ones split into
cycles like Perry Rhodan. Results are cached per parent
(`.children-of-<id>`), fresh for `category_cache_ttl` seconds (30 days by
default — unlike a product's cache, a category's own child list genuinely
does change over time, e.g. a new Perry Rhodan cycle roughly every ~50
issues, so this needs a real TTL rather than "cached forever"; see
`bs::category_children_fresh`, the same `find -newermt` idiom as
goodreads' `gr::book_fresh`); `--refresh` forces a re-crawl regardless of
age.

## `series` commands

`series list`, `series get <id>`,
`series create <id> --categories <ids> [--name] [--item-pattern] [--order
auto|given] [--resolutions <specs>]` (alias `new`),
`series edit <id> [--categories <ids> | --add-categories <ids>]
[--remove-categories <ids>] [--resolutions <specs> | --add-resolutions
<specs>] [--remove-resolutions <specs>] [--name] [--item-pattern]
[--order auto|given]`,
`series relink [id...]` (shows its own status line, auto-detected — no
`--batch` flag on this one, nothing to explicitly opt out of),
`series audit <id>`,
`series refresh [id...] [--limit n] [--force] [--batch]`,
`series remove <id...> | --all` (alias `rm`, same shape as
`bashly/goodreads`' `challenges remove`/`blogs remove`).

**`audit`** (`bs::series_audit`) answers "what's incomplete in this
series?" purely from local metadata — no network access, so it's instant
and works fully offline regardless of series size. Three finding kinds,
one JSON object per line, sorted by item number and rendered as a table
by the command: `missing` (an integer between the series' own observed
min and max `item_number` with no cached product at all — genuinely never
reached by any fetch attempt; nothing to resolve a product id from here,
`covers import` needs its `--product`/`--category`/`--title` form for
this one), `broken` (either a cached `cover_status: "failed"` record — a
fetch attempt genuinely happened and recorded exactly why no cover was
obtained, e.g. a 404'd cover image url, shown appended to the title — or
a `final` record whose `images/<id>.<ext>` file doesn't actually exist on
disk, deleted after the fact or some other inconsistency; both report as
the same kind since both are fixed the same way, `covers import`,
including its `--series`/`--item` shortcut, which works against either
since both already have a real product id/category/title on file), and
`placeholder` (a cached product still stuck there — lower severity, the
real cover may simply not exist upstream yet). Grep-prefiltered the same
way as `series remove`/`series relink`, so it stays fast even across
thousands of cached products.

**A failed fetch attempt is recorded, not left untraced** — confirmed as
a real, reported gap: without this, `missing` and "attempted but failed"
were indistinguishable (both leave no record at all), so a fetch that hit
a 404'd cover url could never be told apart from an item nobody had
looked at yet, and `covers import --series/--item` would have nothing to
resolve a product id from either. `bs::record_fetch_failure`
(`beam_shop_covers.sh`) writes a minimal `products/<id>.json` (title from
the listing/detail page, `category_id`, series/item-number classification
attempted too, `cover_status: "failed"`, `failure_reason`) for any of
`bs::fetch_one_product`'s three failure points (detail page unreachable,
no cover image url found, or the image itself failed to download) instead
of returning empty-handed. This has a real knock-on effect on
`bs::fetch_category`'s early-exit (see "Resumable backfills" above):
`bs::category_has_failures` makes a category with any `failed` record
behave as not-yet-synced even if its `.synced-<id>` marker exists —
without this, a newer `final` item (examined first, newest-first) would
trigger the early-exit before pagination ever reached an *older*, still-
`failed` one, permanently hiding it from routine re-fetches. Verified
directly against the live site: a real full re-walk of a partially-synced
category correctly retried a previously-`failed` item to success, and
separately, in the same run, hit two genuinely broken cover urls on the
real shop (issues 6 and 93 of Perry Rhodan) — both got `failed` records
with the real failure reason instead of silently vanishing into
`missing`.

**`bs::series_audit` was rewritten for performance, confirmed against a
real ~2400-product series: minutes (had to be killed) down to ~3s.** The
original version called `jq` once per field per candidate row (product_id,
title, item_number, cover_status, failure_reason — 5 calls) plus a
per-candidate `bs::image_file` filesystem glob, plus one more `jq -n` per
finding emitted — thousands of subprocess spawns total for a large series,
for a function whose whole point is being a fast, local, no-network check.
Fixed by cutting subprocess count to a small, fixed number regardless of
series size: one directory listing builds a product-id → "has an image
file" lookup (replacing the per-candidate glob), one `jq -r ... | @tsv`
call extracts every candidate row in one pass (replacing the 5-calls-
per-row extraction), the classification loop over those rows is then pure
bash (string comparisons + an associative-array `seen` lookup for the
missing-item-number gap scan — *not* a string-substring `seen_str`
approach, which would silently reintroduce an O(n) cost per lookup right
back), and finally one `jq -R` call converts the whole accumulated
TSV batch into the function's real JSON-lines output (replacing the
per-finding `jq -n`).

**`bs::series_relink` had the identical bug, confirmed the same day
against the same real series: a `covers import` that finished its own
work in seconds then sat relinking for minutes (the user watched one
running invocation still going after 2+ minutes, confirmed via its live
`/proc` state — its target `products/<id>.json` had already been written
correctly well before that).** Same root cause: a per-candidate `jq -e`
filter check (run against *every* grep-prefiltered candidate, matching or
not) plus several more `jq -r` calls and a `tr`+`sed` slug pipeline per
match. Every `covers import`/`covers fetch` call ends with a relink, so
this wasn't a rare-path cost at all — fixed the same way, one `jq -r ...
| @tsv` call filtering and extracting every matching row at once, one
directory listing building a product-id → actual-image-filename lookup.
Confirmed: minutes down to ~12s on the real series, then down to ~6s
again once the view's filenames were simplified to drop the title/slug
entirely (see "The translation layer" above) — the `tr`+`sed` slug
pipeline this file used to preserve German-umlaut-in-filename behavior
for is simply gone now, since there's no slug left to compute at all.

**`refresh`** is the routine day-to-day command, composing three existing
steps for one or more series (default: every defined series) in one call:
per series, fetch every one of its own categories
(`bs::series_category_ids`, same as `covers fetch --series`), relink, then
resize at every one of its preconfigured `resolutions` (`bs::resize_series`
with no width/height override — falls back to the single-profile default
for a series with none, same as `covers resize` would). Unlike `covers
fetch --series id --resize`, which is the same idea for one call's worth of
categories, `refresh` is meant for "just keep everything current" — one
series' failure (an unknown id, a fetch error) doesn't abort the rest; it's
tallied and reported at the end (`ok`/`fail` counts, non-zero exit if any
failed), the same resilience pattern as `series remove`/`bashly/goodreads`'
own `remove` commands. `refresh` prints its own persisted `=== series $sid
[n/total] ===`/`-- category $cid --` headers marking stage transitions,
while the fetch/relink/resize calls underneath each show their own more
granular self-updating status line (one `$quiet` value threaded through
all of them from `refresh`'s own `--batch`/terminal check) — the two never
collide since headers are only ever printed right after the previous
stage's status line already cleared itself.

**`create` vs. `edit`** mirrors `bashly/goodreads`' own `challenges
create`/`challenges edit` split: `create` (`bs::series_create`) takes a
full, from-scratch spec and errors if the id already exists; `edit`
(`bs::series_edit`) errors if it *doesn't*, and merges with, rather than
clobbers, whatever isn't explicitly given this call — `--categories`/
`--resolutions` are each a full replacement (mutually exclusive with
their own `--add-*`/`--remove-*` in the same call), while
`--add-categories`/`--remove-categories` and `--add-resolutions`/
`--remove-resolutions` modify the *existing* list without retyping the
rest — e.g. `series edit perry-rhodan --add-categories 1234` to pick up a
newly-released cycle instead of a full `create` repeating all ~47 existing
ids plus one. `--name`/`--item-pattern` on `edit`, when omitted, keep
their current value (only `create` without `--name` falls back to the
first category's own name). `--order` (default `auto`) always applies to
whichever category list results, in every mode. Every category id a call
actually *introduces* (`--categories`/`--add-categories`, not
`--remove-categories`) is validated against `categories list`'s cache, and
every resolution spec given is checked for stray whitespace
(`bs::validate_resize_specs` — a spec is otherwise passed straight through
to ImageMagick's `-resize`, so its grammar isn't beam-shop's to police
further), before anything is written; ending up with zero categories is a
rejected no-op. A failed call leaves the existing definition completely
untouched, not partially applied. `edit`ing a series (different
categories, resolutions, a corrected `--item-pattern`, etc.) takes effect
on the next `series relink` / `covers fetch` — nothing needs manual
cleanup, the view folder is always fully rebuilt.

**`resolutions`** (`bs::series_resolutions`) is a series' own list of
ImageMagick resize geometry strings, e.g. `700x1000!,300x300` — passed
straight to `convert -resize`, so the shop-standard `!` suffix (force
exact size, ignoring aspect ratio) works exactly as ImageMagick defines
it, alongside a plain `WxH` (fit within, preserving aspect ratio) or any
other geometry ImageMagick accepts. See "`covers` commands" below for how
`covers resize` uses this list.

`series remove` (`bs::series_remove`) deletes only the series' own
definition and everything derived from it (`series/<id>/`,
`series-resized/<id>/` — the latter covers both single-profile and
per-resolution output, since per-resolution subfolders nest under the same
path) — canonical `products/`/`images/` data is never touched, since it's
real scraped fact, not part of the series mapping, but any product
currently attributed to the removed series has its `series_id`/
`item_number` reset to `null` (grep-prefiltered across `products/*.json`
so this stays cheap even with thousands of cached products) — otherwise
redefining a *different* series under the same id later would silently
inherit the old classification on its first `series relink`.

## `covers` commands

`covers fetch (<category_id...> | --series <id>... | --all-series)
[--all-children] [--limit n] [--force] [--resize] [--batch]`, `covers
resize [series_id...] [--width] [--height] [--format] [--batch]`. Both
show a self-updating status line while running unless `--batch` is given
or stderr isn't a terminal (see "Status-line progress" under Architecture
above). `fetch`'s core loop is
`bs::fetch_category` (`beam_shop_covers.sh`): paginate a category (newest
first), stop at the first already-`final` product unless `--force` *or*
this category has never been walked all the way to the end before (see
"Resumable backfills" below), fetch/classify/download each new one via
`bs::fetch_one_product`, then relink every series touched. `--series <id>` (repeatable,
`bs::series_category_ids`) is the usual way to fetch a whole series
day-to-day — it expands to that series' own member category ids, in their
stored (chronological) order, so `covers fetch --series perry-rhodan`
walks all ~47 cycles without listing any ids by hand; give it more than
once to fetch several series in one call. `--all-series`
(`bs::all_series_ids`) expands to every defined series instead — the
routine "check everything for new releases" command. All three id sources
(`category_id` args, `--series`, `--all-series`) are mutually exclusive
(an error, not a silent merge); a category id reached through more than
one given series is only fetched once (deduped, order-preserving).
`--all-children` is the lower-level, series-agnostic tool
for the same kind of bulk backfill — expands each given category id to its
*direct children* first (e.g. `covers fetch --all-children 43` before a
series is even defined for Perry Rhodan).

### Resumable backfills

The early-exit optimization above ("stop at the first already-`final`
product, since releases are numerically monotonic newest-first") is only
sound once a category has been walked all the way to its true end at
least one time — a real bug, reported and fixed directly against this
project: an interrupted large backfill (killed partway through, having
already cached the newest N items) could never be resumed correctly,
because the very next run's page 1 is entirely already-cached items, so
the naive early-exit fired on the *first* item it looked at, and the
older, never-fetched tail of the category silently never got checked
again.

Fixed via `bs::category_synced_marker` (`categories/.synced-<id>`, plain
existence, no content/TTL): the early-exit is only trusted once that
marker exists. Until it does (a category's first-ever backfill, or a
resume after an earlier run was cut short), an already-cached item is
*skipped* (never re-fetched, no need) rather than treated as proof
there's nothing left further down — so `bs::fetch_category` keeps
paginating regardless, at the cost of still walking through (not
re-downloading) however much of the category is already done, until it
either runs out of `--limit` or truly reaches the end. The marker is only
written when a run reaches the true end of pagination *without* `--limit`
cutting it short (`limited` tracked separately from the early-exit's own
`stop`) — a limited run can never prove it saw everything, so it must
never make a future run trust the fast path prematurely either. Verified
directly: `--limit 3` three times in a row on a fresh 49-item category
correctly walked issues 49→44 across the first two calls (skipping the
prior batch each time, not re-stopping on it), a final unlimited call
walked the remaining ~40 down to issue 1 and wrote the marker, and a
follow-up run then correctly early-exited in ~2s instead of ~3 minutes.
`--force` is unaffected either way — it already re-fetches regardless of
cache state, and doesn't touch the marker.

The same "is the early-exit actually safe here" question applies to a
category with a known `failed` record too, even after it's genuinely
synced once — see "A failed fetch attempt is recorded, not left
untraced" under "`series` commands"' `audit` above
(`bs::category_has_failures`) for that half of it.

`resize` (`bs::resize_series`, `beam_shop_resize.sh`) always reads a
series' *view* folder (so output uses the same item numbering) and never
touches originals/the view itself. Two modes:
- **No `--width`/`--height` override, series has its own `resolutions`**
  (see "`series` commands" above): one `convert -resize <spec>` pass per
  resolution string, raw geometry passed straight through with none of the
  padding below — into `series-resized/<id>/<spec>/`, one subfolder per
  spec, so e.g. an exact-stretch `700x1000!` and an aspect-preserving
  `300x300` thumbnail can coexist for the same series.
- **Otherwise** (an explicit `--width`/`--height` always wins over a
  series' own `resolutions`, for a quick one-off override without editing
  the series; a series with no `resolutions` at all falls back here too):
  the original single-profile behavior — pad to exactly width x height
  (never cropping content) on a white background, written flat into
  `series-resized/<id>/`, defaulting width/height/format from their own
  config keys when not given on the command line.

`import <image_file> (--product <product_id> --category <category_id>
--title <title> | --series <series_id> --item <item_number>) [--force]`
(`bs::import_cover`) manually registers a cover the shop's own copy is
unreachable for (some cover image urls 404 on the server even though the
product itself is otherwise fine) but the user already has on file some
other way. `image_file` is the only positional arg — `--product` isn't
one, specifically so an optional-vs-required positional ordering
ambiguity never comes up — and gets real filesystem tab-completion via
bashly's builtin `completions: [<file>]` token (literal angle brackets,
not a shell snippet like this project's other `completions:` entries;
`lib/bashly/completion_builder.rb`'s `BUILTIN_PATTERN` is what recognizes
this syntax and compiles it into a real `compgen -A file` for that
position — an arg with no `completions:`/`allowed:` at all gets no
completion, since bashly's `complete -F` registration has no filename
fallback). **bashly itself never emits `compopt -o filenames` for this**
(confirmed against the actual generator source, both the version this
repo builds with and current upstream HEAD — no version does this), so
without a fix, completing into a directory ends completion with a
trailing space instead of `/`, and a path containing a space gets
inserted raw/unescaped. Fixed for this project (and any other project in
this repo that ever adds a `<file>`/`<directory>`/`<dir>` completion) by
the shared `bash-completion.d/.template.sh.in` — see its own header
comment and `~/.claude/rules/bashly.md` for the full writeup, including
why this is a project-scoped fix rather than argument-scoped (bashly's
generated completion function returns one flat `COMPREPLY` with no
marker for which argument position a candidate came from). The target
product is resolved one of two ways:
- **`--product`/`--category`/`--title`** — the general case, works for
  either a `series audit` **`missing`** finding (nothing was ever fetched,
  so there's no id to look up — this is the only form that works there)
  or a **`broken`** one. `category_id`/`title` can't be reliably
  re-derived without a working fetch (that's the whole problem), so
  they're required alongside `--product` rather than looked up live.
- **`--series`/`--item`** (`bs::find_series_item`) — a shortcut for a
  **`broken`** finding specifically: since the product was fetched
  successfully at some point (only its image file is gone now), its
  product id/category/title are already sitting in the existing
  `products/<id>.json` record, so they're looked up automatically instead
  of being re-typed. Grep-prefiltered by series id first, same technique
  as `series remove`/`series audit`. Errors clearly if no such record
  exists (a `missing` finding, not `broken` — there's genuinely nothing to
  resolve) rather than silently falling through.

Mutually exclusive with each other (an error, not a silent preference).
Refactored the actual classification/write step out of
`bs::fetch_one_product` into a shared `bs::finalize_product` (hash-based
placeholder classification, series/item-number classification, the atomic
`products/<id>.json` write) so `fetch` and `import` produce byte-for-byte
the same kind of record — an imported cover is indistinguishable from a
fetched one afterward, gets relinked into its series' view the same way,
and still participates in cross-product placeholder-hash collision
detection like any other cover. Copies the given file into
`images/<id>.<ext>`, removing any other extension already cached for that
id first (`bs::image_file` just globs `<id>.*` and takes the first match,
so a stale different-format leftover would otherwise linger and could win
that glob unpredictably). Refuses to overwrite an existing cover unless
`--force` — but only when there's a genuinely intact one to protect:
`cover_status: final` with no actual image file on disk (exactly a
`broken` finding) proceeds without `--force`, since there's nothing real
to overwrite; a `placeholder` record is likewise always fair game, same
as a live re-fetch treats it.

## `config` commands

`config list` (default), `config get/set/unset <key>`. Same shape as
`bashly/goodreads`' own `config` group. Keys: `curl_bin`,
`http_request_delay_min`/`_max`, `http_retry_delays`, `discovery_root_url`,
`category_cache_ttl`, `image_width`/`_height`/`_format`,
`known_placeholder_hashes`.

## Open design questions

- No `--all-children` recursion depth limit — fine for Perry Rhodan (one
  level of cycles), would need thought if a future series nested more than
  one level deep under its own category.
- `item_pattern` is matched with `grep -oP` (PCRE), not pure POSIX ERE, so
  lookbehind assertions like Perry Rhodan's own `(?<=Perry Rhodan )[0-9]+`
  work — fine as long as the runtime's `grep` has PCRE support (`-P`);
  worth revisiting if this ever needs to run somewhere that lacks it.
- Cover images beyond a "shared or unique hash" test aren't otherwise
  validated (e.g. no check that a "final" cover is actually a plausible
  book-cover aspect ratio) — the two placeholder-detection mechanisms above
  are the only defense against a bad/generic image being treated as real.
- `series remove` exists (see "`series` commands" above); no command yet
  to remove a cached product or category individually — not needed so far,
  but would follow the same `remove`/`--all` shape if it becomes useful.
