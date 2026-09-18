: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
update="${args[--update]:-}"
version="${args[--version]:-}"
explicit_version="$version"

# --update is shorthand for --version=latest; declaring them as conflicting
# flags in bashly.yml already rejects any other combination of the two
# (e.g. --update --version=1.2.3) before this script ever runs.
[[ -n "$update" ]] && version="latest"

boxctl::install_calibre_check
boxctl::install_calibre_installed_version
boxctl::install_calibre_available_version "$version"

if [[ -z "$version" && -n "$INSTALLED_VERSION" ]]; then
  echo "calibre ${INSTALLED_VERSION} is already installed at /opt/calibre-${INSTALLED_VERSION}."
  if [[ "$INSTALLED_VERSION" != "$AVAILABLE_VERSION" ]]; then
    echo "Version ${AVAILABLE_VERSION} is available -- pass --update (-u) or --version=${AVAILABLE_VERSION} to install it."
  fi
  exit 0
fi

# An explicit --version pin is a deliberate request for *that* version, so
# it reinstalls even if it happens to match what's already there (repair);
# --update converging to an already-current latest is the one case that
# still no-ops (asking for latest when you're already on latest isn't an
# error -- see CLAUDE.md).
if [[ -z "$explicit_version" && "$INSTALLED_VERSION" == "$AVAILABLE_VERSION" ]]; then
  echo "calibre ${AVAILABLE_VERSION} is already installed at ${INSTALL_DIR}."
  exit 0
fi

boxctl::install_calibre_install
echo "calibre ${AVAILABLE_VERSION} installed successfully at ${INSTALL_DIR}."
