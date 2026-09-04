readonly BOXCTL_XIDEL_DIR_URL="https://sourceforge.net/projects/videlibri/files/Xidel/"
readonly BOXCTL_XIDEL_PACKAGE_NAME="xidel"

boxctl::install_xidel_check() {
  local cmd
  for cmd in curl dpkg-query apt-get; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "error: '${cmd}' is required but not installed." >&2
      exit 1
    }
  done
}

# Sets INSTALLED_VERSION (empty if xidel is not installed).
boxctl::install_xidel_installed_version() {
  # shellcheck disable=SC2034 # read by install_command.sh, the caller of this function
  INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' "${BOXCTL_XIDEL_PACKAGE_NAME}" 2>/dev/null || true)"
}

# $1: non-empty to look up the latest development snapshot instead of the
# latest stable release. Sets AVAILABLE_VERSION, DOWNLOAD_URL and FILENAME.
boxctl::install_xidel_available_version() {
  local dev="$1" release_kind
  if [[ -n "${dev}" ]]; then
    release_kind="development"
  else
    release_kind="stable (non-development)"
  fi
  echo "Looking up latest ${release_kind} xidel release for amd64..."

  local dir_html release_path feed_path release_feed feed_xml match

  dir_html="$(curl -fsSL "${BOXCTL_XIDEL_DIR_URL}")"
  if [[ -z "${dir_html}" ]]; then
    echo "error: could not fetch the SourceForge folder listing at ${BOXCTL_XIDEL_DIR_URL}" >&2
    exit 1
  fi

  # The listing is sorted newest-first; the "Xidel development" folder is
  # the only place development snapshots live, everything else is stable.
  if [[ -n "${dev}" ]]; then
    release_path="$(echo "${dir_html}" | grep -oP 'href="/projects/videlibri/files/Xidel/Xidel%20[^"]*/"' | grep 'Xidel%20development' | head -n1 | grep -oP '(?<=href=").*(?=")')"
  else
    release_path="$(echo "${dir_html}" | grep -oP 'href="/projects/videlibri/files/Xidel/Xidel%20[^"]*/"' | grep -v 'Xidel%20development' | head -n1 | grep -oP '(?<=href=").*(?=")')"
  fi
  if [[ -z "${release_path}" ]]; then
    echo "error: could not find a ${release_kind} release folder under ${BOXCTL_XIDEL_DIR_URL}" >&2
    exit 1
  fi

  feed_path="${release_path#/projects/videlibri/files}"
  feed_path="${feed_path%/}"
  release_feed="https://sourceforge.net/projects/videlibri/rss?path=${feed_path}"

  feed_xml="$(curl -fsSL "${release_feed}")"
  match="$(echo "${feed_xml}" | grep -m1 -A1 'amd64\.deb\]\]></title>')"
  if [[ -z "${match}" ]]; then
    echo "error: could not find an amd64 .deb release under ${release_feed}" >&2
    exit 1
  fi

  DOWNLOAD_URL="$(echo "${match}" | grep -oP '(?<=<link>).*(?=</link>)')"
  FILENAME="$(echo "${match}" | grep -oP '(?<=<title><!\[CDATA\[).*(?=\]\]></title>)' | grep -oP '[^/]+$')"

  if [[ -z "${DOWNLOAD_URL}" ]] || [[ -z "${FILENAME}" ]]; then
    echo "error: could not parse the release link/filename from ${release_feed}" >&2
    exit 1
  fi

  echo "Latest ${release_kind} amd64 package: ${FILENAME}"

  # The package filename's version segment carries a trailing "-<build>"
  # packaging counter (e.g. "0.9.9-1") that dpkg-deb/dpkg-query never
  # report back (confirmed: an actual installed 0.9.9-1 package reports
  # plain "0.9.9") -- drop it so this matches what INSTALLED_VERSION will
  # read as once installed, without needing to download the .deb just to
  # ask it directly.
  if [[ "${FILENAME}" =~ ^xidel_(.+)-[0-9]+_amd64\.deb$ ]]; then
    AVAILABLE_VERSION="${BASH_REMATCH[1]}"
  else
    echo "error: unexpected package filename '${FILENAME}' (expected 'xidel_<version>-<build>_amd64.deb')." >&2
    exit 1
  fi
}

boxctl::install_xidel_install() {
  echo "Downloading ${DOWNLOAD_URL}..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  # apt-get drops privileges to the _apt user while installing a local file,
  # so it needs to be able to traverse into the temp dir and read the file.
  chmod 755 "${tmp_dir}"

  local deb_path="${tmp_dir}/${FILENAME}"
  curl -fL --progress-bar -o "${deb_path}" "${DOWNLOAD_URL}"
  chmod 644 "${deb_path}"

  echo "Installing ${FILENAME} (version ${AVAILABLE_VERSION})..."
  boxctl::run_as_root apt-get install -y --allow-downgrades "${deb_path}" || {
    echo "error: failed to install '${deb_path}'." >&2
    exit 1
  }
}
