#!/usr/bin/env bash
#
# Convert comdirect "Finanzreport" PDFs into structured JSON.
#
# Usage:
#   comdirect-finanzreport [-o|--output TEMPLATE] FILE.pdf...
#   comdirect-finanzreport skeleton [--strict] FILE.pdf
#
# Without --output, each report is printed to stdout as pretty-printed JSON,
# multiple reports separated by a newline (a plain JSON stream for jq).
#
# --output TEMPLATE is a jq string-interpolation template evaluated against
# the respective report, e.g. --output 'report-\(.year)-\(.number).json'; the
# report is then written to that path instead of stdout.
#
# skeleton prints the `pdftotext -layout` text for layout inspection. Default
# (blacklist): digits, tokens containing digits, mail/URL-like tokens and any
# word listed in .local/comdirect-sensitive-words.txt in this repo (one per line,
# case-insensitive substring, e.g. your own name/street/employer, also when
# wrapped over lines of a table cell) are masked
# with 9/x; all other words stay readable. This is fail-open: free text such as
# counterparty names is NOT masked unless listed -- review before sharing.
# --strict inverts it: only a small keyword whitelist stays readable.

set -euo pipefail

OUTPUT_TEMPLATE=""
# .local/ in this repo (gitignored), found via the real path of this script, as
# it usually runs through the symlink in bin/.
MASK_WORDS_FILE="$(dirname -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")")/.local/comdirect-sensitive-words.txt"
SKELETON_KEYWORDS="Konto Kontonummer IBAN BIC Saldo Kontostand Alter Neuer Zinssatz Zins Zinsen
Depot Wertpapier Wertpapiere Kurs Währung Gesamt Summe Stück Nominal Bestand Wert Buchung
Buchungstag Valuta Vorgang Umsatz Umsätze Finanzreport Nr per vom EUR USD Girokonto
Tagesgeld Verrechnungskonto Festgeld Kreditkarte Dispo Kreditlinie Datum Betrag Soll Haben
WKN ISIN Einstandskurs Performance Veränderung Differenz Seite Gesamtvermögen
Währungsanlagekonto PLUS-Konto JPY SEK Kontowährung Kundennummer Buchungstext
Auftraggeber Empfänger
Kurswert Stückzinsen Kaufwert Gewinn Verlust Verwahrart Bezeichnung Gesamtwert
Gesamtkurswert"

main() {
	check_dependencies || exit 1

	if [ "${1:-}" = skeleton ]; then
		shift
		if [ "${#}" -lt 1 ] || [ "${#}" -gt 2 ]; then
			print_usage
			exit 1
		fi
		skeleton "${@}"
		return
	fi

	parse_args "${@}"
	convert_all
}

print_usage() {
	echo "Usage: ${0##*/} [-o|--output TEMPLATE] FILE.pdf..." >&2
	echo "       ${0##*/} skeleton [--strict] FILE.pdf" >&2
}

# Sets OUTPUT_TEMPLATE and FILES.
parse_args() {
	FILES=()
	while [ "${#}" -gt 0 ]; do
		case "${1}" in
			-o|--output)
				[ "${#}" -ge 2 ] || { echo "Error: ${1} needs an argument." >&2; exit 1; }
				OUTPUT_TEMPLATE="${2}"
				shift 2
				;;
			--output=*)
				OUTPUT_TEMPLATE="${1#--output=}"
				shift
				;;
			-h|--help)
				print_usage
				exit 0
				;;
			--)
				shift
				FILES+=("${@}")
				break
				;;
			-*)
				echo "Error: unknown option '${1}'." >&2
				print_usage
				exit 1
				;;
			*)
				FILES+=("${1}")
				shift
				;;
		esac
	done

	if [ "${#FILES[@]}" -eq 0 ]; then
		print_usage
		exit 1
	fi
}

check_dependencies() {
	local -A install_hints=(
		[pdftotext]="Install via 'apt install poppler-utils' (Debian/Ubuntu)"
		[perl]="Part of every Debian/Ubuntu base install (perl-base)"
		[jq]="Install via 'apt install jq' (Debian/Ubuntu)"
	)

	local cmd missing=()
	for cmd in "${!install_hints[@]}"; do
		require "${cmd}" "${install_hints[${cmd}]}" || missing+=("${cmd}")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Missing executables: ${missing[*]}" >&2
		return 1
	fi
}

require() {
	local cmd="${1}" hint="${2}"

	command -v "${cmd}" >/dev/null 2>&1 && return 0

	echo "Error: '${cmd}' is required but not installed." >&2
	[ -z "${hint}" ] || echo "${hint}" >&2
	return 1
}

convert_all() {
	local file json target failed=0 first=1
	local -A written=()

	for file in "${FILES[@]}"; do
		if ! json="$(convert_file "${file}")"; then
			echo "Error: could not convert '${file}'." >&2
			failed=1
			continue
		fi

		if [ -z "${OUTPUT_TEMPLATE}" ]; then
			[ "${first}" -eq 1 ] || echo
			first=0
			printf '%s\n' "${json}"
			continue
		fi

		if ! target="$(resolve_output_path "${json}")"; then
			echo "Error: bad --output template for '${file}'." >&2
			failed=1
			continue
		fi
		if [ -n "${written[${target}]:-}" ]; then
			echo "Error: '${file}' resolves to '${target}', already written from '${written[${target}]}'." >&2
			failed=1
			continue
		fi
		written[${target}]="${file}"

		mkdir -p "$(dirname -- "${target}")"
		printf '%s\n' "${json}" > "${target}"
	done

	return "${failed}"
}

# Evaluates OUTPUT_TEMPLATE as a jq string against the report JSON in ${1}.
resolve_output_path() {
	local path
	path="$(jq -r "\"${OUTPUT_TEMPLATE}\"" <<<"${1}")" || return 1
	[ -n "${path}" ] && [ "${path}" != null ] || return 1
	printf '%s\n' "${path}"
}

# Prints the report JSON for the PDF in ${1}.
convert_file() {
	local file="${1}" base content

	[ -r "${file}" ] || { echo "Error: cannot read '${file}'." >&2; return 1; }
	base="$(source_meta "${file}")" || return 1
	content="$(pdftotext -layout "${file}" - | perl -CS -e "${PARSER}")" || return 1

	# `date` is the report's own "per" date; the file name's date can be a day
	# or two off (download date). The numbers must agree. Both documents go
	# in via stdin (-s): the content is too big for --argjson.
	printf '%s\n%s\n' "${base}" "${content}" | jq -s '
		.[0] as $base
		| .[1] as $content
		| ($base + ($content | del(.header)))
		| .source.file_date = $base.date
		| .date = ($content.header.date // $base.date)
		| .warnings += (
			if $content.header == null then ["no Finanzreport header (Nr. N per DATE) found"]
			elif $content.header.number != $base.number then ["report number differs from the file name"]
			else [] end)
		'
}

# Prints the filename-derived part of the report as JSON. Handles the
# filename eras 'Nr.005_vom_DD.MM.YYYY_HASH.pdf' and 'Nr._01_per_DD.MM.YYYY_HASH.pdf'.
source_meta() {
	local name
	name="$(basename -- "${1}")"

	local re='^Finanzreport_Nr\._?([0-9]+)_(vom|per)_([0-9]{2})\.([0-9]{2})\.([0-9]{4})_([0-9A-Fa-f]+)\.pdf$'
	if [[ ! "${name}" =~ ${re} ]]; then
		echo "Error: unrecognised file name '${name}'." >&2
		return 1
	fi

	# A report dated in early January closes the previous year's last report
	# (e.g. 'Nr. 12 per 01.01.2017' belongs to 2016), so `year` is the year
	# the number counts in, not necessarily the year of the date.
	local number="$((10#${BASH_REMATCH[1]}))" year="$((10#${BASH_REMATCH[5]}))"
	if [ "${BASH_REMATCH[4]}" = 01 ] && [ "${number}" -ge 12 ]; then
		year="$((year - 1))"
	fi

	jq -n \
		--arg file "${name}" \
		--argjson number "${number}" \
		--arg date "${BASH_REMATCH[5]}-${BASH_REMATCH[4]}-${BASH_REMATCH[3]}" \
		--argjson year "${year}" \
		--arg hash "${BASH_REMATCH[6]}" \
		'{number: $number, year: $year, date: $date,
		  source: {file: $file, hash: $hash}}'
}

skeleton() {
	local strict=0
	if [ "${1:-}" = --strict ]; then
		strict=1
		shift
	fi
	local file="${1}"
	[ -r "${file}" ] || { echo "Error: cannot read '${file}'." >&2; return 1; }

	local mask_words=""
	[ ! -r "${MASK_WORDS_FILE}" ] || mask_words="$(grep -v '^[[:space:]]*\(#\|$\)' "${MASK_WORDS_FILE}" || true)"

	# Perl rather than awk: needs UTF-8 aware columns/case-folding (mawk is
	# byte-based) to match words wrapped across lines of a table cell.
	pdftotext -layout "${file}" - |
		SK_STRICT="${strict}" SK_KEYWORDS="${SKELETON_KEYWORDS}" SK_MASKWORDS="${mask_words}" \
		perl -CSD -MEncode -e '
			use strict; use warnings; use utf8;
			my $strict = $ENV{SK_STRICT};
			my %keep = map { lc($_) => 1 } split /\s+/, decode("UTF-8", $ENV{SK_KEYWORDS});
			my @mw = grep { length } map { lc } split /\n/, decode("UTF-8", $ENV{SK_MASKWORDS});

			sub mask { my $t = shift; $t =~ s/[0-9]/9/g; $t =~ s/\p{L}/x/g; return $t; }

			# Blacklist: digits (amounts, dates, numbers, IBANs), mixed
			# alphanumerics, mail/URL-ish tokens, user-listed words.
			sub sensitive {
				my $t = shift;
				return 1 if $t =~ /[0-9@]/ || $t =~ m{://} || $t =~ /^www\./i;
				my $lt = lc $t;
				for my $w (@mw) { return 1 if index($lt, $w) >= 0 }
				return 0;
			}

			my @lines;
			while (my $line = <STDIN>) {
				chomp $line;
				my @toks;
				my $end = 0;
				while ($line =~ /(\s*)(\S+)/g) {
					my ($gap, $txt, $col) = ($1, $2, $-[2]);
					# A table cell starts after a gap of 2+ blanks.
					push @toks, { gap => $gap, txt => $txt, col => $col,
					              seg => (!@toks || length($gap) >= 2) ? 1 : 0, mask => 0 };
					$end = pos($line);
				}
				push @lines, { t => \@toks, tail => substr($line, $end) };
			}

			for my $ln (@lines) {
				for my $tk (@{ $ln->{t} }) {
					if ($strict) {
						(my $bare = $tk->{txt}) =~ s/[^\p{L}-]//g;
						$tk->{mask} = (!$keep{lc $bare} || $tk->{txt} =~ /[0-9]/) ? 1 : 0;
					} else {
						$tk->{mask} = sensitive($tk->{txt});
					}
				}
			}

			# A listed word wrapped over several lines of one cell ("Mül-" /
			# "ler") matches on no single line: join the last token of a
			# cell line with the first token of the cell line below it (same
			# left column, up to 4 lines) and mask all pieces on a hit that
			# spans the line break.
			if (!$strict && @mw) {
				for my $l (0 .. $#lines) {
					my $r = $lines[$l]{t};
					for my $i (0 .. $#$r) {
						next unless $i == $#$r || $r->[$i + 1]{seg};
						my $s = $i;
						$s-- until $r->[$s]{seg};
						my $scol = $r->[$s]{col};
						my $acc = lc $r->[$i]{txt};
						my @parts = ($r->[$i]);
						for my $d (1 .. 4) {
							last if $l + $d > $#lines;
							my $r2 = $lines[$l + $d]{t};
							my ($j) = grep { $r2->[$_]{seg} && $r2->[$_]{col} == $scol } 0 .. $#$r2;
							last unless defined $j;
							(my $prev = $acc) =~ s/-$//;
							my $cand = $prev . lc $r2->[$j]{txt};
							push @parts, $r2->[$j];
							my $hit = 0;
							for my $w (@mw) {
								my $o = 0;
								while (($o = index($cand, $w, $o)) >= 0) {
									$hit = 1 if $o < length($prev) && $o + length($w) > length($prev);
									$o++;
								}
							}
							$_->{mask} = 1 for ($hit ? @parts : ());
							last unless $j == $#$r2 || $r2->[$j + 1]{seg};
							$acc = $cand;
						}
					}
				}
			}

			for my $ln (@lines) {
				print join("", map { $_->{gap} . ($_->{mask} ? mask($_->{txt}) : $_->{txt}) } @{ $ln->{t} }), $ln->{tail}, "\n";
			}
		'
}

# Perl rather than awk/bash for the actual parsing: UTF-8 aware column handling
# on the `pdftotext -layout` text, JSON::PP (core) for the output.
read -r -d '' PARSER <<'PERL' || true
use strict;
use warnings;
use utf8;
use JSON::PP;

binmode(STDIN, ":encoding(UTF-8)");
binmode(STDOUT, ":encoding(UTF-8)");

my $AMT  = qr/[+-]?(?:\d{1,3}(?:\.\d{3})+|\d+),\d{2}/;
my $DATE = qr/\d\d\.\d\d\.\d{4}/;
my $IBAN = qr/[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?/;

sub num  { my $s = shift; $s =~ s/\.//g; $s =~ s/,/./; $s =~ s/^\+//; return $s + 0; }
sub iso  { my ($d, $m, $y) = $_[0] =~ /(\d\d)\.(\d\d)\.(\d{4})/; return "$y-$m-$d"; }
sub trim { my $s = shift; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s; }
sub norm { my $s = trim(shift); $s =~ s/\s+/ /g; return $s; }
sub round2 { return sprintf("%.2f", shift) + 0; }

my @raw = <STDIN>;
chomp @raw;
s/\r$//, s/\f//g for @raw;

# Drop page footers; table headers get repeated on every page by the bank.
my @L = grep {
	!(/^\s*comdirect – eine Marke/ || /^\s*\d{5} [^\d]{2,30}$/ || /^\s*Finanzreport Nr\. .* - Seite \d+/
	  || /^\s*Kundennummer\s+[\d ]+$/ || /^\s*Kontonummer \d+ \/ / || /•.*•/ || /USt-ID/)
} @raw;

my (%out, @warnings);
my $all = join("\n", @L);

# --- header ---------------------------------------------------------------
if ($all =~ /Finanzreport Nr\.\s*(\d+)\s+per\s+($DATE)/) {
	$out{header} = { number => $1 + 0, date => iso($2) };
}

# --- overview ---------------------------------------------------------------
my (%acct, @order);
sub acct_for {
	my $name = norm(shift);
	unless ($acct{$name}) {
		my $type = $name =~ /^Giro/ ? "giro" : $name =~ /^Tagesgeld/ ? "tagesgeld"
		         : $name =~ /^Währungsanlage/ ? "fremdwaehrung" : $name =~ /^Depot/ ? "depot"
		         : $name =~ /^Verrechnung/ ? "verrechnung" : "sonstige";
		my ($cur) = $name =~ /\(([A-Z]{3})\)/;
		$acct{$name} = { name => $name, type => $type, currency => $cur // "EUR" };
		push @order, $name;
	}
	return $acct{$name};
}

my $layout_iban = 0;
for my $i (0 .. $#L) {
	next unless $L[$i] =~ /Ihre aktuellen Salden/;
	for my $j ($i + 1 .. ($i + 30 > $#L ? $#L : $i + 30)) {
		my $l = $L[$j];
		if ($l =~ /^\s*Gesamtsaldo(?:\s+($DATE))?\s+($AMT)\s*$/) {
			$out{total_eur} = { as_of => defined $1 ? iso($1) : undef, amount => num($2) };
			last;
		}
		next unless $l =~ /^\s*(\S.*?)\s{2,}((?:$IBAN)\s+)?($AMT)(?:\s+($AMT))?\s*$/ or $l =~ /^\s*(\S.*?)\s{2,}()($AMT)()\s*$/;
		my ($name, $iban, $a1, $a2) = ($1, $2, $3, $4);
		my $a = acct_for($name);
		if (defined $iban && length $iban) { $a->{iban} = trim($iban); $layout_iban = 1; }
		if (defined $a2 && length $a2) {
			$a->{overview_native} = num($a1);
			$a->{balance_eur} = num($a2);
		} else {
			$a->{balance_eur} = num($a1);
			$a->{overview_native} = num($a1) if $a->{currency} eq "EUR";
		}
	}
	last;
}

# --- account sections -------------------------------------------------------
my ($heading, $cur, $tx, %col, $amt_end);
my $soll_haben = 0;

sub finish_tx {
	return unless $tx && $cur;
	my $t = $tx;
	undef $tx;
	my (@type, @ref, @cp, @text, @rawl);
	my $n = 0;
	for my $e (@{ $t->{lines} }) {
		$n++;
		my ($l, $c) = @$e;
		push @rawl, norm($l);
		while ($l =~ /(\S+(?: \S+)*)/g) {
			my ($st, $s) = ($-[1], $1);
			next if $s =~ /^$DATE$/ && $st <= 3;
			if ($t->{era_a}) { push @text, $s; next; }
			if (defined $c->{text} && $st >= $c->{text} - 2)       { push @text, $s }
			elsif (defined $c->{auf} && $st >= $c->{auf} - 2)      { push @cp, $s }
			elsif ($n <= 2 && $s !~ /\d/)                          { push @type, $s }
			elsif ($n == 1)                                        { push @type, $s }
			else                                                   { push @ref, $s }
		}
	}
	my %d;
	my $joined = join(" ", @text);
	$d{end_to_end_ref} = $1 if $joined =~ /End-to-End-Ref\.:\s*(\S+)/;
	$d{mandate_ref}    = $1 if $joined =~ /Mandatsref\.:\s*(\S+)/;
	$d{creditor_id}    = $1 if $joined =~ /Gläubiger-ID:\s*(\S+)/;
	$d{card}           = $1 if $joined =~ /Karte Nr\.\s*(.+?)(?:\s+Kartenzahlung|\s+comdirect|$)/;
	$d{card_timestamp} = $1 if $joined =~ /(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d)/;
	($d{wkn}, $d{isin}) = ($1, $2) if $joined =~ /WPKNR:\s*(\S+)\s+ISIN:\s*([A-Z]{2}[A-Z0-9]{10})/;
	my %tr = (
		booking_date => iso($t->{booking}),
		value_date   => defined $t->{value} ? iso($t->{value}) : undef,
		amount       => $t->{amount},
		type         => norm(join(" ", @type)),
		reference    => join("", map { trim($_) } @ref),
		counterparty => (map { { name => norm(join(" ", grep { !/^$IBAN(?:\/\S+)?$/ } @cp)),
		                         iban_bic => (join(" ", grep { /^$IBAN(?:\/\S+)?$/ } @cp) || undef) } } 1)[0],
		text_lines   => [@text],
		details      => \%d,
		raw_lines    => \@rawl,
	);
	delete $tr{counterparty} if $t->{era_a};
	push @{ $cur->{transactions} }, \%tr;
}

for my $i (0 .. $#L) {
	my $l = $L[$i];
	next if $l =~ /^\s*$/;

	if ($l =~ /\bBuchungstag\b/ && $l =~ /Vorgang|Valuta|Soll|Buchungstext/) {
		%col = ();
		$col{auf}  = index($l, "Auftraggeber") if $l =~ /Auftraggeber/;
		$col{text} = index($l, "Buchungstext") if $l =~ /Buchungstext/;
		$soll_haben = 1 if $l =~ /Soll \/ Haben/;
		$amt_end = length($l =~ s/\s+$//r);
		next;
	}
	next if $cur && $l =~ /^\s*Valuta\s+(Referenz|Reference)?/ && !$tx;

	if ($l =~ /^\s*Alter Saldo\s+(?:($DATE)\s+)?($AMT)\s*$/) {
		my ($d, $a) = ($1, $2);
		my $name = $heading // "Unbekanntes Konto";
		$cur = acct_for($name);
		$cur->{opening_balance} = { date => defined $d ? iso($d) : undef, amount => num($a) };
		$cur->{transactions} //= [];
		$amt_end //= length($l =~ s/\s+$//r);
		undef $tx;
		next;
	}
	if ($cur && $l =~ /^\s*Neuer Saldo\s+(?:($DATE)\s+)?($AMT)\s*$/) {
		finish_tx();
		$cur->{closing_balance} = { date => defined $1 ? iso($1) : undef, amount => num($2) };
		undef $cur;
		undef $heading;
		next;
	}

	unless ($cur) {
		# Account heading candidates: first table cell without digits.
		my ($cell) = $l =~ /^\s*(\S.{0,60}?)(?:\s{2,}|$)/;
		if (defined $cell && ($cell !~ /\d/ || $cell =~ /^[^\d]+\([A-Z]{3}\)$/)) {
			$heading = norm($cell) unless $cell =~ /^(Umsätze|Buchungstag|Valuta|Alter Saldo|Neuer Saldo|EUR)\b/;
			if ($l =~ /Dispositionskredit\s+([\d.]+)\s*EUR/ && defined $heading) {
				(my $v = $1) =~ s/\.//g;
				acct_for($heading)->{overdraft_limit_eur} = $v + 0;
			}
		}
		next;
	}

	# inside a section: a transaction line?
	my $line = $l;
	my $amount;
	my $trimmed = $line =~ s/\s+$//r;
	if ($trimmed =~ /($AMT)$/ && defined $amt_end && abs(length($trimmed) - $amt_end) <= 4) {
		$amount = num($1);
		my $a = length($1);
		$line = substr($trimmed, 0, length($trimmed) - $a) . (" " x $a);
	}

	if ($soll_haben && defined $amount
	    && ($line =~ /^\s*(\S.*?)\s{2,}($DATE)\s{2,}($DATE)\s*$/ || $line =~ /^\s*()($DATE)\s{2,}($DATE)\s*$/)) {
		finish_tx();
		$tx = { era_a => 1, booking => $2, value => $3, amount => $amount, lines => [[$1, {}]] };
		next;
	}
	if (!$soll_haben && $line =~ /^\s{0,3}($DATE)(?:\s|$)/) {
		if ($tx && !defined $tx->{value}) {
			$tx->{value} = $1;
			$tx->{amount} = $amount if defined $amount;
			push @{ $tx->{lines} }, [$line, {%col}];
		} else {
			finish_tx();
			$tx = { booking => $1, amount => $amount, lines => [[$line, {%col}]] };
		}
		next;
	}
	if ($tx) {
		$tx->{amount} = $amount if defined $amount;
		push @{ $tx->{lines} }, [$line, {%col}];
	}
}
finish_tx();

# --- depot --------------------------------------------------------------------
my $inside_depot = 0;
my (@pos, $p);
my $UAMT = qr/\d{1,3}(?:\.\d{3})*,\d+|\d+,\d+/;
for my $i (0 .. $#L) {
	my $l = $L[$i];
	if ($l =~ /^\s*Depotbestand/ || ($l =~ /\bKurswert\b/ && $l =~ /\bKaufwert\b/)) { $inside_depot = 1; next; }
	next unless $inside_depot;
	if ($l =~ /^\s*(\S{6})(?: \/ (\S+))?\s+($UAMT)(?:\s+([A-Za-z]{2,5}))?\s+($UAMT)\s+([A-Z]{3})\s+($UAMT)\s+($UAMT)\s+($AMT)\s*$/) {
		$p = { wkn => $1, (defined $2 ? (custody => $2) : ()), quantity => num($3),
		       (defined $4 ? (unit => $4) : ()), price => num($5), currency => $6,
		       market_value_eur => num($7), cost_value_eur => num($8), gain_loss_eur => num($9), notes => [] };
		push @pos, $p;
		next;
	}
	if ($l =~ /^\s*Gesamtkurswert\s+($UAMT)\s+($UAMT)\s+($AMT)\s*$/) {
		$out{depot_totals}{market_value_eur} = num($1);
		$out{depot_totals}{cost_value_eur} = num($2);
		$out{depot_totals}{gain_loss_eur} = num($3);
		undef $p;
		next;
	}
	if ($l =~ /^\s*Stückzinsen gesamt\s+($AMT)\s*$/) { $out{depot_totals}{accrued_interest_eur} = num($1); next; }
	if ($l =~ /^\s*Gesamtwert\s+($UAMT)\s*$/)       { $out{depot_totals}{total_value_eur} = num($1); $inside_depot = 0; undef $p; next; }
	next unless $p;
	next if $l =~ /^\s*(WKN \/|Bezeichnung|Die Kaufwerte|Gewinn\/Verlust-Rechnung)/;
	if ($l =~ /^\s*(\S{6}) \/ (\S+)\s*$/) { $p->{custody} = $2; $p->{custody_after} = 1; next; }
	if ($l =~ /^(.*?\S)?\s+($AMT)\s*$/ && length($l =~ s/\s+$//r) > 70) {
		$p->{accrued_interest_eur} = num($2);
		$l = $1 // "";
		next if $l =~ /^\s*$/;
	}
	if ($l =~ s/\s+(\d+,\d{4,6})\s+([A-Z]{3})\/([A-Z]{3})\s*$//) { $p->{fx_rate} = { rate => num($1), pair => "$2/$3" }; }
	push @{ $p->{notes} }, norm($l) if $l =~ /\S/;
}
for my $q (@pos) {
	if (delete $q->{custody_after}) {
		$q->{name} = norm(join(" ", @{ $q->{notes} }));
		delete $q->{notes};
	} else {
		$q->{name} = pop @{ $q->{notes} } // "";
		delete $q->{notes} unless @{ $q->{notes} };
	}
}

# --- tax data -------------------------------------------------------------------
my @tax;
for my $i (0 .. $#L) {
	next unless $L[$i] =~ /^\s*Steuerliche Daten/;
	my ($pending, $blank) = (undef, 0);
	for my $j ($i + 1 .. $#L) {
		my $l = $L[$j];
		if ($l =~ /^\s*$/) { last if ++$blank >= 2; next; }
		last if $l =~ /Dieses ist keine Steuerbescheinigung/;
		$blank = 0;
		if    ($l =~ /^\s*(\S.*?)\s{2,}($AMT)\s*$/) { push @tax, { label => norm($1), amount => num($2) }; undef $pending; }
		elsif ($l =~ /^\s*($AMT)\s*$/ && defined $pending) { push @tax, { label => $pending, amount => num($1) }; undef $pending; }
		elsif ($l =~ /^\s*(\S.*\S)\s*$/) { $pending = norm($1); }
	}
	last;
}

# --- interest rates ---------------------------------------------------------------
my (@rates, $ilabel);
my $inside_interest = 0;
for my $l (@L) {
	if ($l =~ /^\s*Zinsübersicht/) { $inside_interest = 1; next; }
	next unless $inside_interest;
	last if $l =~ /^\s*(Wichtige Hinweise|Zinsgleitklausel)/;
	if ($l =~ /^\s*(.*?):\s+(\d+,\d+)\s*%\s*p\.\s*a\.(?:\s*\(gültig ab:\s*($DATE)\))?/) {
		push @rates, { account => $ilabel, kind => norm($1), rate_pct => num($2), valid_from => defined $3 ? iso($3) : undef };
	} elsif ($l =~ /^\s*(\S[^:]*\S)\s*$/ && $l !~ /\d/) {
		$ilabel = norm($1);
	}
}

# --- account data table (IBAN/BIC) at the end ------------------------------------------
for my $l (@L) {
	next unless $l =~ /^\s*(\S.*?)\s{2,}($IBAN)(?:\s+([A-Z0-9]{8,11}))?\s*$/;
	my ($name, $iban, $bic) = (norm($1), $2, $3);
	next unless $acct{$name};
	$acct{$name}{iban} //= $iban;
	$acct{$name}{bic} = $bic if defined $bic;
}

# --- assemble -----------------------------------------------------------------------------
my (@accounts, @dates_from, @dates_to);
for my $name (@order) {
	my $a = $acct{$name};
	if (defined $a->{opening_balance}) {
		push @dates_from, $a->{opening_balance}{date} if defined $a->{opening_balance}{date};
		push @dates_to, $a->{closing_balance}{date} if $a->{closing_balance} && defined $a->{closing_balance}{date};
		unless ($a->{closing_balance}) {
			push @warnings, "$name: no 'Neuer Saldo' found";
		} else {
			my $sum = 0;
			$sum += $_->{amount} // 0 for @{ $a->{transactions} };
			my $calc = round2($a->{opening_balance}{amount} + $sum);
			push @warnings, sprintf("%s: opening %.2f + transactions %.2f = %.2f, but closing is %.2f",
				$name, $a->{opening_balance}{amount}, $sum, $calc, $a->{closing_balance}{amount})
				if abs($calc - $a->{closing_balance}{amount}) > 0.005;
			push @warnings, "$name: transaction without amount"
				if grep { !defined $_->{amount} } @{ $a->{transactions} };
			push @warnings, sprintf("%s: overview balance %.2f differs from closing balance %.2f", $name,
				$a->{overview_native}, $a->{closing_balance}{amount})
				if defined $a->{overview_native} && abs($a->{overview_native} - $a->{closing_balance}{amount}) > 0.005;
		}
	}
	if ($a->{currency} ne "EUR" && defined $a->{overview_native} && defined $a->{balance_eur} && $a->{overview_native} != 0) {
		$a->{eur_equivalent} = { value => $a->{balance_eur}, implied_rate_eur_per_unit => $a->{balance_eur} / $a->{overview_native} };
	}
	delete $a->{overview_native};
	delete $a->{transactions} if $a->{type} eq "depot" && !@{ $a->{transactions} // [] };
	push @accounts, $a;
}

push @warnings, "no accounts found" unless @accounts;
if (my ($dep) = grep { $_->{type} eq "depot" } @accounts) {
	push @warnings, "depot has value in overview but no positions were parsed"
		if ($dep->{balance_eur} // 0) > 0 && !@pos;
}

if (@pos && $out{depot_totals}) {
	my $sum = 0;
	$sum += $_->{market_value_eur} for @pos;
	push @warnings, sprintf("depot: positions sum %.2f differs from Gesamtkurswert %.2f", $sum, $out{depot_totals}{market_value_eur})
		if abs($sum - $out{depot_totals}{market_value_eur}) > 0.005;
	my ($dep) = grep { $_->{type} eq "depot" } @accounts;
	push @warnings, sprintf("depot: Gesamtwert %.2f differs from overview %.2f", $out{depot_totals}{total_value_eur}, $dep->{balance_eur})
		if $dep && defined $out{depot_totals}{total_value_eur} && defined $dep->{balance_eur}
		   && abs($out{depot_totals}{total_value_eur} - $dep->{balance_eur}) > 0.005;
}

my ($pf) = sort @dates_from;
my ($pt) = reverse sort @dates_to;
$out{period} = { from => $pf, to => $pt } if $pf || $pt;
$out{layout} = $soll_haben ? "soll-haben" : $layout_iban ? "vorgang-iban" : "vorgang";
$out{accounts} = \@accounts;
$out{depot} = { positions => \@pos, %{ $out{depot_totals} // {} } } if @pos || $out{depot_totals};
delete $out{depot_totals};
$out{tax_data} = \@tax if @tax;
$out{interest_rates} = \@rates if @rates;
$out{warnings} = \@warnings;

print JSON::PP->new->pretty->canonical->encode(\%out);
PERL

main "${@}"
