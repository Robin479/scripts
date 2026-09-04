# Runs "$@" directly if already root; otherwise prints a notice naming the
# command and re-runs it via sudo, so the user only sees a password prompt
# for the specific command that actually needs it.
boxctl::run_as_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Root is required to run '$*' -- you may be prompted for your password."
    sudo "$@"
  else
    "$@"
  fi
}
