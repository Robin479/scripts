#!/usr/bin/env bash
#
# Download and install/update xidel from its SourceForge project
# (https://sourceforge.net/projects/videlibri/files/Xidel/), since xidel is
# not packaged in the default system repositories.
#
# Usage: install-xidel.sh [--dev|--development]
#   --dev, --development   Install the latest development snapshot instead
#                           of the latest stable release.

set -euo pipefail

DIR_URL="https://sourceforge.net/projects/videlibri/files/Xidel/"
PACKAGE_NAME="xidel"

main() {
    parse_args "${@}"
    check_dependencies
    determine_download_url
    download_deb

    if up_to_date; then
        echo "xidel ${AVAILABLE_VERSION} is already installed."
        exit 0
    fi

    install_deb

    echo "xidel ${AVAILABLE_VERSION} installed successfully."
}

# Sets INCLUDE_DEV.
parse_args() {
    INCLUDE_DEV="false"

    local arg
    for arg in "${@}"; do
        case "${arg}" in
            --dev|--development)
                INCLUDE_DEV="true"
                ;;
            *)
                echo "Error: unknown argument '${arg}'." >&2
                echo "Usage: ${0} [--dev|--development]" >&2
                exit 1
                ;;
        esac
    done
}

check_dependencies() {
    local cmd
    for cmd in "curl" "dpkg-deb" "dpkg-query" "apt-get"; do
        command -v "${cmd}" >/dev/null 2>&1 || {
            echo "Error: '${cmd}' is required but not installed." >&2
            exit 1
        }
    done

    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: this script must be run as root." >&2
        exit 1
    fi
}

# Sets DOWNLOAD_URL and FILENAME.
determine_download_url() {
    local release_kind
    if [ "${INCLUDE_DEV}" = "true" ]; then
        release_kind="development"
    else
        release_kind="stable (non-development)"
    fi
    echo "Looking up latest ${release_kind} xidel release for amd64..."

    local dir_html release_path feed_path release_feed feed_xml match

    dir_html="$(curl -fsSL "${DIR_URL}")"
    if [ -z "${dir_html}" ]; then
        echo "Error: could not fetch the SourceForge folder listing at ${DIR_URL}" >&2
        exit 1
    fi

    # The listing is sorted newest-first; the "Xidel development" folder is
    # the only place development snapshots live, everything else is stable.
    if [ "${INCLUDE_DEV}" = "true" ]; then
        release_path="$(echo "${dir_html}" | grep -oP 'href="/projects/videlibri/files/Xidel/Xidel%20[^"]*/"' | grep 'Xidel%20development' | head -n1 | grep -oP '(?<=href=").*(?=")')"
    else
        release_path="$(echo "${dir_html}" | grep -oP 'href="/projects/videlibri/files/Xidel/Xidel%20[^"]*/"' | grep -v 'Xidel%20development' | head -n1 | grep -oP '(?<=href=").*(?=")')"
    fi
    if [ -z "${release_path}" ]; then
        echo "Error: could not find a ${release_kind} release folder under ${DIR_URL}" >&2
        exit 1
    fi

    feed_path="${release_path#/projects/videlibri/files}"
    feed_path="${feed_path%/}"
    release_feed="https://sourceforge.net/projects/videlibri/rss?path=${feed_path}"

    feed_xml="$(curl -fsSL "${release_feed}")"
    match="$(echo "${feed_xml}" | grep -m1 -A1 'amd64\.deb\]\]></title>')"
    if [ -z "${match}" ]; then
        echo "Error: could not find an amd64 .deb release under ${release_feed}" >&2
        exit 1
    fi

    DOWNLOAD_URL="$(echo "${match}" | grep -oP '(?<=<link>).*(?=</link>)')"
    FILENAME="$(echo "${match}" | grep -oP '(?<=<title><!\[CDATA\[).*(?=\]\]></title>)' | grep -oP '[^/]+$')"

    if [ -z "${DOWNLOAD_URL}" ] || [ -z "${FILENAME}" ]; then
        echo "Error: could not parse the release link/filename from ${release_feed}" >&2
        exit 1
    fi

    echo "Latest ${release_kind} amd64 package: ${FILENAME}"
}

# Sets DEB_PATH and AVAILABLE_VERSION.
download_deb() {
    echo "Downloading ${DOWNLOAD_URL}..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '${tmp_dir}'" EXIT
    # apt-get drops privileges to the _apt user while installing a local file,
    # so it needs to be able to traverse into the temp dir and read the file.
    chmod 755 "${tmp_dir}"

    DEB_PATH="${tmp_dir}/${FILENAME}"
    curl -fL --progress-bar -o "${DEB_PATH}" "${DOWNLOAD_URL}"
    chmod 644 "${DEB_PATH}"

    AVAILABLE_VERSION="$(dpkg-deb -f "${DEB_PATH}" Version)"
    if [ -z "${AVAILABLE_VERSION}" ]; then
        echo "Error: could not read the Version field from '${DEB_PATH}'." >&2
        exit 1
    fi
}

up_to_date() {
    local installed_version
    installed_version="$(dpkg-query -W -f='${Version}' "${PACKAGE_NAME}" 2>/dev/null || true)"
    [ "${installed_version}" = "${AVAILABLE_VERSION}" ]
}

install_deb() {
    echo "Installing ${FILENAME} (version ${AVAILABLE_VERSION})..."
    apt-get install -y --allow-downgrades "${DEB_PATH}" || {
        echo "Error: failed to install '${DEB_PATH}'." >&2
        exit 1
    }
}

main "${@}"
