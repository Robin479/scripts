: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
update="${args[--update]:-}"
dev="${args[--dev]:-}${args[--development]:-}"

boxctl::install_xidel_check
boxctl::install_xidel_installed_version
boxctl::install_xidel_available_version "$dev"

if [[ -n "$INSTALLED_VERSION" && -z "$update" ]]; then
  echo "xidel ${INSTALLED_VERSION} is already installed."
  if [[ "$INSTALLED_VERSION" != "$AVAILABLE_VERSION" ]]; then
    echo "Version ${AVAILABLE_VERSION} is available -- pass --update (-u) to install it."
  fi
  exit 0
fi

if [[ "$INSTALLED_VERSION" == "$AVAILABLE_VERSION" ]]; then
  echo "xidel ${AVAILABLE_VERSION} is already installed."
  exit 0
fi

boxctl::install_xidel_install
echo "xidel ${AVAILABLE_VERSION} installed successfully."
