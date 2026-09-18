readonly BOXCTL_CALIBRE_BASE_URL="https://download.calibre-ebook.com/"
readonly BOXCTL_CALIBRE_UNINSTALL_BIN="/usr/bin/calibre-uninstall"

boxctl::install_calibre_check() {
  command -v xidel >/dev/null 2>&1 || {
    echo "error: xidel is required but not installed (run 'boxctl install xidel' first)." >&2
    exit 1
  }

  command -v expect >/dev/null 2>&1 || {
    echo "error: 'expect' is required but not installed. Install it (e.g. 'apt-get install -y expect')." >&2
    exit 1
  }
}

# Sets INSTALLED_VERSION (empty if no /opt/calibre-<version> installation is found).
boxctl::install_calibre_installed_version() {
  local dir
  dir="$(compgen -G '/opt/calibre-*' | sort -V | tail -n1 || true)"
  # shellcheck disable=SC2034 # read by install_command.sh, the caller of this function
  if [[ -n "${dir}" ]]; then
    INSTALLED_VERSION="${dir#/opt/calibre-}"
  else
    INSTALLED_VERSION=""
  fi
}

# $1: exact version to install, or empty/"latest" for the latest release.
# Sets AVAILABLE_VERSION, DOWNLOAD_URL, FILENAME and INSTALL_DIR.
boxctl::install_calibre_available_version() {
  local version_filter="$1"
  [[ "${version_filter}" == "latest" ]] && version_filter=""

  local series_label="" series_predicate="1" release_predicate="1"

  if [[ -n "${version_filter}" ]]; then
    echo "Looking up calibre release ${version_filter}..."

    # Series pages are named after the major version (e.g. "9.x"), except
    # for legacy releases before 1.0, which are grouped by minor (e.g.
    # "0.9.x").
    local major minor
    major="${version_filter%%.*}"
    if [[ "${major}" == "0" ]]; then
      minor="${version_filter#*.}"
      minor="${minor%%.*}"
      series_label="0.${minor}.x"
    else
      series_label="${major}.x"
    fi

    series_predicate="a='${series_label}'"
    release_predicate="a='${version_filter}'"
  else
    echo "Looking up latest calibre release..."
  fi

  local series_url release_url

  series_url="$(xidel -s "${BOXCTL_CALIBRE_BASE_URL}" -e "(//ul/li[${series_predicate}]/a)/resolve-uri(@href)")"
  if [[ -z "${series_url}" ]]; then
    echo "error: could not find release series '${series_label:-<latest>}' on ${BOXCTL_CALIBRE_BASE_URL}" >&2
    exit 1
  fi

  release_url="$(xidel -s "${series_url}" -e "(//ul[@class='release-list']/li[${release_predicate}]/a)/resolve-uri(@href)")"
  if [[ -z "${release_url}" ]]; then
    echo "error: could not find release '${version_filter:-<latest>}' on ${series_url}" >&2
    exit 1
  fi

  DOWNLOAD_URL="$(xidel -s "${release_url}" -e '(//a[@title="Linux Intel 64-bit binary"])/resolve-uri(@href)')"
  if [[ -z "${DOWNLOAD_URL}" ]]; then
    echo "error: could not find the Linux Intel 64-bit binary link on ${release_url}" >&2
    exit 1
  fi

  FILENAME="${DOWNLOAD_URL##*/}"
  if [[ "${FILENAME}" =~ ^calibre-([0-9]+\.[0-9]+\.[0-9]+)-x86_64\.[A-Za-z0-9.]+$ ]]; then
    AVAILABLE_VERSION="${BASH_REMATCH[1]}"
  else
    echo "error: unexpected binary filename '${FILENAME}' (expected 'calibre-<version>-x86_64.<ext>')." >&2
    echo "The download page layout may have changed; please check it manually." >&2
    exit 1
  fi

  if [[ -n "${version_filter}" ]] && [[ "${AVAILABLE_VERSION}" != "${version_filter}" ]]; then
    echo "error: resolved version '${AVAILABLE_VERSION}' does not match requested version '${version_filter}'." >&2
    exit 1
  fi

  INSTALL_DIR="/opt/calibre-${AVAILABLE_VERSION}"

  echo "Resolved version: ${AVAILABLE_VERSION}"
}

boxctl::install_calibre_install() {
  echo "Downloading ${DOWNLOAD_URL}..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  local archive_path="${tmp_dir}/${FILENAME}"
  curl -fL --progress-bar -o "${archive_path}" "${DOWNLOAD_URL}"

  # Uninstall the previous version *before* extracting the new one, not
  # after: BOXCTL_CALIBRE_UNINSTALL_BIN's recorded install path is whatever
  # was current when it was generated, which for a same-version reinstall
  # is the very ${INSTALL_DIR} we're about to (re-)populate -- uninstalling
  # after extraction would delete the files just extracted. Uninstalling
  # first also means a reinstall of the currently-installed version is a
  # clean remove-then-recreate rather than an extract-over-a-live-install.
  # curl above already ran (and would have aborted the script via set -e
  # on failure) before anything destructive happens, so a download failure
  # still leaves the old install untouched.
  if [[ -e "${BOXCTL_CALIBRE_UNINSTALL_BIN}" ]]; then
    echo "Running uninstall of previous calibre version..."
    # calibre-uninstall unconditionally reopens /dev/tty for its [y/n]
    # prompts, ignoring piped stdin entirely; expect gives it a pty of its
    # own so the prompts can be answered automatically. The executability
    # check and the uninstall itself are two tightly-coupled root-needing
    # steps -- calibre_postinstall leaves this script mode 0744 (root-only
    # execute), so -x has to be checked as root, not the invoking user, and
    # it always runs right into the same root call -- so both are combined
    # into one bash -c (one sudo prompt instead of two), with the binary
    # path passed positionally rather than interpolated into the string.
    # The path reaches expect via $env(), not by splicing it into the Tcl
    # source, to dodge nested quote-escaping entirely.
    # shellcheck disable=SC2016 # $env(UNINSTALL_BIN)/$result below are expect's own Tcl variables, not bash expansions -- single quotes are deliberate
    boxctl::run_as_root bash -c '
      if [[ -x "$1" ]]; then
        UNINSTALL_BIN="$1" expect -c '"'"'set timeout -1
          spawn -noecho $env(UNINSTALL_BIN)
          expect {
            -re {\[y/n\]:} {
              send "y\r"
              exp_continue
            }
            eof
          }
          catch wait result
          exit [lindex $result 3]
        '"'"'
      else
        echo "error: $1 exists but is not executable." >&2
        exit 1
      fi
    ' _ "${BOXCTL_CALIBRE_UNINSTALL_BIN}" || {
      echo "error: '${BOXCTL_CALIBRE_UNINSTALL_BIN}' failed; aborting before installing the new version." >&2
      exit 1
    }
  fi

  echo "Extracting to ${INSTALL_DIR}..."
  # shellcheck disable=SC2016 # $1/$2 below are the inner bash -c script's own positional params, filled in via the trailing "_" "$1" "$2" args, not this outer bash's expansion
  boxctl::run_as_root bash -c 'mkdir -p "$1" && tar xf "$2" -C "$1"' _ "${INSTALL_DIR}" "${archive_path}"

  local postinstall="${INSTALL_DIR}/calibre_postinstall"
  [[ -x "${postinstall}" ]] || {
    echo "error: '${postinstall}' not found or not executable after extraction." >&2
    echo "The archive layout may have changed; please inspect ${INSTALL_DIR} manually." >&2
    exit 1
  }

  echo "Running postinstall..."
  boxctl::run_as_root "${postinstall}" || {
    echo "error: '${postinstall}' failed; calibre ${AVAILABLE_VERSION} may not be fully installed." >&2
    exit 1
  }
}
