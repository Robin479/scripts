# Shared logic for every remote-exec subcommand: sync the current project
# directory to a scratch location on a remote host, then run a command
# there. Subcommands call re::init once, then re::sync_project and
# re::run_remote; 'clean' calls re::clean_recorded instead, skipping all of it.

re::config_file() {
	echo "${REMOTE_EXEC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/remote-exec/config.ini}"
}

# Record of every remote scratch copy made, one "<local dir>\t<host>\t<root>"
# line each (no duplicates), next to the config file -- so 'clean' knows
# where to look regardless of what host/root the config says today.
re::history_file() {
	echo "$(dirname "$(re::config_file)")/history"
}

re::history_add() {
	local entry file
	entry="$(printf '%s\t%s\t%s' "${PWD}" "${RE_HOST}" "${RE_ROOT}")"
	file="$(re::history_file)"
	[[ -f "${file}" ]] && grep -qFx -- "${entry}" "${file}" && return 0
	mkdir -p "$(dirname "${file}")"
	printf '%s\n' "${entry}" >> "${file}"
}

# True if local dir $1 is $2 itself or somewhere below it.
re::is_within() {
	[[ "$2" == / || "$1" == "$2" || "$1" == "$2"/* ]]
}

# Drops every entry for the given host/root that's gone remotely after
# cleaning local dir $3 there: $3 itself or anything below it (rm -rf took
# it along), plus each local dir listed in $4 (newline-separated) whose
# remote copy was removed as a now-empty parent.
re::history_prune() {
	local host="$1" root="$2" target="$3" removed="$4"
	local file entry dir h r gone anc content=""
	file="$(re::history_file)"
	[[ -f "${file}" ]] || return 0
	while IFS= read -r entry; do
		IFS=$'\t' read -r dir h r <<< "${entry}"
		gone=0
		if [[ "${h}" == "${host}" && "${r}" == "${root}" ]]; then
			if re::is_within "${dir}" "${target}"; then
				gone=1
			else
				while IFS= read -r anc; do
					[[ -n "${anc}" && "${dir}" == "${anc}" ]] && gone=1
				done <<< "${removed}"
			fi
		fi
		if [[ "${gone}" -eq 1 ]]; then
			echo "Dropped '${dir}' on '${h}' from the history." >&2
		else
			content+="${entry}"$'\n'
		fi
	done < "${file}"
	# Fully built in memory first, so the truncating redirect is safe.
	printf '%s' "${content}" > "${file}"
}

# Looks up one setting in the config file: the running command's own
# section first (e.g. [mvn] host), then the sectionless global key, else
# the given default. Read-only, so a missing config file is just empty
# (bashly's config_* would create it on first read).
re::config_get() {
	local key="$1" default="$2" file
	file="$(re::config_file)"
	declare -gA ini=()
	[[ -f "${file}" ]] && ini_load "${file}"
	# shellcheck disable=SC2154 # action is set by bashly's own run()
	echo "${ini[${action}.${key}]:-${ini[${key}]:-${default}}}"
}

# Resolves --host/--root/--dry-run (flag, else env var, else config file,
# else built-in default) and the remote scratch directory for the current
# $PWD -- always this directory's own absolute local path appended to the
# root, so distinct local projects never collide even if they happen to
# share a basename. RE_ROOT is kept around (not just folded into
# RE_REMOTE_DIR) since 'clean' needs it as the upper bound past which it
# must never remove anything.
re::init() {
	RE_HOST="${args[--host]:-${REMOTE_EXEC_HOST:-$(re::config_get host kiwi)}}"
	RE_ROOT="${args[--root]:-${REMOTE_EXEC_ROOT:-$(re::config_get root /tmp/remote-exec)}}"
	RE_ROOT="${RE_ROOT%/}"
	RE_REMOTE_DIR="${RE_ROOT}${PWD}"
	RE_DRY_RUN="${args[--dry-run]:-}"
}

# Makes sure the remote host is reachable and the scratch directory exists
# there (also serves as the connectivity check), then rsyncs the current
# project directory into it -- excluding .git, target, and Eclipse metadata,
# which have no business traveling to a disposable remote scratch copy.
# --delete keeps the remote copy in sync with local deletions; since target/
# is excluded from the sync to begin with, it's left alone on the remote
# side, so incremental builds there stay incremental across repeated runs.
re::sync_project() {
	echo "Checking that '${RE_HOST}' is reachable, and creating '${RE_REMOTE_DIR}' there..." >&2
	if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${RE_HOST}" "mkdir -p $(printf '%q' "${RE_REMOTE_DIR}")"; then
		echo "Error: couldn't reach '${RE_HOST}' over ssh, or failed to create '${RE_REMOTE_DIR}' there -- see above for details." >&2
		exit 1
	fi
	# Recorded as soon as the directory exists remotely -- even on a dry run,
	# since the mkdir above isn't dry.
	re::history_add

	local -a rsync_opts=(-a --delete --exclude .git --exclude target --exclude .settings --exclude .classpath --exclude .project)
	[[ -n "${RE_DRY_RUN}" ]] && rsync_opts+=(-n -v)

	echo "Syncing '${PWD}' to '${RE_HOST}:${RE_REMOTE_DIR}/'..." >&2
	rsync "${rsync_opts[@]}" "${PWD}/" "${RE_HOST}:${RE_REMOTE_DIR}/"
}

# Runs the given command (its words individually quoted for the remote
# shell) on the remote host, inside the synced scratch directory -- unless
# --dry-run was given, in which case it's only described, not actually run.
# Nothing is synced back: whatever the remote command populates outside the
# scratch copy (e.g. ~/.m2/repository) is the actual point: the scratch
# copy itself, and any build output under it, is disposable.
re::run_remote() {
	if [[ -n "${RE_DRY_RUN}" ]]; then
		echo "Dry run: skipping the remote '$*' step." >&2
		exit 0
	fi

	local remote_cmd part
	remote_cmd="cd $(printf '%q' "${RE_REMOTE_DIR}") &&"
	for part in "$@"; do
		remote_cmd+=" $(printf '%q' "${part}")"
	done

	echo "Running on '${RE_HOST}': $*" >&2
	ssh -t "${RE_HOST}" "${remote_cmd}"
}

# Cleans the current $PWD's remote scratch copy on every host/root on
# record for $PWD or any of its parents -- i.e. a subfolder of a synced dir
# cleans just that subfolder remotely. With --all, it instead cleans every
# entry's own dir, wherever it is. Afterwards, every entry whose remote copy
# is gone (cleaned outright, or removed as a now-empty parent) is dropped
# from the history; the rest stay. --host/--root (or their env vars) narrow
# it down to matching entries only; the config file deliberately doesn't,
# since it may have changed since the copy was made. A copy that fails to
# clean (e.g. host unreachable) keeps its entry, so a later 'clean' retries
# it.
re::clean_recorded() {
	local want_host="${args[--host]:-${REMOTE_EXEC_HOST:-}}"
	local want_root="${args[--root]:-${REMOTE_EXEC_ROOT:-}}"
	want_root="${want_root%/}"
	RE_DRY_RUN="${args[--dry-run]:-}"
	local all="${args[--all]:-}"

	# One "<host>\t<root>\t<local dir to clean>" per remote copy to clean.
	local -a targets=()
	local file entry dir host root
	file="$(re::history_file)"
	if [[ -f "${file}" ]]; then
		while IFS= read -r entry; do
			IFS=$'\t' read -r dir host root <<< "${entry}"
			[[ -z "${want_host}" || "${host}" == "${want_host}" ]] || continue
			[[ -z "${want_root}" || "${root}" == "${want_root}" ]] || continue
			if [[ -n "${all}" ]]; then
				targets+=("${host}"$'\t'"${root}"$'\t'"${dir}")
			elif re::is_within "${PWD}" "${dir}"; then
				targets+=("${host}"$'\t'"${root}"$'\t'"${PWD}")
			fi
		done < "${file}"
	fi

	if [[ "${#targets[@]}" -eq 0 ]]; then
		local filter=""
		[[ -n "${want_host}" ]] && filter+=" on host '${want_host}'"
		[[ -n "${want_root}" ]] && filter+=" under root '${want_root}'"
		local what="of '${PWD}' (or a parent)"
		[[ -n "${all}" ]] && what="at all"
		echo "No dirty remote copy ${what} on record${filter} -- nothing to clean." >&2
		return 0
	fi

	# Duplicates (several parents on record for the same host/root), and
	# targets below another one on the same host/root (--all only), are
	# already covered by that other target's rm -rf.
	local -a unique
	mapfile -t unique < <(printf '%s\n' "${targets[@]}" | sort -u)
	local t o t_dir o_dir covered failed=0 removed
	for t in "${unique[@]}"; do
		t_dir="${t##*$'\t'}"
		covered=0
		for o in "${unique[@]}"; do
			o_dir="${o##*$'\t'}"
			[[ "${o}" != "${t}" && "${o%$'\t'*}" == "${t%$'\t'*}" ]] || continue
			re::is_within "${t_dir}" "${o_dir}" && covered=1 && break
		done
		[[ "${covered}" -eq 0 ]] || continue

		IFS=$'\t' read -r host root dir <<< "${t}"
		if removed="$(re::clean_remote "${dir}" "${host}" "${root}")"; then
			[[ -n "${RE_DRY_RUN}" ]] || re::history_prune "${host}" "${root}" "${dir}" "${removed}"
		else
			failed=1
		fi
	done
	[[ "${failed}" -eq 0 ]] || exit 1
}

# Removes one remote scratch directory (root + local dir $1, on host $2)
# outright, then removes any now-empty ancestor directories back up
# towards -- but never including -- the root, so the root itself survives
# for future runs, and an ancestor still shared with another project's
# scratch dir is left alone the moment rmdir finds it non-empty and stops
# there. No rsync involved: there's nothing to sync for a removal. Prints
# the local dir of each ancestor actually removed, for the history; returns
# non-zero if the removal itself failed. A directory that's already gone is
# just reported (a repeated 'clean'), not an error, and leaves the parents
# alone -- whatever cleaned it before already took care of those.
re::clean_remote() {
	local dir="$1" host="$2" root="$3"
	local remote_dir="${root}${dir}"

	if [[ -n "${RE_DRY_RUN}" ]]; then
		echo "Dry run: would remove '${remote_dir}' on '${host}', and any now-empty parent(s) up to '${root}'." >&2
		return 0
	fi

	local quoted status=0
	quoted="$(printf '%q' "${remote_dir}")"
	echo "Removing '${remote_dir}' on '${host}'..." >&2
	ssh -o BatchMode=yes -o ConnectTimeout=5 "${host}" "if [ -e ${quoted} ]; then rm -rf -- ${quoted}; else exit 99; fi" || status=$?
	if [[ "${status}" -eq 99 ]]; then
		echo "Already gone on '${host}' -- nothing to clean there." >&2
		return 0
	elif [[ "${status}" -ne 0 ]]; then
		echo "Error: couldn't reach '${host}' over ssh, or failed to remove '${remote_dir}' there -- see above for details; keeping it on record." >&2
		return 1
	fi

	# Ancestor dirs are computed locally, deepest first, by repeatedly
	# stripping the last path segment of the local dir -- the root itself
	# (local '/') is never among them.
	local -a ancestors=()
	local anc="${dir%/*}"
	while [[ -n "${anc}" ]]; do
		ancestors+=("${anc}")
		anc="${anc%/*}"
	done
	[[ "${#ancestors[@]}" -eq 0 ]] && return 0

	local remote_cmd=""
	for anc in "${ancestors[@]}"; do
		remote_cmd+="${remote_cmd:+ && }rmdir -- $(printf '%q' "${root}${anc}") 2>/dev/null && printf '%s\n' $(printf '%q' "${anc}")"
	done

	# Chained with && on purpose: rmdir stops at (and fails harmlessly on)
	# the first ancestor that isn't actually empty (hence its stderr is
	# muted), which is the normal, expected outcome whenever the root is shared with another project --
	# so its own exit status is deliberately not treated as an error here.
	# Each successful rmdir echoes its local dir back, so the caller knows
	# which history entries went with it.
	echo "Removing now-empty parent(s) up to '${root}'..." >&2
	ssh -o BatchMode=yes -o ConnectTimeout=5 "${host}" "${remote_cmd}" || true
}
