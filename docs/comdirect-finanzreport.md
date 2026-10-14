# comdirect-finanzreport

Context for picking up work on `plain/comdirect-finanzreport.sh` -- mainly: what to
do when the bank changes its PDF format. Contains no personal data; keep it that
way (no names, places, merchants, account numbers, amounts).

## What it does

Converts comdirect "Finanzreport" PDFs (monthly statements: accounts,
transactions, depot, tax data, interest rates) to JSON via
`pdftotext -layout` + an embedded Perl parser (`PARSER` heredoc at the end of
the script) + `jq`.

```
comdirect-finanzreport [-o|--output TEMPLATE] FILE.pdf...
comdirect-finanzreport skeleton [--strict] FILE.pdf
```

- Default: pretty-printed JSON to stdout, several reports separated by a newline
  (a JSON stream; use `jq -s` to collect).
- `-o`: jq string-interpolation template over the report, e.g.
  `-o 'out/\(.year)-\(.number).json'`. Errors if two reports map to one path.
- `Jahressteuerbescheinigung_*` PDFs are out of scope (file names that do not
  match `Finanzreport_Nr.*` are rejected).
- Source PDFs: `.local/finanzen/Finanzreport_*.pdf` (gitignored, 214 files,
  2008 -> present at time of writing).

## Privacy rules (org policy: classify data before it enters Claude)

The PDFs are real financial data. **Never read their text into a session
directly.** Inspect layouts with `skeleton`, which prints the layout with
masked content:

- default (blacklist): digits, tokens with digits, mail/URL-ish tokens and any
  word in `.local/comdirect-sensitive-words.txt` are masked (`9`/`x`), also when
  wrapped over lines of a table cell. **Fail-open**: free text (merchants,
  counterparties, places) stays readable unless listed -- this already leaked
  sensitive data once. Prefer `--strict` (whitelist `SKELETON_KEYWORDS` in the
  script; everything else becomes `x`) for investigation.
- To debug parser output, look at aggregates (counts, warnings with digits
  stripped) or mask `raw_lines` through `gsub("[0-9]";"9")|gsub("\\p{L}";"x")`,
  never print real transactions.
- Derived data (JSON, skeletons) belongs in the session scratchpad, deleted
  afterwards -- not in the repo.

## File name eras

`Finanzreport_Nr.005_vom_03.06.2014_HASH.pdf`, `Finanzreport_Nr.01_vom_...`,
`Finanzreport_Nr._01_per_01.02.2018_HASH.pdf` (all handled by `source_meta`).

- `number` = counting number within the year (1-12).
- `year` = the year the number counts in: a report dated in early January with
  number >= 12 belongs to the previous year (`Nr. 12 per 01.01.2017` -> 2016).
  Needed so `year`+`number` is unique (all 214 files are).
- `date` = the report's own "per" date from the text; the file name's date can
  be 1-2 days off (kept as `source.file_date`).

## Layout eras seen in the PDF text (reports are monthly, dated ~1st of month)

| `layout` | years | notes |
|---|---|---|
| `soll-haben` | 2008-2009 | table header `Buchungstag / Valuta / Soll / Haben`; each tx on ONE line: `type  booking  valuta  amount`, description on indented lines below; sometimes the type is missing (line = two dates + amount); overview has no IBAN |
| `vorgang` | 2010-2013 | header `Buchungstag Vorgang Auftraggeber / Empfänger Buchungstext Ausgang` + second header line `Valuta ... Eingang`; booking date on the first tx line, valuta date on a later line; no IBANs in overview |
| `vorgang-iban` | 2014- | same table; overview lists IBAN, later two balance columns (`Saldo in Kontowährung`, `Saldo in EUR`); foreign-currency accounts (`Währungsanlagekonto (XXX)`); depot from ~2012; `Zinsübersicht`, `Steuerliche Daten`; from ~2021 depot rows have WKN/Verwahrart on the row, an extra note line (e.g. custody country) before the name, and `Kontoübersicht` heading |

Depot position layouts (all handled, in `# --- depot` of the parser):
1. WKN only, name on the next line (older);
2. December/year-end variant: heading differs, quantity has a unit, FX rate
   line (`rate EUR/USD`) and `WKN / Verwahrart` AFTER the name lines;
3. newer: `WKN / Verwahrart` on the row, notes before the name (last line = name).

## Parser design (read this before changing anything)

Line-oriented state machine over the footer-stripped text:

1. **Footer filter** (`@L = grep ...`): drops page footer lines (`comdirect – eine
   Marke...`, `Finanzreport Nr. N per ... - Seite N`, `Kundennummer`, ...). The
   bank repeats table headers per page, so tx tables continue across pages.
2. **Overview**: from `Ihre aktuellen Salden` to `Gesamtsaldo`; rows = name,
   optional IBAN, 1-2 amounts (native currency, EUR).
3. **Sections**: heading (first table cell without digits, remembered only while
   *outside* a section) -> `Alter Saldo` opens, `Neuer Saldo` closes. Overdraft
   limit from `Dispositionskredit N EUR` on the heading line.
4. **Transactions**: right-aligned amount column. The right edge is taken from
   the table header line **of the current page** (it shifts per page!) with a
   +-4 column tolerance; amounts elsewhere in the text column are ignored that
   way. Booking-date line starts a tx; the next date-leading line is its
   valuta line if it has none yet (`soll-haben`: one-line rows instead).
   Columns (type/reference | counterparty | text) are split by the header word
   positions (`Auftraggeber`, `Buchungstext`), with 2-column tolerance and
   per-line column snapshots, since a tx can straddle a page break. Text that
   overflows into the next column is not repaired (`raw_lines` keep the full
   lines). Details (End-to-End-Ref, Mandatsref, Gläubiger-ID, card, WKN/ISIN) are
   regexed out of the text lines.
5. **Depot**, **tax data**, **interest rates**, **IBAN/BIC table** at the end.
6. **Validation** -> `warnings[]` (never fatal): `opening + sum(tx) == closing`
   per account (0.005), overview balance == closing balance, depot positions sum
   == `Gesamtkurswert`, `Gesamtwert` == overview depot value, report number and
   header present. **A clean run has an empty `warnings` for every report** --
   this is the regression test.

Gotchas already hit:
- `mawk` (the default awk here) is byte-based: breaks umlaut columns and
  case-folding -> hence Perl.
- Don't pass big JSON via `jq --argjson` ("Argument list too long"); the script
  feeds base + parsed content through stdin with `jq -s`.
- `Umsätze (xxx) ... Buchungstag ...` headers can have text in front of
  `Buchungstag`; match it anywhere in the line.
- Strict skeletons mask almost every word; use them for layout shape only.

## Output schema (top level)

`number`, `year`, `date`, `period{from,to}` (from opening/closing balance
dates), `source{file,hash,file_date}`, `layout`, `accounts[]`, `depot{positions[],
totals}`, `tax_data[]`, `interest_rates[]`, `warnings[]`, optionally
`total_eur`. Account: `name`, `type` (giro/tagesgeld/fremdwaehrung/depot/
verrechnung/sonstige), `currency`, `iban`, `bic`, `overdraft_limit_eur`,
`opening_balance`/`closing_balance{date,amount}`, `balance_eur`,
`eur_equivalent{value,implied_rate_eur_per_unit}` (non-EUR accounts),
`transactions[]` {`booking_date`, `value_date`, `amount` (signed), `type`,
`reference`, `counterparty{name,iban_bic}`, `text_lines`, `details`,
`raw_lines`}. Amounts are numbers (German format `1.234,56` converted).

## Workflow when the format changes

1. Run over everything and look at warnings by category only:
   `comdirect-finanzreport .local/finanzen/Finanzreport_*.pdf | jq -r '.warnings[]'`
   plus per-file `layout` / counts. Find the first affected file (usually a new
   year or the newest reports).
2. Look at the layout with `comdirect-finanzreport skeleton --strict FILE.pdf`
   (see privacy rules); compare with a file from the previous era.
3. Prefer small, tolerant changes in the matching era branch of the embedded
   parser over a new parser. Typical breakages: renamed headings (overview,
   `Alter/Neuer Saldo`), shifted columns (check the amount edge tolerance), new
   depot row shape, new account types (`acct_for` type mapping).
4. Re-run on all 214 files; all `warnings` must stay empty and transaction /
   position counts must not drop for old files.
5. `shellcheck plain/comdirect-finanzreport.sh` (`make lint-plain` also checks the
   unrelated `desktopctl.sh`, which has pre-existing findings).

## Status when written (2026-10-14)

214 reports, 9501 transactions, 1093 depot positions; zero warnings. Not yet
done / ideas: drop `raw_lines` if output size matters; rejoin words wrapped
mid-token in `text_lines`; Jahressteuerbescheinigung parsing; unit tests with
synthetic PDFs (none exist because real PDFs cannot be committed).
