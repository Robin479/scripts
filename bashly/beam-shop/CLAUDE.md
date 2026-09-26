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

**Status: fully implemented on its second data model ("v2").** The original
design (v1) baked `category_id`/`series_id`/`item_number` directly onto each
scraped product record and derived series membership from a single regex
matched only against a category a series explicitly listed. A live
investigation (chasing ~40 "missing" Perry Rhodan covers) proved that
assumption wrong — the covers turned out to be real, already-downloaded ones
fetched under a category the series definition simply never listed, since a
product isn't reliably reachable through just one category. v2 (this
document) replaces that model: canonical scraped data stays pure fact, never
touched by classification; category membership is a persisted *reverse*
relation (category → product, the direction that's actually certain); and
series membership is computed fresh against *every* product regardless of
which category it came from. The v1 data (`~/.beam-shop`) was renamed to
`~/.beam-shop.v1-backup` when this was built — **migrating it (or deciding to
just re-fetch/re-import instead) is still open, not done**, see "Open design
questions" below.

## Architecture

- **Interaction stack**: `curl` for HTTP, `xidel` for HTML extraction, `jq`
  for JSON (including its own regex engine, Oniguruma-backed — see "Series
  matchers" below), `sha256sum` for placeholder-cover detection, ImageMagick's
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
  `covers fetch`, `covers resize`, `series rebuild` (both with and without
  `--covers-only`), and `series refresh` — all can run for a long time (one
  throttled request per page/product for fetch; one `convert` per file, per
  resolution, for resize; one classification pass per cached product for a
  full rebuild), so something needs to visibly show it isn't hung.
  **Deliberately always writes to stderr, not stdout** (unlike goodreads'
  versions, which use stdout) — several of these are called via `$(...)`
  command substitution at their call sites to capture a real return value
  (a count, an outcome string), and stdout status-line noise would leak
  into that captured string, corrupting it (confirmed directly, more than
  once: an earlier version of this code did exactly that). `bs::fetch_quiet`
  auto-detects via `[[ -t 2 ]]` (is stderr a terminal) for the same reason,
  on top of an explicit `--batch` flag each of these commands exposes.
  **Must be called via a plain `if`, never `$(...)`** — a command
  substitution runs in a subshell with its own stdio, which silently
  breaks the `[[ -t 2 ]]` check; every real call site (`covers_import_command.sh`,
  `series_refresh_command.sh`, `series_rebuild_command.sh`,
  `covers_fetch_command.sh`, `covers_resize_command.sh`) uses the plain-`if`
  form for exactly this reason.

### The core problem this data model solves

A product is **not** reliably reachable through just one category — a
product can legitimately be found under several categories over time (a
parent/landing category, a specific cycle, a reissue's own category, ...),
and there is no way to know in advance which one "belongs" to it. v1 assumed
otherwise (one `category_id` field per product, one series per category) and
that assumption is what caused the real incident that triggered this
redesign. v2's design principle, throughout: **only ever persist a relation
in the direction that's actually certain.** We know, for a fact, that a given
category's listing included a given product — that's category → product, and
it's the one relation this project persists. We do *not* know that a product
belongs to *only* that category, so product → category is never stored at
all; series membership is instead computed fresh, globally, against every
product's own title, independent of which category(ies) it happens to be
linked from.

### Category → product linking

`bs::link_category_product` (`beam_shop_categories.sh`): `mkdir -p
categories/<category_id>/products/`, then `ln -sf
../../../products/<product_id>.json categories/<category_id>/products/
<product_id>.json`. Called from `bs::finalize_product`/`bs::record_fetch_failure`
(`beam_shop_covers.sh`) wherever a fetch/import already knows the category
it's working under. A product can be linked from any number of categories
with zero write conflicts, since each link is an independent file in an
independent directory. `bs::categories_for_product` (same file) is the
reverse lookup — **every** category id a product is currently linked from,
one per line (not just a "representative" one) — this *is* the crawl-
agnostic input to matcher category-scoping (see "Series matchers" below):
cheap enough for both a single-product lookup (bounded by the number of
categories that exist, all bash-builtin `[[ -f ]]` checks, no forks) and a
whole-cache one (`bs::_all_categories_for_products`, one pass per category
directory instead of per product — used by `series rebuild`) that no
separate cached `categories` field on the product record itself is worth
the added invalidation surface. `bs::category_has_failures` also switched
to walking this symlink folder directly, instead of grepping every product
for a now-nonexistent `category_id` field. A category's own listing fetch
(`bs::fetch_category`) prunes stale links here too — but only once a run
has genuinely walked the *entire* current listing without any early exit
(neither `--limit` nor the already-synced shortcut), since anything less
hasn't actually confirmed which products are still really listed.

### Series matchers and the classification engine

A series (`series/<id>/meta.json` — see "Data directory" below for why it
moved inside its own directory) no longer has a single `item_pattern`. It has
an ordered **`matchers`** array, each `{pattern, categories}`:

- `pattern` is a PCRE regex (evaluated by `jq`'s own `test()`/`capture()`
  builtins, Oniguruma-backed — **not** `grep -oP`, no new dependency; see
  below) whose only required job is asserting *membership* — does this
  product's title belong to this series at all. It may optionally embed
  named capture groups `(?<index>...)` and/or `(?<title>...)` to also pull
  out an item number and/or a cleaned title from that same match, e.g. Perry
  Rhodan's own `Perry Rhodan 0*(?<index>[1-9][0-9]*): (?<title>.*)`. Neither
  group is required — a matcher can be pure membership-assertion with
  neither (useful for a series with no derivable numbering at all — every
  member just lands at a fallback key, see below, until a human sorts it by
  hand), membership-plus-number, or membership-plus-both.
- `categories` (optional) scopes a matcher to only apply when there's an
  overlap between this list and the product's own *full* set of linked
  categories (`bs::categories_for_product`, every `categories/<cid>/products/`
  symlink pointing at it — a product can be linked from several over time,
  and all of them count, not just one "representative" pick) — omitted/empty
  means it applies regardless of category, the expected common case. Managed
  via its own command group
  (`series matcher add/list/remove`, see "`series` commands" below) —
  deliberately **not** a flag on `series create`/`series edit`, and
  deliberately **never** one compact flag combining pattern and category
  scope on the command line: a regex can itself contain a literal `:` inside
  `(?:...)`/`(?<name>...)`, so a colon-delimited shorthand would be actively
  ambiguous, not just unwanted. **No stored `index` field either** — a
  matcher's own current array position *is* its address for CLI purposes
  (0-based), not stable across an add/remove, and that's accepted by design;
  `series matcher list` always reports each matcher's *current* position,
  computed fresh, never a value read back from storage.

**Extraction mechanism**: `jq -n --arg title "$title" --arg re "$pattern"
'$title | if test($re) then (capture($re) // {}) else null end'` — returns
`null` (no match), `{}` (matched, no named groups at all — the pure
membership-only case), or an object with whichever of `index`/`title` the
pattern actually captured (`capture`'s own behavior omits a named group's key
entirely when it didn't participate in the match — exactly the "present vs.
absent" distinction the engine needs, no further parsing). Requires the
runtime's `jq` to be built with Oniguruma regex support — near-universal on
any modern jq package, same kind of assumption already made (and documented,
not defensively checked) for `grep -oP`'s own PCRE requirement elsewhere in
this project.

**`bs::classify_product <product_id> <title>`** (`beam_shop_series.sh`) is
the entry point — called once per product against **every** defined series
(global matching, not scoped to whichever series, if any, happens to have
one of the product's categories in its own `category_ids`), from
`bs::finalize_product`, `bs::import_cover`, and `series rebuild`. **Crawl-
agnostic by design**: it takes no category argument from the caller at all
— it looks up the product's own full category set itself
(`bs::categories_for_product`, reading the already-on-disk
`categories/<cid>/products/` symlinks, which `bs::link_category_product`
has already written by the time this runs). This is what makes a live
fetch and a `series rebuild` run the *exact same code path* instead of the
old model, where a rebuild had to guess a "representative" category after
the fact — everything here only ever reads what's already persisted, never
anything a caller happens to know from "just crawling" it. Per series, the
algorithm (split into `bs::_resolve_series_match`, pure/no writes, and
`bs::_classify_product_into_series`, which does the actual write — the
split matters, see "`series audit`" below):

1. Check the product's own `overrides["<series_id>"]` (see "Data directory" —
   this lives on the product record itself now, not a separate file):
   `{"exclude": true}` skips this series entirely for this product;
   `{"item": N}` forces the item index to `N`, skipping matcher evaluation
   (title stays the raw product title in this case — no `<title>` capture
   was involved).
2. Otherwise, try the series' matchers in array order (skipping any whose
   `categories` has no overlap at all with the product's own full category
   set). First pattern that matches wins — matching alone is enough, no
   requirement that anything be
   captured. If `<index>` is present in the match, that's the item index; if
   absent (or the pattern captured nothing at all), this is not treated as a
   misconfiguration — it's the expected shape for an item whose title
   carries no clean number, or an entire series deliberately given a
   catch-all membership-only matcher — and falls through to the fallback key
   below. If `<title>` is present, it's used as the pre-cleanup title (a
   lightweight, match-native way to strip a "Series Title #1234: " prefix
   for free, straight from the same regex that already confirms membership);
   otherwise the raw product title is used instead.
3. The pre-cleanup title is passed through `bs::clean_series_item_title
   <series_meta_file> <title>` — a hook prepared for real, non-regex cleanup
   rules (case conversion, etc.), **currently just `echo "$title"`, an
   identity stub**. This is deliberate groundwork, not a finished feature:
   when actual cleanup rules get designed later, only this one function's
   body needs to change.
4. The key is the **storage key**: `bs::_item_storage_key` applied to the
   item index — a *fixed* `item-%04d` pattern (zero-padded to 4 digits so a
   plain `ls` sorts item files naturally), completely unrelated to the
   series' own configurable `item_key_format` (see "`item_key_format` only
   names cover files" below) — or, if there's no
   item index at all, the **fallback key**: `".product-{product_id}"` (e.g.
   `.product-277185`). A real Unix dotfile — genuinely hidden from a plain,
   non-dotglob `ls`/glob, i.e. "hidden file, until a human renames it to
   something useful" — and namespaced with a `.product-` prefix (not just a
   bare `.{product_id}`) specifically so a fallback-keyed series-item's own
   filename can never collide with some *other* dot-prefixed marker this
   project might introduce (it already has one at the series level,
   `.dirty`). Both `series/<id>/.product-{product_id}.json` and its cover
   under `covers/original/.product-{product_id}.<ext>` stay invisible this
   way until renamed. Relink/classify code must explicitly opt into
   `dotglob` to see these at all (symmetric with this project's existing
   `nullglob` convention) — `covers resize` deliberately does **not**, so it
   naturally skips them until sorted, for free.
5. The product id is recorded onto the resolved key's file
   (`series/<id>/<key>.json`'s own `matched.product_ids` array, appended,
   never overwriting a sibling that already matched it) — **every**
   product that currently matches a key is kept on record here, not just
   one "winner"; a real conflict (2+ entries, no `manual.product_id`
   picking a canonical one) is a normal, structurally-representable state,
   not a failure. `derived` is then recomputed (`bs::_recompute_item`) from
   whatever `matched.product_ids`/`manual.product_id` says right now:
   `manual.product_id`'s own data if set (even a product absent from
   `matched.product_ids` — a deliberate promotion; the data model supports
   this already, no command sets it yet), else the sole matched entry's
   data if there's exactly one, else `null` ("undecidable" — this *is* what
   a conflict looks like on disk, surfaced directly by `series audit`'s
   "ambiguous" finding below, with no dry-run needed to find it). Finally
   `covers/original/<display-key>.<ext>` gets relinked to match
   (`bs::_link_series_item` — see "Cover linking is automatic" below,
   naturally clears the symlink if `derived` just became `null`). A real
   conflict is resolved the same way as before: a human adding an
   `exclude`/`item` override to all but the one that should win, then
   `series rebuild`.

**`item_key_format` only names cover files — it has no effect on storage at
all.** This is a deliberate fix for a real, confirmed data-loss bug: the
storage key used to *be* `item_key_format` applied to the item index (step 4
above), so changing `--item-key-format` didn't rename anything by itself,
but the next `series rebuild` computed all-new filenames for every item and,
seeing the old-named files never touched again by its own discovery pass,
deleted them as its normal "genuinely gone" cleanup — silently dropping
whatever `matched`/`manual` state lived on them (verified directly: a
`manual.title` set on `PR0007.json` vanished the moment `--item-key-format`
changed to `XX%04d` and a rebuild ran). The fix: the storage key is now the
*fixed*, index-derived `bs::_item_storage_key` pattern (never changes
regardless of `item_key_format`), and `item_key_format` is confined to
naming the **cover symlink only**:
- `bs::_link_series_item` derives an item's numeric index straight from its
  own fixed-pattern storage key (a plain prefix strip, no more reversing a
  user-chosen pattern), then applies `item_key_format` to build the cover's
  *display* name (`covers/original/<display-key>.<ext>`). The `.product-`
  fallback key has no numeric index, so its display name is just its
  storage key, unchanged.
- `bs::series_relink`/`bs::series_audit` (below) do the same derivation per
  item, inline (matched via `^item-([0-9]+)$` directly, not a shared
  helper function call) rather than via a subshell call — kept
  subprocess-free, a real, measured cost across ~3400 items (see
  "Performance history" below).
- Consequence: editing `item_key_format` never touches any `.json` data
  again, and needs no rebuild for data correctness. Only already-linked
  cover symlink names go stale (still valid, just under their previous
  display name) until whatever next relinks that item, or an explicit
  `series rebuild --covers-only` (a full `covers/` wipe + rebuild — the only
  thing that can find and clean up a cover left behind under a *previous*
  display name, since a single-item relink only ever looks at that one
  item's *current* display name). `series edit --item-key-format` marks the
  series `.dirty` for exactly this reason, same signal a matcher change
  raises, cleared the same way.

**A genuinely serious bash gotcha was found and fixed while building this,
worth remembering for any future TSV-based batch processing in this
project**: `read` treats tab (like space and newline) as "IFS whitespace"
*regardless* of what `IFS` is actually set to, so `IFS=$'\t' read -r a b c`
silently **collapses consecutive tabs into one delimiter** instead of
producing an empty field between them — confirmed directly: an empty
`item_index` (a fallback/unkeyed match), and an empty `failure_reason` (any
product but a "failed" one — the *common* case), were both silently eaten
this way, shifting every later field one slot to the left. Every
`@tsv`/`read` pair in this project that can carry a non-trailing empty field
now joins with **`\x01`** instead (via `join("\u0001")` in the jq side,
`IFS=$'\x01'` on the bash side) — `\x01` has no such special treatment.
`column -t -s $'\t'`-consuming output (a *display* pipeline, not `read`) is
unaffected and still uses plain tabs.

### The translation layer

```
products/<product_id>.json            # canonical scraped fact, PLUS an "overrides" object -- see below
images/<product_id>.<ext>              # canonical fetched cover
images/import-<timestamp>-<pid>.<ext>  # canonical cover for a fully-manual series-item (no real product)

categories/<category_id>/meta.json                     # raw shop category cache: {category_id, name, url, parent_id}
categories/<category_id>/products/<product_id>.json    # symlink -> ../../../products/<product_id>.json
categories/<category_id>/<child_id>                    # symlink -> ../<child_id> (this category's own direct sub-categories)
categories/.root/<child_id>                             # symlink -> ../<child_id> (root-level genres -- the nil-parent's own "children")

series/<series_id>/meta.json                          # name, category_ids (informative only now), matchers[], item_key_format
series/<series_id>/.dirty                             # marker: matcher rules (or item_key_format) changed since the last 'series rebuild'
series/<series_id>/item-<NNNN>.json                   # one file per indexed series-item -- storage key is FIXED (item_key_format plays no part), see below
series/<series_id>/.product-<product_id>.json         # fallback-keyed series-item (no item index) -- {matched, derived, manual} same as above
series/<series_id>/covers/original/<display-key>.<ext> # symlink -> ../../../../images/<...>.<ext> -- display key IS item_key_format applied to the index (or the storage key itself, for a fallback item)
series/<series_id>/covers/<resize_spec>/<display-key>.<ext>  # resize output, one folder per spec
```

**`products/<id>.json`** holds classification overrides too, not a separate
sidecar file: `{...scraped fields, no category_id..., "overrides":
{"<series_id>": {"exclude": true} | {"item": N}, ...}}`. `overrides` is
written only by the `product` command group (below); the scraped fields are
written only by the fetch/import path — **both sides are surgical
read-merge-writes**, never a blind full-file overwrite, so a routine
re-fetch can never silently wipe a manually-set override (or vice versa).

**A series-item file (`series/<id>/<key>.json`) has two layers**, same
"never let one concern's write clobber another's" discipline (a third,
`item_index`, was tried and deliberately removed — see "item_index is
derived, never stored" below):
- **`matched.product_ids`** — every product id that *currently* resolves to
  this key, appended by classification as it discovers each one (never
  removed incrementally — only a full `series rebuild` can safely conclude
  a previously-matching product no longer does, see "series rebuild"
  below). 2+ entries with no `manual.product_id` picking a winner is
  exactly what "ambiguous" means.
- **`derived`** — the *resolved* view, recomputed (`bs::_recompute_item`)
  from `matched`/`manual` every time either changes, never hand-edited:
  `{product_id, title}`, taken from `manual.product_id`'s own product if
  set (even one absent from `matched.product_ids` — a deliberate
  promotion; the data model supports this already, no command sets it
  yet), else the sole `matched.product_ids` entry if there's exactly one,
  else `null` ("undecidable" — 0 or 2+ candidates with no manual pick). No
  longer records *which* category or matcher produced it — reapplying the
  same rules later may match a different one, and nothing ever depended on
  the old value staying accurate.
- **`manual`** (all fields optional, only ever touched by a human or an
  explicit CLI command — `covers import`'s manual path, or a future direct
  edit): **`product_id`** (picks a canonical winner, see `derived` above),
  **`title`**, and **`image_key`** — the filename stem inside `images/` (a
  real product id, or an `import-<timestamp>-<pid>` key), never an
  arbitrary path. Resolution rule for title/image: `manual.<field> //
  derived.<field>`.

**Cover images always live in `images/`; a series-item's own cover is always
a symlink into it — no exceptions, including manually-imported ones.**
`covers import`'s fully-manual path (no `--product`/`--category` resolves,
just `--series`/`--item` plus a required `--title`) copies the given file
into `images/import-<timestamp>-<pid>.<ext>` first, runs it through the
*exact same* `bs::register_image_hash` placeholder/collision pipeline every
fetched cover goes through, then merge-writes `manual.title`/
`manual.image_key` — no product record, no synthetic product id, ever
created. (`bs::import_manual_cover`, `beam_shop_series.sh`; always reports
"final" — there's no per-product `cover_status` to read back for an entry
with no real product, and a human choosing this exact file already did the
judgment call collision detection exists to automate.)

**`item_index` is derived, never stored.** It used to be its own top-level
field, set once at file-creation time — which turned out to be exactly
the wrong design: a series-item's *key* already encodes this number (that's
literally how the key gets computed in the first place), so a separately-
stored copy is redundant data that can drift out of sync with the key it's
supposed to describe. And it did, for real: the write path only ever set
it when creating a brand-new file, never when updating an already-existing
one, so every item that predated that field's introduction silently never
got it backfilled — confirmed directly, this broke `series audit`'s
"missing" range detection across an entire real ~3400-item series (2930
spurious gaps, since the range logic only ever saw the handful of items
that happened to be brand-new). Grepping every real read of `.item_index`
turned up exactly one consumer, `series audit`'s own "missing"/"broken"/
etc. finding logic — nothing else in this project ever reads it back.
So it's gone: `series_audit` (`beam_shop_series.sh`) derives it directly
from each item's own key instead — and since the storage key is now a
*fixed* `item-%04d` pattern rather than the series' own configurable
`item_key_format` (see "`item_key_format` only names cover files" above),
this got simpler too: a plain regex match against the literal `item-`
prefix (`^item-([0-9]+)$`), then the captured digits parsed as base-10
(`$((10#${BASH_REMATCH[1]}))` — a real gotcha: bash arithmetic treats a
leading-zero string like `"0008"` as octal otherwise, which would
hard-error on an invalid octal digit like 8/9; confirmed directly this
needed the explicit base prefix). No more reversing a user-chosen pattern
— every place that needs this inverse (`bs::_recompute_item`,
`bs::_link_series_item`, `bs::series_relink`, here) matches the same fixed
`^item-([0-9]+)$` inline rather than through a shared helper function, to
stay subprocess-free across a per-item loop (see "Performance history"
below). A dot-fallback key (`.product-<id>`) still just gets detected by
its own literal `.` prefix, same as always — no number involved there at
all, derived or otherwise.

**One reserved name to watch for**: a series-item's own storage key must
never collide with `meta` (the series definition's own filename lives
inside the series' directory too, alongside every item file) — moot now
that storage keys are the fixed `item-%04d`/`.product-<id>` patterns
(`bs::_item_storage_key`), neither of which can ever produce `meta`.

### Cover linking is automatic — there is no standalone "relink" command

Every place that changes what a series-item resolves to — a live fetch, an
import, a `product exclude`/`set-item`/`unset` override, a bulk `series
rebuild` — keeps `covers/original/<key>.<ext>` current **as a direct part of
that same operation**, via `bs::_link_series_item <series_id> <key>`: it's
idempotent and self-correcting (its only input is the item's own current
`.json` file, never a value threaded through from elsewhere), so it's safe to
call after *any* change to that one item, however it happened. It resolves
the effective image key (`manual.image_key // derived.product_id`), removes
any existing symlink for that key first (covers an extension change or the
image disappearing), and relinks only if there's a real image to point at —
so calling it on an item that no longer resolves to anything correctly
leaves no symlink behind. `bs::_classify_product_into_series` calls it right
after every successful write; `bs::import_manual_cover` calls it right after
its own write. **There used to be a separate top-level `series relink`
command that did this in bulk for a whole series — it's gone now, folded
into `series rebuild --covers-only` instead** (see below), per direct
instruction: cover-linking should just happen automatically, not be a
separate step every command has to remember to chain, and a repair-only
command doesn't need to be as prominent as a whole top-level `series`
subcommand when there are already several `re*`-prefixed ones.

**When a product's resolved key *changes*** (an immediate override apply —
see below), the *old* key needs cleaning up too, not just the new one:
`bs::_remove_matched_product <series_id> <old_key> <product_id>` removes
the product from the old key's `matched.product_ids`, then calls
`bs::_recompute_item` on it — which relinks/deletes as appropriate (whoever
else is still matched there, or genuinely nothing left). `series rebuild`
itself doesn't need this at all any more (see below) — its own clear-then-
rediscover design handles a moved key without tracking "old" vs. "new"
separately.

**`bs::series_relink` (the old bulk implementation) still exists**, but is
now only reachable via `series rebuild --covers-only` — a genuinely rare
repair path (see "`series rebuild`" below) for when the file tree itself
needs fixing independent of classification (an image or symlink deleted by
hand), not the everyday way covers stay current.

**Products never carry `series_id`/`item_number` any more, so
`series remove`'s old un-classify step (resetting those fields on every
matching product) is gone entirely** — removing a series is now just
deleting its whole directory (`series/<id>/`), which already contains
everything derived from it (definition, every item, `covers/`).

### `series rebuild` — two passes: revalidate in place, then discover

A live fetch/import only ever classifies *one*, genuinely-new product — no
old placement to worry about, and its own cover is already linked as part
of that same write (see above). `series rebuild [id...]` is for the
bulk case: re-running classification against **every** cached product with
zero network access, for after changing a series' *matchers* (`series
matcher add/edit/set-order/remove` — every one of these sets a `.dirty`
marker on the series, cleared once a rebuild actually runs; surfaced in
`series get`/`list`/`audit` as a reminder that current classification may
not reflect the latest rules yet) — something that can affect many products
at once, not just one, so there's no single product to apply an immediate
fix to the way a product override gets (below). `series edit
--item-key-format` (an actual change, not a no-op re-set to the same value)
sets the same `.dirty` marker for a different reason: it doesn't touch
classification at all, but it does mean cover symlinks may now be showing
under a stale display name (see "`item_key_format` only names cover files"
above) — the marker doesn't distinguish *why* a series is dirty, so a full
`series rebuild` (which always clears it) is the one operation guaranteed to
resolve either cause; `--covers-only` (below) alone fixes the cover-naming
case but never clears `.dirty` itself, precisely because it can't tell
whether a matcher change is still unvalidated. Two passes:
1. **Revalidate every already-existing series-item in place** (bounded by
   current item count, not the whole product cache) — for each one, take
   its own current `matched.product_ids` and re-run *each* referenced
   product through `bs::_resolve_series_match` against today's matcher
   rules, keeping a product only if it still resolves back to this *same*
   key. This is deliberately stricter than "does it match something
   somewhere" — a matcher/category change can just as easily move a
   product to a *different* key (a captured item number changing, say),
   in which case it's dropped here and picked up under its real key by
   pass 2, exactly like a brand-new match. Whatever survives becomes the
   new `matched.product_ids`; `bs::_recompute_item` then resolves `derived`
   from it the normal way — a `manual.product_id` pick always wins if set,
   *even with nothing surviving validation at all* (a deliberate
   promotion is never touched by this pass), else the sole survivor, else
   `null`; the file is only ever deleted if *both* end up empty. This is
   what makes a "this stopped matching" case fully self-contained within
   this one pass — nothing needs to "come back" to an item afterward.
   Every product confirmed still-current here is recorded into an
   in-memory `settled_products` set for pass 2 to skip.
2. Walk every cached product *except* one already in `settled_products`
   (pass 1 already confirmed its placement can't have changed), re-running
   the *exact same* per-product classify path a live fetch uses
   (`bs::_classify_product_into_series`) to discover anything genuinely
   new: a brand-new product, one whose title/category just started
   matching, or one pass 1 just dropped from its old key that needs a new
   home (if any) — same "no separate old-key tracking" property as
   before, since pass 1 already fully closed the loop on every
   pre-existing item on its own.

This replaced an earlier three-pass design (blind-clear every item, walk
every product, then unconditionally re-sweep every pre-existing item a
second time to catch whatever pass 2 never touched) that was both
conceptually awkward — the third pass existed purely to compensate for
the first one not actually validating anything — and, before an interim
fix, a real, measured cost: without at least tracking which keys pass 2
already fully recomputed, that blind third-pass resweep was confirmed to
roughly double a real ~3400-item rebuild's total time (50m48s -> 91m21s,
after an unrelated `derived.title` fix made each recompute itself more
expensive). This two-pass design is both simpler to reason about and
cheaper: pass 2 no longer needs to re-test every product already known to
be correctly placed, and there's no redundant second recompute of
anything pass 1 already settled.

**`series rebuild --covers-only`** skips classification entirely and just
calls the old bulk `bs::series_relink` — a full `covers/` wipe, then
walking every already-existing series-item file and relinking its
`covers/original/<display-key>.<ext>` symlink from whatever it already says
(same `item_key_format`-applied display-name derivation `bs::_link_series_item`
uses, computed once per series rather than passed in, see "`item_key_format`
only names cover files" above), with zero effect on any `.json` file (and
doesn't clear the `.dirty` marker, since it never actually re-validates
matcher rules). Being a full wipe is what makes this the one operation that
can clean up a cover left behind under a *previous* display name after an
`item_key_format` change — an incremental single-item relink can't, since it
only ever knows that one item's *current* display name (see above). This is
also the rare "the file tree itself is wrong, not the classification" repair
path (an image or symlink deleted by hand, say) — everyday cover-linking
never needs it otherwise, since it already happens automatically (see
above).

### Product overrides apply immediately, not on the next rebuild

`product exclude`/`set-item`/`unset` (see "`product` commands" below) don't
just write the override and leave it for later — `bs::apply_product_override
<product_id> <series_id>` (`beam_shop_series.sh`) re-resolves that *one*
product into that *one* series right away: looks up its title and its full
category set (`bs::categories_for_product`, the same crawl-agnostic lookup
`bs::classify_product` itself uses — no "representative category"
simplification any more, since the full set is cheap enough for both a
single-product and a whole-cache lookup, see "Category → product linking"),
finds whatever key it currently matches there via `bs::_find_current_key` (a
grep-prefiltered scan of that series' own item files, checking
`matched.product_ids` membership — bounded by series size, not the whole
product cache, and only ever a one-off per override change, not a hot-path
cost), reclassifies (`bs::_classify_product_into_series` — records/links the
new key, or does nothing if the product no longer belongs here at all),
then removes it from the old key's `matched.product_ids` if that changed
(`bs::_remove_matched_product`). A product that was never classified into
this series to begin with, and still isn't after the override, is a
correct, silent no-op. This is specifically why `series rebuild` (the bulk
pass) is only needed after a *matcher* change — a single product's own
override is already live the moment the command returns.

`bs::apply_product_override` ends with an explicit `return 0` — without
it, its own exit status is whatever its last `&&`-chained line happens to
be, which is 1 whenever nothing resolves (a correct, common no-op, e.g.
every `product exclude` call). Every command script calls this function
bare/unguarded, so `set -e` would otherwise abort the caller before it
prints its own confirmation line.

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
   yet, with no hardcoded per-series knowledge needed. **Retroactive**: the
   first product to use a given hash is initially `final`; the moment a
   second product collides with it, both flip to `placeholder`. This still
   works exactly as before — `cover_status` lives on `products/<id>.json`,
   untouched by the v2 redesign (only `category_id`/`series_id`/
   `item_number` were removed from products, not `cover_status`/
   `image_sha256`/etc.).

`bs::fetch_category`'s early-exit pagination ("stop once an already-cached
product is hit") only stops on a `final` product — a cached `placeholder` is
always re-checked on the next run, so real art that later replaces a
placeholder gets picked up automatically. **Classification/cover-linking no
longer excludes a `placeholder` product from the human-browsable view the
way v1 did** — classification only ever looks at a product's *title*, not
its `cover_status`, so a placeholder cover is now classified and linked like
any other final one; `series audit`'s own `placeholder` finding still flags
it (by cross-referencing the linked product's own `cover_status`), so it's
discoverable, just not automatically hidden from browsing any more. Not yet
decided whether that's worth restoring — see "Open design questions."

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
  parent (not just Perry Rhodan) vanished from `categories list` entirely**.
  Fixed by matching the class *token* instead of the whole attribute
  (`contains(concat(" ", normalize-space(@class), " "), " navigation--link
  ")`). `categories list <full https:// url>` (via `bs::category_id_for_url`/
  the url-detection branch in `bs::category_children`) remains as a general
  escape hatch for anything genuinely only reachable from the mega-menu.
- **A category's own listing may not include every issue it nominally
  covers** — confirmed directly: category 70 ("Die Tolkander 1800-1875")
  only ever lists 48 of its 76 nominal issues (its own `data-pages="4"` at
  12/page = exactly 48 — the tool wasn't missing anything, the shop's own
  catalog simply doesn't carry the rest any more), and the products it does
  carry aren't even listed in a numerically-sorted order (a live re-fetch of
  its page 1 came back as `1875, 1865, 1862, 1874, 1843, ...`). This is
  fine, even beneficial, under the v2 model — global matching means it
  genuinely doesn't matter which category (if any) actually lists a given
  issue, as long as *some* category the tool ever fetches does. It's the
  reason the early-exit pagination assumption ("releases are numerically
  monotonic newest-first") should not be trusted as a universal property of
  every category — see "Resumable backfills" below for where that
  assumption is actually load-bearing (it still holds for the parent
  category's *own* listing order in practice, just not necessarily for
  every possible category).
- **Pagination**: a category listing page's own `.listing[data-pages="N"]`
  attribute gives the total page count directly — no need to detect
  "empty page" as an end condition.
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
this is one instance of.

## Data directory

Resolved by `bs::data_dir` (`src/lib/beam_shop.sh`): `--data-path`, else
`$BEAM_SHOP_DATA`, else `~/.beam-shop`. Layout:

```
$data_dir/
  config.ini                              # INI config (bashly's vendored config library)
  .last_request_at                        # bs::throttle state
  image_hashes.json                       # sha256 -> [product_id, ...], drives placeholder detection

  categories/<id>/meta.json               # raw shop category cache: {category_id, name, url, parent_id}
  categories/<id>/products/<pid>.json     # symlink -> ../../../products/<pid>.json (category -> product, the one persisted relation)
  categories/<id>/<child_id>              # symlink -> ../<child_id> (this category's own direct sub-categories)
  categories/<id>/.synced                 # marker: this category's own child list was crawled, fresh for category_cache_ttl
  categories/<id>/products/.synced        # marker: a fetch has walked category <id>'s products to their true end at least once
  categories/.root/<child_id>             # symlink -> ../<child_id> (root-level genres -- the nil-parent's own "children")
  categories/.root/.synced                # marker: the discovery root's own child list (the genre list) was crawled

  products/<pid>.json                     # canonical scraped fact + "overrides" -- see below
  images/<pid>.<ext>                      # canonical downloaded cover, keyed by product id
  images/import-<timestamp>-<pid>.<ext>   # canonical cover for a fully-manual series-item, no real product involved

  series/<id>/meta.json                        # series definition: {series_id, name, category_ids, matchers, item_key_format, resolutions}
  series/<id>/.dirty                           # marker: matcher rules (or item_key_format) changed since the last 'series rebuild'
  series/<id>/item-<NNNN>.json                 # one file per indexed series-item: {matched, derived, manual} -- fixed storage key, item_key_format plays no part (item_index is derived, not stored)
  series/<id>/.product-<pid>.json              # fallback-keyed series-item (no item index) -- same shape
  series/<id>/covers/original/<display>.<ext>   # symlink -> ../../../../images/<...>.<ext> -- display name IS item_key_format applied to the index
  series/<id>/covers/<spec>/<display>.<ext>     # resize output, one folder per resolutions[] entry (or per --width/--height override)
```

**Every JSON record in this tree is written via `bs::write_file`**
(`beam_shop.sh`), never a plain, *unguarded* `jq ... > file`: the caller
builds the new content in a variable first (`content="$(jq ...)"`),
checks that capture's own exit status, and only then hands the
*already-known-good* content to `bs::write_file`, which does a single
plain `printf '%s\n' "$content" > "$file"`. This used to be a hand-rolled
`tmp="$(mktemp)" ... && mv "$tmp" "$file"` per call site, guarding
against the same thing: **a `jq` failure must never truncate the real
file** -- a real, previously-hit incident (an earlier direct `jq ... >
product_file` corrupted an already-successfully-downloaded cover's record
this way). The variable-capture-then-check *is* the fix, on its own --
command substitution only returns once `jq` has fully exited, so by the
time `bs::write_file` runs, the content is already a complete string
sitting safely in memory, with no still-writing, possibly-failing
producer left to protect the real file against. A plain write at that
point is exactly as safe as the old `mktemp`+`mv` dance, simpler, and
(bonus) doesn't have `mktemp`'s own hardcoded-`0600`-regardless-of-umask
problem either -- a truncating write to an *existing* path reuses the
same inode, so its permissions are automatically preserved, and a
brand-new path goes through the normal umask-respecting `open()` (both
confirmed directly). An earlier version of this piped the
already-buffered content through moreutils' `sponge` on top of the same
guard -- entirely redundant (sponge's whole job is buffering an
*in-progress* stream before committing it, and the content was never
in-progress by the time it reached there) and removed once that was
noticed.

**Two write paths don't go through `bs::write_file` at all**: downloaded
cover images (`bs::http_download`, via `curl -o`) and manually-imported
covers (`cat -- "$src_file" > "$dest"`, `covers import`/`series`
manual-cover import) aren't JSON records built from a jq filter, so
there's nothing to buffer-and-check the same way -- but both still needed
to actually respect umask, which took two different, unrelated fixes:
- `curl -o` already respects the calling process's own umask correctly on
  its own (confirmed directly) — the only reason images ever came out at
  the wrong mode was this project's curl auto-detection previously
  preferring a Docker-based curl-impersonate fallback whenever no
  impersonate binary was on `$PATH` (its container has its own, unrelated
  default umask of `0022`, confirmed directly, regardless of the host's
  actual umask) — now fixed by making plain `curl` on `$PATH` the
  default, ahead of curl-impersonate/Docker in `bs::init_curl_cmd`'s own
  priority order (`http.sh`; this project doesn't need curl-impersonate's
  browser-fingerprint spoofing at all -- nothing about www.beam-shop.de
  has ever required it -- and silently bootstrapping a Docker container
  on every single request was also a real, avoidable slowdown).
- Importing a local file used to be a plain `cp`, which genuinely does
  *not* respect umask -- it preserves the *source* file's own mode bits
  verbatim (confirmed directly: copying a 0600 source under umask 002
  still yields a 0600 copy). Switched to `cat -- "$src_file" > "$dest"`
  instead of `cp` at both call sites -- a plain redirect creates the
  destination via the normal umask-respecting `open()` regardless of
  whatever mode the source file happens to have, with no separate chmod
  needed (an earlier version called a `bs::chmod_like_umask` helper after
  the `cp` for this; removed once `cat` made it unnecessary).

**The same `.synced` filename appears at two different levels, deliberately,
for two related but distinct facts**: `categories/<id>/.synced` (or
`categories/.root/.synced`) means "this category's own *child-category
list* was crawled, fresh for `category_cache_ttl`" (mtime matters, see
`bs::category_children_fresh`); `categories/<id>/products/.synced` means
"a fetch has walked *this category's own products* all the way to the
true end of pagination at least once" (plain existence, no TTL, see
`bs::category_synced_marker`/`bs::fetch_category` below). One folder
level apart, one about sub-categories, the other about products.

**`products/<pid>.json`** fields: `product_id`, `title`, `source_url` (the
og:image url, or the source listing url for a `failed` record where no
image url was ever confirmed), `image_sha256` (`null` for `failed`),
`fetched_at` (ISO 8601 UTC, meaning "last attempted" for a `failed` record),
`cover_status` (`final`/`placeholder`/`failed`; a `failed` record also
carries `failure_reason`), and `overrides` (`{"<series_id>": {"exclude":
true} | {"item": N}}`, sparse — most products have no entries at all).
**No `category_id`/`series_id`/`item_number`** — see "The core problem this
data model solves" above for why.

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
cycles like Perry Rhodan.

**Every category is its own folder, flatly, directly under `categories/`**
(`bs::category_dir`) — never nested inside its parent's own folder,
regardless of its real `parent_id`. A category's own *children* are plain
relative symlinks (`../<child_id>`) sitting inside that same folder,
alongside its `meta.json` and `products/` — so `categories/<id>/` holds
everything about that one category (its metadata, which products were
found under it, and which sub-categories it has) in one place, the same
principle `series/<id>/` already follows. The one category with no real id
of its own — the discovery root's own children, the genre list — gets a
dedicated `categories/.root/` folder to hold *its* child symlinks instead
(`bs::category_children_dir`, returns a category's own folder for a real
id, `.root` for the nil-parent).

Results are cached per parent (a `.synced` marker file inside that
parent's own folder -- or `categories/.root/.synced` for the root; not to
be confused with `categories/<id>/products/.synced`, one level deeper,
which instead marks *that category's own products* as fully backfilled —
see "The same `.synced` filename appears at two different levels" above),
fresh for `category_cache_ttl` seconds (30 days by default —
unlike a product's cache, a category's own child list genuinely does
change over time, e.g. a new Perry Rhodan cycle roughly every ~50 issues,
so this needs a real TTL rather than "cached forever"; see
`bs::category_children_fresh`, the same `find -newermt` idiom as
goodreads' `gr::book_fresh`); `--refresh` forces a re-crawl regardless of
age. A cache-fresh read lists the marker's own folder's child symlinks
directly (`bs::list_category_children`); a re-crawl (`bs::crawl_children`)
is self-correcting, the same way cover-linking is — any child symlink left
over from an earlier crawl that isn't among the current crawl's children
gets removed, not left to linger. Every category listed here is now also,
potentially, a source of `categories/<id>/products/*.json` symlinks once
anything's fetched from it — see "Category → product linking" above.

## `series` commands

`series list`, `series get <id>`,
`series create <id> --categories <ids> [--name] [--item-key-format]
[--order auto|given] [--resolutions <specs>]` (alias `new`),
`series edit <id> [--categories <ids> | --add-categories <ids>]
[--remove-categories <ids>] [--resolutions <specs> | --add-resolutions
<specs>] [--remove-resolutions <specs>] [--name] [--item-key-format]
[--order auto|given]`,
`series matcher add <id> --pattern <regex> [--categories <ids>]`,
`series matcher list <id>` (alias `ls`),
`series matcher edit <id> --index <n> [--pattern <regex>]
[--categories <ids> | --add-categories <ids>] [--remove-categories <ids>]`,
`series matcher set-order <id> --index <n>...`,
`series matcher remove <id> --index <n>...` (alias `rm`),
`series audit <id> [--hide-promoted]`,
`series rebuild [id...] [--covers-only] [--batch]`,
`series refresh [id...] [--limit n] [--force] [--batch]`,
`series remove <id...> | --all` (alias `rm`).

**`series refresh [id...] [--limit n] [--force] [--batch]`** is the
everyday day-to-day command: for each given series (default: all), fetch
every one of its member categories (`bs::fetch_category`, classifying and
linking covers as products are discovered — see "Cover linking is
automatic" below), then resize it (`bs::resize_series`). No separate
relink step needed afterward, same reasoning as `covers fetch`.

**No standalone `series relink` command** — cover-linking is automatic now
(see "Cover linking is automatic" above); `series rebuild --covers-only` is
its only remaining home, for the rare case where the file tree itself
needs repairing independent of classification.

**A series no longer carries a single `item_pattern`** — see "Series
matchers and the classification engine" above for the full design
(`matchers[]`, `item_key_format`, the fallback dot-key, the title-cleanup
hook). `series create`/`series edit` manage everything *except* matchers
(name, categories, resolutions, item_key_format) — matchers themselves are
their own command group, addressed by current array position, never by
retyping a pattern on the command line (a regex can contain shell-hostile
characters, and a colon-combined `pattern:categories` shorthand would be
genuinely ambiguous against a regex that itself contains `:`). A freshly
created series starts with zero matchers — nothing classifies into it until
at least one is added.

**`create` vs. `edit`** mirrors `bashly/goodreads`' own `challenges
create`/`challenges edit` split: `create` (`bs::series_create`) takes a
full, from-scratch spec and errors if the id already exists; `edit`
(`bs::series_edit`) errors if it *doesn't*, and merges with, rather than
clobbers, whatever isn't explicitly given this call. `bs::_write_series`
(shared by both) deliberately preserves whatever `matchers` the file
already had across either call — a plain `series edit --name ...` must
never silently wipe out matchers the same way it must never silently wipe
`category_ids`/`resolutions` it wasn't asked to touch.

**`series matcher add <id> --pattern <regex> [--categories <ids>]`**
appends to the end of the matchers array (`bs::add_series_matcher`).
**`series matcher list <id>`** (`bs::series_matchers`, printed via the
shared `bs::print_series_matchers_table` — also used by `edit`/`set-order`
to show the result of what they just did) prints each matcher's own
*current* position, pattern, and category scope — the position is what
`series matcher remove --index <n>` (repeatable) uses to address one,
`bs::remove_series_matcher_at`; removing more than one in the same call
resolves each index against the list as it stood *before* that call (the
command script sorts requested indices highest-to-lowest first, so an
earlier removal's shift never corrupts a later one's target).

**`series matcher edit <id> --index <n> [--pattern <regex>] [--categories
<ids> | --add-categories <ids>] [--remove-categories <ids>]`**
(`bs::edit_series_matcher_at`) updates the matcher at `<n>` in place —
same position afterward, unlike a remove+add round-trip. `--pattern`
omitted leaves the existing pattern untouched; the category-scope flags
mirror `series edit`'s own conventions (`--categories` is a full
replacement, mutually exclusive with `--add-categories`/
`--remove-categories`, which merge into the matcher's current scope). At
least one of the four flags must be given.

**`series matcher set-order <id> --index <n>...`**
(`bs::reorder_series_matchers`) reorders the whole array: the given
indices — an *ordered* set, unlike every other repeatable `--index` in
this command group — move to the front in the order given; every matcher
not named follows, in its own current relative order. Since matching is
first-match-wins, this is how you change *which* rule wins for a product
several rules would otherwise match. Implemented as
`.matchers as $m | .matchers = ($order | map($m[.]))`, not the more
obvious `.matchers = ($order | map(.matchers[.]))` — inside `map()`, `.`
is each `$order` element (a bare number), which has no `.matchers` field
of its own, so the direct form silently breaks; capturing the original
array into `$m` first sidesteps this.

All four of `add`/`edit`/`set-order`/`remove` set the series' own
`.dirty` marker (`bs::mark_series_dirty`) rather than implicitly
rebuilding — matching a rule change against every cached product can be
real work, so a human chooses when to pay for it via an explicit `series
rebuild`, which is what clears the marker again. `series edit
--item-key-format` (an actual change) sets the same marker, for the
unrelated reason of stale cover display names -- see "`item_key_format`
only names cover files" above. Surfaced as a `*` in `series list`, a line
in `series get`, and a warning in `series audit` (whose findings may be
stale until the next rebuild).

**`series rebuild`** — see "`series rebuild`" above for the full algorithm
(two passes — revalidate in place, then discover — and `--covers-only`).
No separate relink step needed afterward — classification already links
each item inline as it goes.

**`series audit`** (`bs::series_audit`) answers "what's incomplete in this
series?" purely from local metadata (no network access at all, and O(1)
regardless of series size for every finding kind — see "Performance
history" below). One JSON object per finding, sorted by item number and
rendered as a table:
- **`missing`**: an integer between the series' own observed min and max
  item index with no series-item at all.
- **`broken`**: a series-item with no actual image file on disk for its
  effective image key, or (for a product-backed one) whose linked product's
  own `cover_status` is `"failed"` (shown appended to the title).
- **`placeholder`**: a product-backed series-item whose linked product is
  still stuck at `cover_status: "placeholder"`.
- **`unsorted`**: a dot-keyed fallback series-item still awaiting a human
  to assign it a real item number (`product set-item`), which moves it to
  a real indexed key.
- **`ambiguous`**: a series-item whose own `matched.product_ids` has 2+
  entries and no `manual.product_id` picking a winner — `product_id` holds
  every currently-matching id, comma-separated. Resolved via `product
  exclude`/`product set-item` on all but the intended winner, then `series
  rebuild`. Read straight off the item file itself, in the same single
  batch read every other finding kind already uses — nothing to dry-run any
  more (see "Performance history" below for what this replaced).
- **`promoted`** (`--hide-promoted` to suppress): a series-item whose
  `manual.product_id` is set but isn't present in its own
  `matched.product_ids` — a human has pinned a product to this slot that
  doesn't (or no longer) naturally match it. Could be a deliberate
  promotion or a leftover from an earlier conflict resolution whose match
  set has since changed — not yet decided which, so shown by default.

Kept cheap regardless of series size: one images/ directory listing builds
a "has an image file" lookup, one `jq` call across every cached product
builds a product_id → `{cover_status, failure_reason}` lookup, one `jq`
call across every series-item file (now also pulling `matched.product_ids`/
`manual.product_id`) extracts every finding candidate — `ambiguous`/
`promoted` included — in a single pass, and the classification loop over
those rows is pure bash.

**A failed fetch attempt is recorded, not left untraced** — `bs::record_fetch_failure`
writes a minimal `products/<id>.json` (title, `cover_status: "failed"`,
`failure_reason`) for any of `bs::fetch_one_product`'s three failure points
instead of returning empty-handed, and still links category → product
(`bs::link_category_product`) even though the download itself failed — "we
found it here" is real regardless. Without this, a failed attempt would be
indistinguishable from an item nobody's looked at yet.

### Performance history (still relevant background, mechanism since changed)

Both `bs::series_audit` and `bs::series_relink` were, at different points,
rewritten from a per-candidate-subprocess design (one `jq` call per field
per row, plus a filesystem glob per row) that took *minutes* on a real
~2400-product series, down to a small, fixed number of subprocesses
regardless of series size — a directory listing instead of a glob per row,
one batch `jq` extraction instead of many. The v2 redesign changed *what*
each function reads (series-item files instead of scanning `products/*.json`
for now-removed fields), but kept this same "batch, not per-row" discipline
throughout — every new function added in v2 (`bs::classify_product`,
`bs::rebuild_series`, the audit passes) follows it too.

**`ambiguous` used to be the one exception** — its own dry-run pass
(re-running classification against *every* cached product, since nothing
about a conflict was ever recorded anywhere) was explicitly accepted as
"revisit only if it actually proves too slow in practice." It did: on a
real ~3500-product/90-category cache, a single `series audit` hadn't
finished after 3.5+ minutes. Root cause was two redundant per-candidate
costs, both now fixed: `bs::_resolve_series_match` was re-deriving the same
series-wide-constant matcher/`item_key_format` data from `meta.json` fresh
on every single call (~6 `jq` forks per candidate, mostly wasted — first
fixed by computing it once per pass and passing it in, `bs::_matcher_rows`;
`item_key_format` was later dropped from this path entirely, not just
hoisted, once storage keys stopped depending on it at all — see
"`item_key_format` only names cover files" above), and
`bs::categories_for_product` was linearly scanning every category directory
per product (~O(products × categories) — now one pass per category
directory instead, `bs::_all_categories_for_products`). Beyond that,
`ambiguous` itself stopped being a dry-run at all: conflicts are recorded
directly on the series-item as they're discovered (`matched.product_ids`,
see "Series matchers" above), so audit now reads them the same O(1) way as
every other finding kind.

**`series rebuild` regressed, then got fixed again, when `derived.title`
started being re-derived from the winning match instead of just copied
from the raw product title** (see "`item_key_format` only names cover
files" above's sibling fix — the title-cleanup one). Confirmed directly: a
real ~3400-item `perry-rhodan` rebuild went from 50m48s to 91m21s the
moment `bs::_recompute_item` started calling `bs::categories_for_product`
(a full per-category linear scan) and re-parsing `bs::_matcher_rows` for
every single winner, on top of the already-existing per-product cost in
the classify pass. Fixed the same way as `ambiguous` above — hoist the
already-computed `category_ids_for`/`matcher_rows` in
(`bs::rebuild_series` passes both down through `bs::_classify_product_-
into_series` into `bs::_recompute_item`, a `local -n` nameref binding for
the category map since it's a whole associative array, not a scalar) —
down to **25m48s**, faster than the original pre-title-fix baseline (this
measurement predates the two-pass redesign below — see there for the
current, further-reduced shape). A second real cost found and fixed in
the same pass: `bs::_all_categories_for_products` and every per-item
key/index derivation (`bs::_recompute_item`, `bs::_link_series_item`,
`bs::series_relink`, `bs::series_audit`) were forking `basename`/a helper
function's own subshell once per (category, product) pair or per item —
replaced with plain bash parameter expansion / an inlined regex match,
`^item-([0-9]+)$`, everywhere it runs inside a per-item loop (see
`bs::_item_storage_key`'s own doc comment).

**The three-pass `bs::rebuild_series` design itself (blind-clear, walk
every product, unconditionally re-sweep every pre-existing item a second
time) was then replaced with the current two-pass one** (see "`series
rebuild`" above) — not purely a performance fix, a genuine architectural
simplification: the old third pass only existed to compensate for the
first pass never actually validating anything (a blind
`.matched.product_ids = []` on every item, not a real "does this product
still belong here" check). An interim fix (having pass 2 mark which keys
it fully recomputes, so the old pass 3 could at least skip those) had
already cut the worst of the redundant-recompute cost, but the redesign
removes the redundant pass entirely, *and* lets pass 2 skip re-testing
every product pass 1 already confirmed is still correctly placed
(`settled_products`) — in steady state (nothing actually changed), this
can shrink pass 2's own workload from the *entire* product cache down to
just the products that were never previously accounted for at all.

**`resolutions`** (`bs::series_resolutions`) is a series' own list of
ImageMagick resize geometry strings, e.g. `700x1000!,300x300` — passed
straight to `convert -resize`, so the shop-standard `!` suffix (force
exact size, ignoring aspect ratio) works exactly as ImageMagick defines
it, alongside a plain `WxH` (fit within, preserving aspect ratio) or any
other geometry ImageMagick accepts. See "`covers` commands" below for how
`covers resize` uses this list.

`series remove` (`bs::series_remove`) now just deletes the series' own
whole directory (`series/<id>/`) — definition, every item file, and
`covers/` (both `original/` and every resize spec) all live under it, so
nothing separate needs cleaning up. Canonical `products/`/`images/` data is
never touched, since it's real scraped fact, not part of the series
mapping.

## `product` commands

`product exclude <product_id> --series <id>`, `product set-item
<product_id> --series <id> --item <n>`, `product unset <product_id>
--series <id>`. Thin CRUD over `products/<id>.json`'s own `overrides`
object (`bs::set_product_override`/`bs::unset_product_override`,
`beam_shop_covers.sh`) — a surgical read-merge-write on just that one key.
**All three apply immediately** — each calls `bs::apply_product_override`
right after writing the override (see "Product overrides apply
immediately" above), which reclassifies and relinks that one product in
that one series on the spot. No separate "now make it take effect" step,
and no `series rebuild` needed for a single product's own override — only
for a *matcher* change, which can affect many products at once.

## `covers` commands

`covers fetch (<category_id...> | --series <id>... | --all-series)
[--all-children] [--limit n] [--force] [--resize] [--batch]`, `covers
resize [series_id...] [--width] [--height] [--format] [--batch]`, `covers
import <image_file> (--product <product_id> --category <category_id>
--title <title> | --series <series_id> --item <item_number> [--title
<title>]) [--force]`.

`fetch`'s core loop is `bs::fetch_category`: paginate a category (assumed
newest-first, see "Site quirks" above for the caveat this doesn't
universally hold), stop at the first already-`final` product unless
`--force` *or* this category has never been walked all the way to the end
before (see "Resumable backfills" below), fetch/classify/download each new
one via `bs::fetch_one_product` → `bs::finalize_product`
(`bs::link_category_product` + `bs::classify_product`, global — no
series-scoped classification any more, and each classified product's cover
gets linked as part of that same call — see "Cover linking is automatic"
above). No relink step needed afterward at all — `--resize` (below) still
runs across every defined series, since classification is global and any
category fetched could in principle have contributed to any series, but
cover-linking itself is already done by the time the fetch loop finishes.

`--series <id>` (repeatable, `bs::series_category_ids`) expands to a
series' own member category ids (still purely *informative* — "which
categories to proactively crawl," nothing more; a category not in this
list can still contribute to the series via `series rebuild`/a future
fetch of that category directly). `--all-series` expands to every defined
series. `--all-children` is the lower-level, series-agnostic bulk-backfill
tool, expanding each given category id to its direct children first.

**`import`**'s target is resolved one of two ways:
- **`--product`** (`--category`/`--title` given only as needed) — the
  general case, works for any finding, including a `missing` one you know
  the real shop product id for. For an already-cached product,
  `--category`/`--title` are both optional: an existing `products/<id>.json`
  already knows its own title, and its own category link (if it has
  one — a product can genuinely have none on record at all, see "Category →
  product linking" above) is looked up the same way `--series`/`--item`
  does below. Only for a genuinely brand-new product id, with no existing
  record at all, does `--title` become required (nothing to fall back on)
  — `--category` stays optional even then.
- **`--series`/`--item`** (`bs::find_series_item` — now a **direct
  file lookup**: compute the fixed storage key (`bs::_item_storage_key`,
  no longer anything to do with `item_key_format`), read that one
  `series/<id>/<key>.json`, done. Fixes a real, confirmed O(series size)
  performance bug this used to have — measured at 60-80+ seconds per lookup
  against a real ~2500-product cache, from grep-prefiltering then scanning
  every cached product for now-removed `series_id`/`item_number` fields.):
  if it resolves (a `broken` finding — the product was fetched successfully
  at some point, only its image is gone), works exactly like the
  `--product` form with everything auto-filled in, and any `--title` given
  alongside is ignored. **If nothing resolves at all** (a genuine `missing`
  gap — the shop never actually listed this issue, e.g. category 70/71's
  own confirmed out-of-print gaps, or a cover from some other archive
  entirely) — `--title` becomes required, and this becomes a **fully
  manual** entry: no shop product id involved at all, see "The translation
  layer" above.

Refuses to overwrite an existing genuine cover (product-backed or manual)
unless `--force` — but only when there's something real to protect; a
`broken`/`missing`-turned-manual slot with nothing behind it proceeds
without `--force`.

### Resumable backfills

The early-exit optimization above ("stop at the first already-`final`
product, since releases are numerically monotonic newest-first" — see
"Site quirks" above for where this assumption can actually fail) is only
sound once a category has been walked all the way to its true end at
least one time — a real bug, reported and fixed directly against this
project: an interrupted large backfill (killed partway through, having
already cached the newest N items) could never be resumed correctly,
because the very next run's page 1 is entirely already-cached items, so
the naive early-exit fired on the *first* item it looked at, and the
older, never-fetched tail of the category silently never got checked
again.

Fixed via `bs::category_synced_marker` (`categories/<id>/products/.synced`,
plain existence, no content/TTL): the early-exit is only trusted once that
marker exists. Until it does, an already-cached item is *skipped* (never
re-fetched) rather than treated as proof there's nothing left further
down. The marker is only written when a run reaches the true end of
pagination *without* `--limit` cutting it short. `--force` is unaffected
either way — it already re-fetches regardless of cache state, and doesn't
touch the marker. Same reasoning applies to a category with any known
`failed` record — `bs::category_has_failures` (now reading the
`categories/<id>/products/` symlink folder, see above) makes such a
category behave as not-yet-synced even if its marker exists, so a stuck
failure always gets retried by a routine run.

`resize` (`bs::resize_series`, `beam_shop_resize.sh`) always reads a
series' `covers/original/` folder and never touches originals or that
folder itself. Two modes:
- **No `--width`/`--height` override, series has its own `resolutions`**:
  one `convert -resize <spec>` pass per resolution string, raw geometry
  passed straight through — into `series/<id>/covers/<spec>/`, one
  subfolder per spec.
- **Otherwise** (an explicit `--width`/`--height` always wins over a
  series' own `resolutions`; a series with none falls back here too): pad
  to exactly width x height (never cropping content) on a white
  background, written into `series/<id>/covers/<width>x<height>/`,
  defaulting width/height/format from their own config keys when not
  given on the command line.

`covers import`'s path-completion note carries over unchanged: bashly
itself never emits `compopt -o filenames` for a `completions: [<file>]`
token, fixed for this (and every) project in this repo by the shared
`bash-completion.d/.template.sh.in` — see its own header comment and
`~/.claude/rules/bashly.md`.

## `config` commands

`config list` (default), `config get/set/unset <key>`. Same shape as
`bashly/goodreads`' own `config` group. Keys: `curl_bin`,
`http_request_delay_min`/`_max`, `http_retry_delays`, `discovery_root_url`,
`category_cache_ttl`, `image_width`/`_height`/`_format`,
`known_placeholder_hashes`.

## Open design questions

- **The `bs::products_dir`/`bs::product_file`/`bs::series_dir`/`bs::category_file`-
  style directory-helper functions are far more expensive per call than
  they look, and this whole file calls them repeatedly inside per-item/
  per-product loops.** Discovered directly while chasing a real
  regression: `bs::rebuild_series`'s new revalidate-in-place pass (see
  "`series rebuild`" above) called `bs::product_file` once per matched
  product to check for/read its title, which measured *slower* overall
  than the previous three-pass design despite doing genuinely less work
  on paper. Root cause: `bs::product_file` calls `bs::products_dir`,
  which calls `bs::data_dir` — each of those is its own subshell fork for
  the nested command substitution, *and* each runs its own `mkdir -p` (an
  external process, not a builtin) even though the directory obviously
  already exists after the first call in a run. One `bs::product_file`
  call is closer to 5 process forks than 1. Fixed *for this one new loop*
  by hoisting `bs::products_dir`'s result once and using plain string
  interpolation (`"${products_dir}/${pid}.json"`) instead — but the same
  pattern (calling a directory-helper function repeatedly inside a loop
  instead of hoisting its result once outside it) likely exists elsewhere
  in this file and hasn't been swept for systematically. Worth a
  dedicated pass later: audit every per-item/per-product loop in
  `beam_shop_series.sh`/`beam_shop_covers.sh`/`beam_shop_categories.sh`
  for a directory-helper call that could be hoisted, and/or make
  `bs::data_dir`/`bs::products_dir`/etc. themselves cheaper (e.g. memoize
  the `mkdir -p` so it only actually runs once per process).
- **Steps 1 and 2 of `series rebuild` could each collapse their several
  sequential `jq` calls per item/product into one `jq` program per
  item/product.** Right now, e.g. `bs::_recompute_item` reads a target
  file's `manual`/`matched.product_ids` via several separate `jq -c`/`jq
  -r` invocations (each one re-opening and re-parsing the same file),
  then writes the result via yet another. Every one of those is a fork +
  process-startup cost this whole redesign has otherwise been chasing
  down elsewhere. The idea (not done, deliberately deferred — noted here
  for later review): read a file's raw content once via plain bash (`$(<
  "$file")`, no `jq` involved at all), pass that content plus whatever
  else is needed (a product's title, category ids, matcher rows) into a
  *single* `jq` program invocation as `--argjson`/`--arg` inputs, and have
  that one program do every field extraction *and* produce the final
  output to write, in one execution instead of several. Same idea applies
  to pass 1's per-product-in-`matched.product_ids` revalidation loop and
  pass 2's per-product classify path (`bs::_resolve_series_match`) —
  each currently spends more than one `jq` fork per candidate where one
  well-written program could do the whole thing. **Confirmed directly
  which pass this actually matters for**: temporarily instrumenting
  `bs::rebuild_series` with a timestamp before/after each pass, on the
  real ~3400-item/~3550-product `perry-rhodan` cache in steady state
  (nothing actually changed since the last rebuild), gave pass 1
  (revalidate in place) 42m22s and pass 2 (discovery, after the
  `settled_products` skip) only 17s. Two rounds of hoisting
  `bs::product_file` calls (see the directory-helper TODO above) barely
  moved this number (48m38s -> 43m46s -> 43m8s total) — confirming the
  dominant cost genuinely is `jq`/subprocess *count* inside pass 1's
  per-item loop, not any one specific expensive call within it. This is
  the concrete evidence that the jq-consolidation idea above is where the
  real remaining win is, not further one-off hoisting.
- **`series rebuild`'s pass 2 (discovery) should eventually be shared
  across series, not repeated per series.** `series_rebuild_command.sh`
  calls `bs::rebuild_series` once per requested series id (or once per
  *every* defined series, if none are given) — each call does its own
  independent pass 2, walking the *entire* product cache and testing each
  product against just that one series' own matcher rules. With only one
  real series (`perry-rhodan`) today this is moot, but with several
  series rebuilt together (a bare `series rebuild` with none given, or
  several ids at once), the product cache gets walked once per series
  requested — genuinely redundant I/O and `jq` forks for exactly the same
  files. The fix (not done, deliberately deferred — noted here for later
  review): restructure so a multi-series rebuild reads every requested
  series' own `matcher_rows`/`category_ids_for`/`item_key_format` up
  front (each already read once per series today, cheap), runs pass 1
  (revalidate in place) per series as now — it's driven by each series'
  own existing items, not the shared product cache, so there's nothing to
  share there — but walks the product cache exactly **once** for pass 2,
  testing each product against every requested series' rules in that same
  single sweep, rather than once per series.
- **Migration of the real v1 data is not done.** `~/.beam-shop.v1-backup`
  holds the full pre-redesign cache (~2500 products, real fetched covers).
  Whether to write a real migration (rebuilding category→product links from
  the old `category_id` field, series-items from the old `series_id`/
  `item_number`) or just re-fetch/re-import from the backup and the
  separately-discovered local archive
  (`/mnt/media/media/incoming/ebooks/Perry Rhodan - Hefte 0001-3187/beam-shop-img/`,
  which already has every cover 1-3399) is undecided.
- **Real, non-regex title-cleanup rules are not built** — only the hook
  (`bs::clean_series_item_title`) exists, currently an identity function.
  Independent of series-membership matching by design; to be designed later
  once it's clearer what actually needs cleaning up (stripping a leading
  "Series Title #1234: " prefix is already free via a matcher's own
  `<title>` capture — this is about cleanups a regex genuinely can't do,
  e.g. case conversion).
- **Placeholder covers are no longer excluded from the human-browsable view**
  the way v1 excluded them from `series relink` — see "Placeholder-cover
  detection" above. `series audit` still flags them; nothing hides them from
  `covers/original/`/resize output any more. Not yet decided whether that's
  worth restoring, and if so, where it should live (classification itself,
  or relink specifically).
- `matchers[].pattern` relies on the runtime's `jq` having Oniguruma regex
  support (near-universal, not defensively checked).
- No `--all-children` recursion depth limit — fine for Perry Rhodan (one
  level of cycles), would need thought if a future series nested more than
  one level deep under its own category.
- Cover images beyond a "shared or unique hash" test aren't otherwise
  validated (e.g. no check that a "final" cover is actually a plausible
  book-cover aspect ratio) — the two placeholder-detection mechanisms above
  are the only defense against a bad/generic image being treated as real.
- No command yet to remove a cached product or category individually (only
  a whole series, via `series remove`) — not needed so far, but would follow
  the same `remove`/`--all` shape if it becomes useful.
- **Categories have a human-readable slug alongside their numeric id, with
  no id<->slug mapping exposed anywhere.** A cycle category's own `url`
  already carries this slug as its trailing path segment (e.g. `1159` ↔
  `pegasos-3350-3399`, from
  `.../perry-rhodan-erstauflage/pegasos-3350-3399/`), and a root-level
  genre's own `category_id` already *is* its slug (`science-fiction`, not a
  number) — so the raw data to build this from already exists in every
  `meta.json`, nothing new needs to be fetched. Wanted:
  - A lookup either direction (slug -> id, id -> slug), presumably derived
    from `meta.json`'s own `url`/`name` rather than stored redundantly, so
    it can't drift out of sync.
  - Accepting a slug anywhere a category id is currently accepted on the
    CLI (`categories get`, `series create --categories`, etc.).
  - Shell completion for category ids/slugs, ideally **traversible through
    the `categories/<id>/<child_id>` symlink structure itself** (see
    "Every category is its own folder" above) — completing on nothing
    lists root categories (`categories/.root/`'s own children), completing
    on one of those lists *its* children, and so on down the tree, mirroring
    `categories list`'s own plain-drilldown navigation but at the shell
    level instead of one `categories list` call at a time.
- **A category's own reserved entries (`meta.json`, `products/`, `.synced`)
  share a namespace with its child-category symlinks, with no collision
  guard.** Every child is linked in as `categories/<id>/<child_id>` (a
  plain relative symlink, see "Every category is its own folder" above),
  sitting directly alongside that same folder's own fixed entries. A
  category whose id/slug happened to literally be `products` (or
  `meta.json`, or `.synced`) would have its own child symlink either
  silently overwrite/corrupt the parent's real `products/`
  results-symlink-folder, or (since `ln -sf` on an existing real
  directory places the link *inside* it instead of replacing it) end up
  linked in the wrong place entirely -- and either way, `bs::crawl_children`
  has no check today that would catch or refuse this. Not yet seen in
  real data (shop-controlled slugs, not adversarial), but there's no
  actual guard against it either. Needs either a reserved-name check in
  `bs::crawl_children` (refuse/warn on a colliding child id) or a
  namespacing change (e.g. child symlinks living in their own subfolder
  instead of sharing the category's top-level directory) -- the tradeoffs
  of each aren't worked out yet.
- **No way to search cached products by (partial) title.** Wanted for
  exactly the case discussed above: a product that's fully cached (real
  title, real cover) but isn't linked into any series-item at all, because
  a typo in its title broke every matcher's `test()` entirely (not the
  same as `unsorted` -- that's a matcher matching *without* a usable
  `<index>`; a title that fails every matcher outright leaves *zero*
  trace in `series/<id>/`, so `series audit`'s `missing` finding can't
  tell "the shop never published this issue" apart from "a real,
  already-fetched product exists but got silently orphaned from
  classification" -- both just show up as the same missing integer, no
  product id attached). Today the only way to check is a manual `grep`/`jq`
  scan through `products/*.json` by hand. A simple `products search
  <text>` (or similar) that greps cached titles and prints
  id/title/cover_status/which-series-if-any would make this a one-liner
  instead, and would also be generally useful for spot-checking
  classification independent of any particular gap investigation.
- **`manual.product_id` (picks a canonical winner for a series-item, even
  one absent from `matched.product_ids`) has no command that sets it.**
  The data model and resolution logic (`bs::_recompute_item`) already
  handle it correctly either way — this is deliberately scoped out until
  it's actually designed (a `product promote`-shaped command? an extra
  mode of `product set-item`? something else?). Relatedly, `series
  audit`'s `promoted` finding (a `manual.product_id` absent from its own
  `matched.product_ids`) is shown by default because it's genuinely
  unclear yet whether that state is normally a deliberate promotion or a
  leftover from an earlier conflict resolution whose match set has since
  changed -- revisit once the promotion feature itself is designed.
