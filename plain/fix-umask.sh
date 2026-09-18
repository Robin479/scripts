#!/bin/bash

main() {
	local dry_run=0
	local -a search_paths=()
	local arg
	for arg in "$@"; do
		case "${arg}" in
			-h|--help) usage; exit 0 ;;
			--dry-run) dry_run=1 ;;
			*) search_paths+=("${arg}") ;;
		esac
	done

	[ "${#search_paths[@]}" -eq 0 ] && search_paths=("${PWD}")
	mapfile -t search_paths < <(printf '%s\n' "${search_paths[@]}" | sort)

	local umask_str
	umask_str="$(umask)"
	umask_str="${umask_str: -3}"
	local u_mask="${umask_str:0:1}" g_mask="${umask_str:1:1}" o_mask="${umask_str:2:1}"

	local my_uid my_gid
	my_uid="$(id -u)"
	my_gid="$(id -g)"

	# path -> chmod symbolic spec, only for paths decided to be fixed; kept in
	# decision order in fix_order so phase 2 (below) can walk it back-to-front
	# (children before their parent directory), so clearing excess bits off a
	# directory never locks us out of paths still nested under it. Granting a
	# directory the execute bit it needs to be scanned at all, in contrast,
	# happens eagerly, on the spot, in process_path itself -- see there.
	local -A fix_spec=()
	local -a fix_order=()

	local recurse_scope="" recurse_action=""
	local bulk_dir="" bulk_action=""
	local quit=0 total=0 granted=0

	# Canonical real paths of directories currently being descended into, so
	# a symlink loop (a symlink that, directly or through further symlinks,
	# leads back to one of its own ancestors) can be detected and stopped
	# instead of recursing forever. Pushed/popped around each directory's
	# own children loop in process_path.
	local -A visiting=()

	local root
	for root in "${search_paths[@]}"; do
		[ "${quit}" -eq 1 ] && break
		if [ ! -e "${root}" ] && [ ! -L "${root}" ]; then
			echo "Error: '${root}' does not exist -- skipping it. (A quoted glob like '*' that matched nothing would end up here too.)" >&2
			continue
		fi
		process_path "${root}"
	done

	local i fixed=0 path
	for (( i = ${#fix_order[@]} - 1; i >= 0; i-- )); do
		path="${fix_order[i]}"
		if [ "${dry_run}" -eq 1 ]; then
			echo "[dry-run] would run: chmod ${fix_spec[${path}]} -- '${path}'" >&2
			fixed=$((fixed + 1))
		elif chmod "${fix_spec[${path}]}" -- "${path}"; then
			fixed=$((fixed + 1))
		else
			echo "Error: failed to chmod '${path}'." >&2
		fi
	done

	echo "Fixed ${fixed} of ${total} non-compliant path(s) (plus ${granted} directory access grant(s))."
	[ "${quit}" -eq 1 ] && echo "Stopped early; remaining paths were left untouched."
	[ "${dry_run}" -eq 1 ] && echo "Dry run: nothing was actually changed. A directory missing its own access grant could not be scanned any deeper than shown."

	return 0
}

usage() {
	cat <<-EOF
	Usage: fix-umask [--dry-run] [PATH...]

	Find files and directories under PATH... (default: the current directory)
	whose permission bits don't match what the current umask ($(umask)) implies
	is the compliant default (base mode 777 for a directory, 666 for anything
	else, minus the umask), and interactively offer to fix them: excess bits
	the umask should have masked off get stripped, and bits the umask allows
	but that are missing get granted -- both in the same fix.

	Only the permission categories that are actually yours get touched:
	  - "user" bits are only checked/fixed on paths you own
	  - "group" bits are only checked/fixed on paths whose group is your main
	    (primary) group, not just any group you happen to belong to
	  - "other" bits are always checked/fixed
	  - the execute bit is only ever checked/fixed on directories; it is left
	    alone on every other file, no matter what the umask says

	A symlink is never "fixed" itself -- there's nothing meaningful to chmod
	on the link. Instead, the file it points to is checked/fixed in its
	place, using the link's own directory for the a/d "rest of this
	directory" grouping. When it points to a directory, that directory is
	entered and scanned exactly like any other -- unless doing so would
	loop back to one of its own ancestors (through this symlink or a chain
	of them), in which case it's left unentered instead of recursing
	forever.

	A directory that's missing the one execute bit that actually applies to
	you (owner -> user bit, else primary group -> group bit, else -> other
	bit) can't be scanned at all -- its contents are invisible until that bit
	is set. Such a directory is still offered a fix like any other: approving
	it grants just that one execute bit right away and then descends into it
	looking for more non-compliant paths; declining leaves it, and everything
	that might be nested under it, unexamined.

	For every offending path found, you're asked:
	  y  fix just this path                                        [default]
	  n  leave just this path
	  r  fix this path and everything nested under it, no more asking about it
	  s  leave this path and everything nested under it, no more asking about it
	  a  fix this path and every other offending entry still left in this same
	     directory (their own nested contents are still asked about individually)
	  d  leave this path and every other offending entry still left in this
	     same directory (their own nested contents are still asked about
	     individually)
	  q  quit now; this path and everything after it is left alone

	--dry-run reports what would be fixed or granted instead of actually
	running chmod. Since nothing is really changed, a directory that needs
	an access grant to be scanned stays locked, so anything nested under it
	can't be previewed either -- only a real run can look inside it.
	EOF
}

# Decides and (partly) applies the fix for a single path, then -- for a
# directory it can access, whether it already could or was just granted
# access -- recurses into its immediate children in the same way. A symlink
# is never "fixed" itself; it's resolved to the real file (or directory) it
# points to first, and that's what actually gets checked/fixed and, for a
# directory, entered and scanned, exactly like a directory reached without
# going through a symlink at all. The only exception is a symlink that
# loops back to one of its own ancestors (directly or through further
# symlinks) -- that one is left unentered so the walk can't recurse forever.
process_path() {
	local path="$1"
	[ "${quit}" -eq 1 ] && return

	local fix_path="${path}" via_symlink=0
	if [ -L "${path}" ]; then
		via_symlink=1
		fix_path="$(readlink -f -- "${path}")" || return
		[ -n "${fix_path}" ] || return
	fi

	local spec desc grant
	compute_fix "${fix_path}" spec desc grant || return

	local is_dir=0
	[ -d "${fix_path}" ] && is_dir=1
	local access_now=1
	[ "${is_dir}" -eq 1 ] && [ ! -x "${fix_path}" ] && access_now=0

	if [ -n "${spec}" ] || [ -n "${grant}" ]; then
		total=$((total + 1))

		local dir decision
		dir="$(path_dirname "${path}")"

		if [ -n "${recurse_scope}" ] && [[ "${path}" == "${recurse_scope}/"* ]]; then
			decision="${recurse_action}"
		elif [ -n "${bulk_action}" ] && [ "${dir}" = "${bulk_dir}" ]; then
			decision="${bulk_action}"
		else
			bulk_dir="" bulk_action=""

			local ans
			ans="$(prompt_action "${path}" "${fix_path}" "${via_symlink}" "${desc}")"
			case "${ans}" in
				y) decision=fix ;;
				n) decision=skip ;;
				r) decision=fix;  recurse_scope="${path}"; recurse_action=fix ;;
				s) decision=skip; recurse_scope="${path}"; recurse_action=skip ;;
				a) decision=fix;  bulk_dir="${dir}"; bulk_action=fix ;;
				d) decision=skip; bulk_dir="${dir}"; bulk_action=skip ;;
				q) decision=skip; quit=1 ;;
			esac
		fi

		if [ "${decision}" = fix ]; then
			if [ -n "${grant}" ]; then
				if [ "${dry_run}" -eq 1 ]; then
					echo "[dry-run] would run: chmod ${grant}+x -- '${fix_path}' (leaving it locked, so anything nested under it stays unscanned)" >&2
					granted=$((granted + 1))
				elif chmod "${grant}+x" -- "${fix_path}"; then
					access_now=1
					granted=$((granted + 1))
				else
					echo "Error: failed to grant '${grant}+x' on '${fix_path}'." >&2
				fi
			fi
			if [ -n "${spec}" ]; then
				fix_spec["${fix_path}"]="${spec}"
				fix_order+=("${fix_path}")
			fi
		fi
	fi

	if [ "${is_dir}" -eq 1 ] && [ "${access_now}" -eq 1 ]; then
		local real
		real="$(readlink -f -- "${fix_path}")"

		if [ -n "${real}" ] && [ -z "${visiting[${real}]:-}" ]; then
			visiting["${real}"]=1

			local -a children
			mapfile -d '' -t children < <(find "${fix_path}" -mindepth 1 -maxdepth 1 -print0 | sort -z)

			local child
			for child in "${children[@]}"; do
				[ "${quit}" -eq 1 ] && break
				process_path "${child}"
			done

			unset "visiting[${real}]"
		elif [ -n "${real}" ]; then
			echo "Skipping '${path}': symlink loop (already inside '${real}' higher up this tree)." >&2
		fi
	fi
}

# Looks up path's owner/group/mode and, given the categories that are
# actually applicable (owner match, primary-group match, always for
# "other"), figures out how each one's bits differ from what the current
# umask implies is compliant (base mode 777 for a directory, 666 for
# anything else, minus the umask) -- both excess bits (set but should be
# masked off) and missing ones (allowed by the umask but not actually set)
# -- and sets the combined chmod symbolic spec and a human-readable
# description via nameref out-parameters. For a directory missing the one
# execute bit that governs your own access to it, also sets the third
# out-parameter to the single category ("u"/"g"/"o") that bit belongs to
# (that one bit is granted eagerly elsewhere, see process_path, so it's
# excluded from the deferred spec here to avoid handling it twice). Returns
# failure only when the path itself couldn't be stat'd (e.g. it vanished
# mid-run); an empty spec/grant is a normal "nothing to do here", not a
# failure.
compute_fix() {
	local path="$1"
	local -n _spec="$2" _desc="$3" _grant="$4"

	local owner_uid gid perm
	read -r owner_uid gid perm < <(stat -c '%u %g %a' -- "${path}" 2>/dev/null) || return 1
	perm="${perm: -3}"
	local u="${perm:0:1}" g="${perm:1:1}" o="${perm:2:1}"

	local is_dir=0
	[ -d "${path}" ] && is_dir=1

	# The x bit is only meaningful (and only umask-checked/fixed) on
	# directories; on every other file type it's left alone entirely, no
	# matter what the umask says, since execute there is a deliberate,
	# per-file choice (e.g. chmod +x on a script), not a umask default.
	local bit_scope=6
	[ "${is_dir}" -eq 1 ] && bit_scope=7

	_spec="" _desc="" _grant=""

	# Which single category governs *your* access to a directory (real
	# POSIX priority: owner beats group beats other) -- its execute bit, if
	# missing, is granted eagerly elsewhere rather than through the loop
	# below.
	local access_cat=""
	if [ "${is_dir}" -eq 1 ]; then
		if [ "${owner_uid}" = "${my_uid}" ]; then
			access_cat=u
		elif [ "${gid}" = "${my_gid}" ]; then
			access_cat=g
		else
			access_cat=o
		fi
	fi

	local cat bits mask applicable excess allowed missing part
	for cat in u g o; do
		case "${cat}" in
			u)
				bits="${u}" mask="${u_mask}"
				[ "${owner_uid}" = "${my_uid}" ] && applicable=1 || applicable=0
				;;
			g)
				bits="${g}" mask="${g_mask}"
				[ "${gid}" = "${my_gid}" ] && applicable=1 || applicable=0
				;;
			o)
				bits="${o}" mask="${o_mask}" applicable=1
				;;
		esac
		[ "${applicable}" -eq 1 ] || continue

		excess=$(( bits & mask & bit_scope ))
		allowed=$(( bit_scope & (7 ^ mask) ))
		missing=$(( allowed & (7 ^ bits) ))
		# That one access-granting execute bit is handled eagerly instead.
		[ "${cat}" = "${access_cat}" ] && missing=$(( missing & 6 ))

		if [ "${excess}" -ne 0 ]; then
			part="${cat}-$(bits_to_sym "${excess}")"
			_spec="${_spec:+${_spec},}${part}"
			_desc="${_desc:+${_desc}, }${part}"
		fi
		if [ "${missing}" -ne 0 ]; then
			part="${cat}+$(bits_to_sym "${missing}")"
			_spec="${_spec:+${_spec},}${part}"
			_desc="${_desc:+${_desc}, }${part}"
		fi
	done

	if [ "${is_dir}" -eq 1 ]; then
		local access_bits
		case "${access_cat}" in
			u) access_bits="${u}" ;;
			g) access_bits="${g}" ;;
			o) access_bits="${o}" ;;
		esac

		if (( (access_bits & 1) == 0 )); then
			_grant="${access_cat}"
			_desc="${_desc:+${_desc}; }${access_cat}+x (grants you access to scan this directory)"
		fi
	fi

	return 0
}

bits_to_sym() {
	local n="$1" s=""
	(( n & 4 )) && s+="r"
	(( n & 2 )) && s+="w"
	(( n & 1 )) && s+="x"
	printf '%s' "${s}"
}

path_dirname() {
	local p="${1%/}"
	case "${p}" in
		*/*) printf '%s' "${p%/*}" ;;
		*)   printf '%s' "." ;;
	esac
}

prompt_action() {
	local path="$1" fix_path="$2" via_symlink="$3" desc="$4"

	ls -ld -- "${path}" >&2
	[ "${via_symlink}" -eq 1 ] && ls -ld -- "${fix_path}" >&2
	echo "  would fix: ${desc}" >&2

	local prompt="Fix [y]es/[n]o/[r]ecurse-fix/[s]kip-tree/[a]ll-here/[d]ecline-rest/[q]uit (y): "

	local ans
	while true; do
		if ! read -r -p "${prompt}" ans; then
			ans=q
		fi
		ans="${ans,,}"
		[ -z "${ans}" ] && ans=y
		case "${ans}" in
			y|n|r|s|a|d|q) break ;;
			*) echo "Please answer one of: y/n/r/s/a/d/q -- see the prompt above (or --help) for what each does." >&2 ;;
		esac
	done

	printf '%s' "${ans}"
}

main "${@}"
