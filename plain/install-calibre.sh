#!/usr/bin/env bash
#
# Download and install/update calibre from https://download.calibre-ebook.com/
# into /opt/calibre-<version>, then run its postinstall script.
#
# Usage: install-calibre.sh [--version=<X.Y.Z>]
#   --version=<X.Y.Z>   Install this specific version instead of the latest.

set -euo pipefail

BASE_URL="https://download.calibre-ebook.com/"
UNINSTALL_BIN="/usr/bin/calibre-uninstall"

main() {
    parse_args "${@}"
    check_dependencies
    determine_download_url

    if installation_exists; then
        echo "calibre ${VERSION} is already installed at ${INSTALL_DIR}."
        exit 0
    fi

    download_and_extract
    uninstall_old
    install_new

    echo "calibre ${VERSION} installed successfully at ${INSTALL_DIR}."
}

# Sets VERSION_FILTER.
parse_args() {
    VERSION_FILTER=""

    local arg
    for arg in "${@}"; do
        case "${arg}" in
            --version=*)
                VERSION_FILTER="${arg#--version=}"
                ;;
            *)
                echo "Error: unknown argument '${arg}'." >&2
                echo "Usage: ${0} [--version=<X.Y.Z>]" >&2
                exit 1
                ;;
        esac
    done
}

check_dependencies() {
    command -v "xidel" >/dev/null 2>&1 || {
        echo "Error: xidel is required but not installed." >&2
        echo "It is not packaged in the default system repositories; see https://videlibri.sourceforge.net/xidel.html" >&2
        echo "or run install-xidel.sh." >&2
        exit 1
    }

    command -v "expect" >/dev/null 2>&1 || {
        echo "Error: expect is required but not installed. Install it (e.g. 'apt-get install -y expect')." >&2
        exit 1
    }

    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: this script must be run as root." >&2
        exit 1
    fi
}

# Sets DOWNLOAD_URL, FILENAME, VERSION and INSTALL_DIR.
determine_download_url() {
    local series_label series_predicate release_predicate
    series_label=""
    series_predicate="1"
    release_predicate="1"

    if [ -n "${VERSION_FILTER}" ]; then
        echo "Looking up calibre release ${VERSION_FILTER}..."

        # Series pages are named after the major version (e.g. "9.x"), except
        # for legacy releases before 1.0, which are grouped by minor (e.g.
        # "0.9.x").
        local major minor
        major="${VERSION_FILTER%%.*}"
        if [ "${major}" = "0" ]; then
            minor="${VERSION_FILTER#*.}"
            minor="${minor%%.*}"
            series_label="0.${minor}.x"
        else
            series_label="${major}.x"
        fi

        series_predicate="a='${series_label}'"
        release_predicate="a='${VERSION_FILTER}'"
    else
        echo "Looking up latest calibre release..."
    fi

    local series_url release_url

    series_url="$(xidel -s "${BASE_URL}" -e "(//ul/li[${series_predicate}]/a)/resolve-uri(@href)")"
    if [ -z "${series_url}" ]; then
        echo "Error: could not find release series '${series_label:-<latest>}' on ${BASE_URL}" >&2
        exit 1
    fi

    release_url="$(xidel -s "${series_url}" -e "(//ul[@class='release-list']/li[${release_predicate}]/a)/resolve-uri(@href)")"
    if [ -z "${release_url}" ]; then
        echo "Error: could not find release '${VERSION_FILTER:-<latest>}' on ${series_url}" >&2
        exit 1
    fi

    DOWNLOAD_URL="$(xidel -s "${release_url}" -e '(//a[@title="Linux Intel 64-bit binary"])/resolve-uri(@href)')"
    if [ -z "${DOWNLOAD_URL}" ]; then
        echo "Error: could not find the Linux Intel 64-bit binary link on ${release_url}" >&2
        exit 1
    fi

    FILENAME="${DOWNLOAD_URL##*/}"
    if [[ "${FILENAME}" =~ ^calibre-([0-9]+\.[0-9]+\.[0-9]+)-x86_64\.[A-Za-z0-9.]+$ ]]; then
        VERSION="${BASH_REMATCH[1]}"
    else
        echo "Error: unexpected binary filename '${FILENAME}' (expected 'calibre-<version>-x86_64.<ext>')." >&2
        echo "The download page layout may have changed; please check it manually." >&2
        exit 1
    fi

    if [ -n "${VERSION_FILTER}" ]; then
        if [ "${VERSION}" = "${VERSION_FILTER}" ]; then
            :
        else
            echo "Error: resolved version '${VERSION}' does not match requested version '${VERSION_FILTER}'." >&2
            exit 1
        fi
    fi

    INSTALL_DIR="/opt/calibre-${VERSION}"

    echo "Resolved version: ${VERSION}"
}

installation_exists() {
    [ -d "${INSTALL_DIR}" ]
}

# Sets ARCHIVE_PATH.
download_and_extract() {
    echo "Downloading ${DOWNLOAD_URL}..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '${tmp_dir}'" EXIT

    ARCHIVE_PATH="${tmp_dir}/${FILENAME}"
    curl -fL --progress-bar -o "${ARCHIVE_PATH}" "${DOWNLOAD_URL}"

    echo "Extracting to ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"
    tar xf "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"
}

uninstall_old() {
    if [ -e "${UNINSTALL_BIN}" ]; then
        if [ -x "${UNINSTALL_BIN}" ]; then
            echo "Running uninstall of previous calibre version..."
            # calibre-uninstall unconditionally reopens /dev/tty for its [y/n]
            # prompts, ignoring piped stdin entirely; expect gives it a pty of
            # its own so the prompts can be answered automatically.
            local uninstall_status
            if expect -c 'set uninstall_bin "'"${UNINSTALL_BIN}"'"
                set timeout -1
                spawn -noecho $uninstall_bin
                expect {
                    -re {\[y/n\]:} {
                        send "y\r"
                        exp_continue
                    }
                    eof
                }
                catch wait result
                exit [lindex $result 3]
            '; then
                uninstall_status=0
            else
                uninstall_status=$?
            fi
            if [ "${uninstall_status}" -ne 0 ]; then
                echo "Error: '${UNINSTALL_BIN}' failed; aborting before installing the new version." >&2
                exit 1
            fi
        else
            echo "Error: '${UNINSTALL_BIN}' exists but is not executable." >&2
            exit 1
        fi
    fi
}

install_new() {
    local postinstall="${INSTALL_DIR}/calibre_postinstall"
    [ -x "${postinstall}" ] || {
        echo "Error: '${postinstall}' not found or not executable after extraction." >&2
        echo "The archive layout may have changed; please inspect ${INSTALL_DIR} manually." >&2
        exit 1
    }

    echo "Running postinstall..."
    "${postinstall}" || {
        echo "Error: '${postinstall}' failed; calibre ${VERSION} may not be fully installed." >&2
        exit 1
    }
}

main "${@}"
