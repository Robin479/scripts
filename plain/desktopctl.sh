#!/usr/bin/env bash
#
# Save and restore X window positions, e.g. across a compiz restart which
# forgets all window geometries. Relies on `wmctrl`.
#
# Usage: desktopctl.sh <persist-windows|restore-windows|restart-compiz>
#   persist-windows  Persist the geometry of all current windows.
#   restore-windows  Restore previously saved window geometries (skipping any
#                    windows that no longer exist).
#   restart-compiz   persist-windows, replace the running compiz with a
#                    fresh, standalone instance, then restore-windows.

set -euo pipefail

main() {
    parse_args "${@}"
    check_dependencies
    determine_paths

    case "${COMMAND}" in
        persist-windows)
            persist_windows
            ;;
        restore-windows)
            restore_windows
            ;;
        restart-compiz)
            restart_compiz
            ;;
    esac
}

# Sets COMMAND.
parse_args() {
    if [ "${#}" -ne 1 ]; then
        print_usage
        exit 1
    fi

    case "${1}" in
        persist-windows)
            COMMAND="persist-windows"
            ;;
        restore-windows)
            COMMAND="restore-windows"
            ;;
        restart-compiz)
            COMMAND="restart-compiz"
            ;;
        *)
            echo "Error: unknown command '${1}'." >&2
            print_usage
            exit 1
            ;;
    esac
}

print_usage() {
    echo "Usage: ${0} <persist-windows|restore-windows|restart-compiz>" >&2
}

check_dependencies() {
    command -v wmctrl >/dev/null 2>&1 || {
        echo "Error: 'wmctrl' is required but not installed." >&2
        echo "Install it with: sudo apt install wmctrl" >&2
        exit 1
    }

    command -v xprop >/dev/null 2>&1 || {
        echo "Error: 'xprop' is required but not installed." >&2
        echo "Install it with: sudo apt install x11-utils" >&2
        exit 1
    }

    if [ "${COMMAND}" = "restart-compiz" ]; then
        command -v compiz >/dev/null 2>&1 || {
            echo "Error: 'compiz' is required but not installed." >&2
            exit 1
        }
    fi
}

# Sets STATE_FILE and LOG_FILE.
determine_paths() {
    if [ -z "${DISPLAY:-}" ]; then
        echo "Error: \$DISPLAY is not set; are you running this inside an X session?" >&2
        exit 1
    fi

    local suffix="${DISPLAY//:/_}"
    STATE_FILE="/tmp/wmctrl-window-state-${suffix}"
    LOG_FILE="/tmp/compiz-restart-${suffix}.log"
}

persist_windows() {
    read_desktop_geometry
    {
        printf '#VP %s,%s DG %sx%s\n' "${VP_X}" "${VP_Y}" "${DG_W}" "${DG_H}"

        local id desktop x y width height host title
        while read -r id desktop x y width height host title; do
            [ -n "${id}" ] || continue
            printf '%s %s %s %s %s %s %s %s %s\n' \
                "${id}" "${desktop}" "$(is_maximized "${id}")" "${x}" "${y}" "${width}" "${height}" "${host}" "${title}"
        done < <(wmctrl -lG)
    } > "${STATE_FILE}"
    echo "Saved $(grep -vc '^#' "${STATE_FILE}") window position(s) to '${STATE_FILE}'."
}

# Echoes 1 if the window is fully maximized (both vert and horz), 0
# otherwise. A maximized window ignores an absolute `wmctrl -e` move/resize -
# the WM re-snaps it to fill whatever output it considers current - so
# restoring one correctly means unmaximizing, moving, then re-maximizing;
# this is what makes that possible.
is_maximized() {
    local id="${1}" state
    state="$(xprop -id "${id}" _NET_WM_STATE 2>/dev/null)"

    case "${state}" in
        *_NET_WM_STATE_MAXIMIZED_VERT*_NET_WM_STATE_MAXIMIZED_HORZ* | *_NET_WM_STATE_MAXIMIZED_HORZ*_NET_WM_STATE_MAXIMIZED_VERT*)
            echo 1
            ;;
        *)
            echo 0
            ;;
    esac
}

# Compiz implements its "desktop wall" of virtual desktops by physically
# shifting every window's X11 coordinates as the viewport pans, so
# `wmctrl -lG` positions are only meaningful relative to whichever viewport
# happens to be current when it runs.
# Sets DG_W, DG_H, VP_X and VP_Y for the current viewport.
read_desktop_geometry() {
    local desktop marker dg_label dg vp_label vp
    read -r desktop marker dg_label dg vp_label vp _ < <(wmctrl -d | awk '$2 == "*"')

    DG_W="${dg%x*}"
    DG_H="${dg#*x}"
    VP_X="${vp%,*}"
    VP_Y="${vp#*,}"

    [ -n "${DG_W}" ] && [ -n "${DG_H}" ] && [ -n "${VP_X}" ] && [ -n "${VP_Y}" ] || {
        echo "Error: could not determine the current viewport/geometry from 'wmctrl -d'." >&2
        exit 1
    }
}

restore_windows() {
    [ -f "${STATE_FILE}" ] || {
        echo "Error: no saved window state found at '${STATE_FILE}'; run '${0} persist-windows' first." >&2
        exit 1
    }

    local marker vp_field saved_vp_x saved_vp_y
    read -r marker vp_field _ _ < "${STATE_FILE}"
    [ "${marker}" = "#VP" ] || {
        echo "Error: '${STATE_FILE}' is missing its viewport header (from an older save); run '${0} persist-windows' again." >&2
        exit 1
    }
    saved_vp_x="${vp_field%,*}"
    saved_vp_y="${vp_field#*,}"

    local existing_ids
    existing_ids="$(wmctrl -l | awk '{print $1}')"

    local id desktop maximized x y width height host title restored=0 skipped=0
    while read -r id desktop maximized x y width height host title; do
        [ -n "${id}" ] || continue

        if [ "${desktop}" = "-1" ]; then
            # Sticky/shown-on-all-desktops windows (the desktop background,
            # panels) were never meant to be repositioned via saved
            # per-desktop coordinates, and issuing them a synthetic
            # move/resize has been observed to leave the desktop background
            # layer visibly glitched.
            echo "Skipping '${title}' (${id}): sticky/all-desktops window, left alone." >&2
            skipped=$((skipped + 1))
        elif grep -qxF "${id}" <<<"${existing_ids}"; then
            # Checked before every window, not just once up front: `wall`'s
            # `auto_switch_vp_and_window` setting can drift the viewport as
            # a side effect of restoring an earlier window in this same
            # loop, which would silently misapply every saved coordinate
            # after that point if we didn't keep verifying.
            ensure_viewport "${saved_vp_x}" "${saved_vp_y}"

            restore_window "${id}" "${desktop}" "${maximized}" "${x}" "${y}" "${width}" "${height}"
            restored=$((restored + 1))
        else
            echo "Skipping '${title}' (${id}): window no longer exists." >&2
            skipped=$((skipped + 1))
        fi
    done < <(grep -v '^#' "${STATE_FILE}")

    echo "Restored ${restored} window(s), skipped ${skipped}."
}

# Switches the current viewport to the given absolute position only if it's
# not already there, and waits for it to actually take effect (the switch
# can be animated, so it doesn't land instantly) before returning.
ensure_viewport() {
    local target_x="${1}" target_y="${2}"

    read_desktop_geometry
    [ "${VP_X}" = "${target_x}" ] && [ "${VP_Y}" = "${target_y}" ] && return 0

    wmctrl -o "${target_x},${target_y}"

    local attempt
    for attempt in $(seq 1 20); do
        read_desktop_geometry
        [ "${VP_X}" = "${target_x}" ] && [ "${VP_Y}" = "${target_y}" ] && return 0
        sleep 0.5
    done

    echo "Error: viewport did not switch to '${target_x},${target_y}' within 10s (still at '${VP_X},${VP_Y}')." >&2
    exit 1
}

restore_window() {
    local id="${1}" desktop="${2}" maximized="${3}" x="${4}" y="${5}" width="${6}" height="${7}"

    wmctrl -i -r "${id}" -t "${desktop}"
    # A maximized window ignores an absolute move/resize outright - the WM
    # re-snaps it to fill whatever output it considers current, regardless
    # of what's requested. Unmaximizing first, moving, then re-maximizing
    # (if it was maximized to begin with) means the re-maximize snaps to the
    # output matching the position just set, not a stale/wrong one - but
    # only if the unmaximize has genuinely taken effect before the move is
    # issued, hence waiting for it rather than assuming it's instant (an
    # in-flight move issued against still-maximized geometry has been
    # observed to land on the wrong output within an otherwise-correct tile).
    wmctrl -i -r "${id}" -b remove,maximized_vert,maximized_horz
    wait_for_not_maximized "${id}"

    wmctrl -i -r "${id}" -e "0,${x},${y},${width},${height}"

    if [ "${maximized}" = "1" ]; then
        wmctrl -i -r "${id}" -b add,maximized_vert,maximized_horz
    fi
}

# Waits for a window to no longer report itself as maximized, so the
# move/resize that follows isn't clamped against stale maximized geometry.
wait_for_not_maximized() {
    local id="${1}" attempt state
    for attempt in $(seq 1 20); do
        state="$(xprop -id "${id}" _NET_WM_STATE 2>/dev/null)"
        case "${state}" in
            *_NET_WM_STATE_MAXIMIZED_VERT* | *_NET_WM_STATE_MAXIMIZED_HORZ*) ;;
            *) return 0 ;;
        esac
        sleep 0.1
    done

    echo "Error: window ${id} did not unmaximize within 2s." >&2
    exit 1
}

restart_compiz() {
    persist_windows

    local old_pids
    old_pids="$(pgrep -x compiz || true)"

    launch_compiz
    wait_for_old_compiz_to_exit "${old_pids}"
    wait_for_window_manager
    wait_for_viewport_grid

    restore_windows
}

# Starts a fresh, standalone compiz - not merely backgrounded from this
# script, but fully detached from it, the same way a .desktop launcher would.
launch_compiz() {
    echo "Starting a new, standalone compiz instance (log: '${LOG_FILE}')..."
    # setsid alone would only detach compiz from the controlling terminal; it
    # would still be a direct child of this script. Wrapping it in a
    # backgrounded subshell that then immediately exits (double-fork) gets it
    # reparented to init right away, so this script is never its ancestor.
    ( setsid compiz --replace >"${LOG_FILE}" 2>&1 </dev/null & )
}

# Waits for the old compiz to react to `--replace` (losing the X selection
# ownership the new instance just took) and exit on its own. Deliberately
# passive - explicitly SIGTERM-ing the old instance before the new one
# starts was tried and correlated with the new instance ending up in a
# broken, effectively pluginless state, so it was reverted.
wait_for_old_compiz_to_exit() {
    local old_pids="${1}"
    [ -n "${old_pids}" ] || return 0

    local pid
    for pid in ${old_pids}; do
        wait_for_pid_exit "${pid}" || {
            echo "Error: old compiz process ${pid} did not exit within 10s; see '${LOG_FILE}'." >&2
            exit 1
        }
    done
}

wait_for_pid_exit() {
    local pid="${1}" attempt
    for attempt in $(seq 1 20); do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 0.5
    done

    return 1
}

wait_for_window_manager() {
    local attempt
    for attempt in $(seq 1 20); do
        wmctrl -m >/dev/null 2>&1 && return 0
        sleep 0.5
    done

    echo "Error: no window manager became available within 10s; see '${LOG_FILE}'." >&2
    exit 1
}

# compiz's "wall" plugin (the virtual desktop grid) loads well after the
# point wmctrl already reports a responsive window manager; restoring before
# it's done means coordinates get wrapped into a still-too-small canvas and
# every window lands on the first viewport.
wait_for_viewport_grid() {
    local marker vp_field dg_label saved_dg required_w required_h
    read -r marker vp_field dg_label saved_dg < "${STATE_FILE}"
    required_w="${saved_dg%x*}"
    required_h="${saved_dg#*x}"

    local attempt
    for attempt in $(seq 1 20); do
        read_desktop_geometry
        [ "${required_w}" -le "${DG_W}" ] && [ "${required_h}" -le "${DG_H}" ] && return 0
        sleep 0.5
    done

    echo "Error: compiz only reports a ${DG_W}x${DG_H} viewport grid, expected at least ${required_w}x${required_h}; see '${LOG_FILE}'." >&2
    exit 1
}

main "${@}"
