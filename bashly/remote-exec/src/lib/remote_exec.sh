# Shared logic for every remote-exec subcommand: sync the current project
# directory to a scratch location on a remote host, then run a command
# there. Subcommands call re::init once, then re::sync_project and
# re::run_remote (re::clean_remote instead, for 'clean' -- it skips both).

# Resolves --host/--root/--dry-run (flag, else env var) and the remote
# scratch directory for the current $PWD -- always this directory's own
# absolute local path appended to the root, so distinct local projects
# never collide even if they happen to share a basename. RE_ROOT is kept
# around (not just folded into RE_REMOTE_DIR) since 'clean' needs it as
# the upper bound past which it must never remove anything.
re::init() {
	RE_HOST="${args[--host]:-${REMOTE_EXEC_HOST}}"
	RE_ROOT="${args[--root]:-${REMOTE_EXEC_ROOT}}"
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

# Removes the remote scratch directory outright, then removes any now-empty
# ancestor directories back up towards -- but never including -- RE_ROOT,
# so the root itself survives for future runs, and an ancestor still
# shared with another project's scratch dir is left alone the moment
# rmdir finds it non-empty and stops there. No rsync involved: there's
# nothing to sync for a removal.
re::clean_remote() {
	if [[ -n "${RE_DRY_RUN}" ]]; then
		echo "Dry run: would remove '${RE_REMOTE_DIR}' on '${RE_HOST}', and any now-empty parent(s) up to '${RE_ROOT}'." >&2
		return 0
	fi

	echo "Removing '${RE_REMOTE_DIR}' on '${RE_HOST}'..." >&2
	if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${RE_HOST}" "rm -rf -- $(printf '%q' "${RE_REMOTE_DIR}")"; then
		echo "Error: couldn't reach '${RE_HOST}' over ssh, or failed to remove '${RE_REMOTE_DIR}' there -- see above for details." >&2
		exit 1
	fi

	# Ancestor dirs are computed locally, deepest first, by repeatedly
	# stripping the last path segment -- cheaper and simpler than parsing
	# 'dirname' output back out of a remote shell loop.
	local -a ancestors=()
	local dir="${RE_REMOTE_DIR%/*}"
	while [[ -n "${dir}" && "${dir}" != "${RE_ROOT}" && "${dir}" != "/" ]]; do
		ancestors+=("${dir}")
		dir="${dir%/*}"
	done
	[[ "${#ancestors[@]}" -eq 0 ]] && return 0

	local remote_cmd="" anc
	for anc in "${ancestors[@]}"; do
		remote_cmd+="${remote_cmd:+ && }rmdir -- $(printf '%q' "${anc}")"
	done

	# Chained with && on purpose: rmdir stops at (and fails harmlessly on)
	# the first ancestor that isn't actually empty, which is the normal,
	# expected outcome whenever the root is shared with another project --
	# so its own exit status is deliberately not treated as an error here.
	echo "Removing now-empty parent(s) up to '${RE_ROOT}'..." >&2
	ssh -o BatchMode=yes -o ConnectTimeout=5 "${RE_HOST}" "${remote_cmd}" || true
}
