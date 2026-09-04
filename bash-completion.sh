#!/usr/bin/env bash
# Source this file (e.g. from ~/.bashrc: `source /path/to/scripts/bash-completion.sh`,
# or symlink it from a directory your own bashrc already sources, such as
# ~/.bash_completion.d/) to enable bash completion for every bashly-generated
# command in this repo that supports it. Each file under bash-completion.d/
# (see `make bash-completions`) does its own check that the command it's for
# actually resolves to this repo's own bin/ before enabling anything.

# Resolved via readlink -f, not just dirname "${BASH_SOURCE[0]}" -- this
# file is meant to be symlinkable from elsewhere (e.g. a bash_completion.d
# directory of the user's own), and BASH_SOURCE reports the symlink's own
# path, not its target, so a plain dirname would look for bash-completion.d/
# next to the symlink instead of next to this file's real location.
_bash_completion_scripts_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bash-completion.d"

for _bash_completion_script in "${_bash_completion_scripts_dir}"/*; do
  # shellcheck disable=SC1090 # dynamic by design -- one generated file per bashly project, see bash-completion.d/.template.sh.in
  [[ -f "${_bash_completion_script}" ]] && source "${_bash_completion_script}"
done

unset _bash_completion_scripts_dir _bash_completion_script
