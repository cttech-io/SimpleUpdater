#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

# ── Options ──────────────────────────────────────────────────────────────────
ASSUME_YES=0
REPORT_ONLY=0

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

  -y, --yes       Don't prompt; apply the safe subset (packages, snap, flatpak).
                  Firmware, reboots, orphan removal and service-stack upgrades
                  are still skipped — they need a human.
  -n, --report    Report what's available; change nothing.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)    ASSUME_YES=1 ;;
        -n|--report) REPORT_ONLY=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Linux" ]]; then
    fail "This is the Linux updater — on macOS run macos-updater.sh instead."
    exit 1
fi

# ── Privilege escalation ─────────────────────────────────────────────────────
SUDO=""
if [[ $EUID -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
        # Cache credentials up front so a password prompt can't ambush the run
        # halfway through an upgrade. Report mode needs root too — refreshing
        # package metadata writes to /var/lib.
        if ! sudo -n true 2>/dev/null; then
            if [[ -t 0 ]]; then
                header "Requesting sudo access"
                sudo -v
            else
                fail "sudo needs a password but there's no terminal to ask on."
                note "Configure passwordless sudo for unattended use."
                exit 1
            fi
        fi
    else
        fail "Not root and sudo is not installed — cannot apply updates."
        exit 1
    fi
fi

# ── Host identification ──────────────────────────────────────────────────────
DISTRO="unknown"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${PRETTY_NAME:-${NAME:-unknown}}"
fi

# ── Package manager detection ────────────────────────────────────────────────
# Never assume apt — pick whichever native manager this host actually has.
PKG_MGR=""
for candidate in apt-get dnf yum pacman zypper apk; do
    if command -v "$candidate" &>/dev/null; then
        PKG_MGR="$candidate"
        break
    fi
done

# Every section is individually guarded, but if something unforeseen still
# kills the run, print what was accomplished rather than exiting silently.
# print_summary only ever prints once, so the normal path is unaffected.
trap print_summary EXIT

banner "Linux Updater" "$(hostname -s) · ${DISTRO} · $(uname -m)"
if [[ -n "$PKG_MGR" ]]; then
    note "  Package manager: ${PKG_MGR}"
else
    note "  Package manager: none detected"
fi
(( REPORT_ONLY )) && note "  Report-only mode — nothing will be changed."

# ── Native packages ──────────────────────────────────────────────────────────
# Each manager needs: refresh metadata, count pending, upgrade, clean cache.
pkg_refresh() {
    case "$PKG_MGR" in
        apt-get) $SUDO apt-get update -qq ;;
        dnf|yum) $SUDO "$PKG_MGR" -q makecache ;;
        pacman)  command -v checkupdates &>/dev/null || $SUDO pacman -Sy --noconfirm ;;
        zypper)  $SUDO zypper --non-interactive refresh ;;
        apk)     $SUDO apk update ;;
    esac
}

pkg_pending() {
    case "$PKG_MGR" in
        # -s is a simulation: every pending package shows as an "Inst" line.
        apt-get) apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true ;;
        # check-update exits 100 when updates exist, so tolerate non-zero.
        # Run as root against the cache pkg_refresh just built: as a normal
        # user dnf5 uses a per-user cache and can stop at a hidden GPG key
        # prompt. Only count "name.arch version repo" rows, not dnf5's
        # "Upgrades" header.
        dnf|yum) { $SUDO "$PKG_MGR" -q check-update </dev/null 2>/dev/null || true; } | awk 'NF>=3 && $1 ~ /\./' | grep -c . || true ;;
        pacman)  if command -v checkupdates &>/dev/null; then checkupdates 2>/dev/null | grep -c . || true
                 else pacman -Qu 2>/dev/null | grep -c . || true; fi ;;
        zypper)  zypper --quiet list-updates 2>/dev/null | grep -c '^v ' || true ;;
        apk)     apk list -u 2>/dev/null | grep -c . || true ;;
        *)       echo 0 ;;
    esac
}

pkg_list_pending() {
    case "$PKG_MGR" in
        apt-get) apt-get -s upgrade 2>/dev/null | awk '/^Inst /{print $2}' ;;
        dnf|yum) { $SUDO "$PKG_MGR" -q check-update </dev/null 2>/dev/null || true; } | awk 'NF>=3 && $1 ~ /\./{print $1}' ;;
        pacman)  if command -v checkupdates &>/dev/null; then checkupdates 2>/dev/null; else pacman -Qu 2>/dev/null; fi ;;
        zypper)  zypper --quiet list-updates 2>/dev/null | awk -F'|' '/^v /{gsub(/ /,"",$3); print $3}' ;;
        apk)     apk list -u 2>/dev/null | awk '{print $1}' ;;
    esac
}

pkg_upgrade() {
    case "$PKG_MGR" in
        apt-get)
            if (( ASSUME_YES )); then
                # Keep existing config files rather than stopping on a conffile
                # prompt, and have needrestart only *list* affected services
                # (mode 'l') — silently bouncing a service on a live host isn't
                # something an updater should decide.
                DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l $SUDO apt-get -y \
                    -o Dpkg::Options::=--force-confdef \
                    -o Dpkg::Options::=--force-confold upgrade
            else
                $SUDO apt-get upgrade
            fi ;;
        dnf|yum)
            if (( ASSUME_YES )); then $SUDO "$PKG_MGR" -y upgrade
            else $SUDO "$PKG_MGR" upgrade; fi ;;
        pacman)
            if (( ASSUME_YES )); then $SUDO pacman -Syu --noconfirm
            else $SUDO pacman -Syu; fi ;;
        zypper)
            if (( ASSUME_YES )); then $SUDO zypper --non-interactive update
            else $SUDO zypper update; fi ;;
        apk)     $SUDO apk upgrade ;;
    esac
}

pkg_clean() {
    case "$PKG_MGR" in
        apt-get) $SUDO apt-get -qq autoclean ;;
        dnf|yum) $SUDO "$PKG_MGR" -q clean packages ;;
        pacman)  $SUDO pacman -Sc --noconfirm ;;
        zypper)  $SUDO zypper --non-interactive clean ;;
        apk)     $SUDO apk cache clean 2>/dev/null || true ;;
    esac
}

if [[ -n "$PKG_MGR" ]]; then
    T=$SECONDS
    header "Refreshing ${PKG_MGR} package list"
    if pkg_refresh; then
        success "Package list refreshed"
    else
        # A single unreachable mirror shouldn't end the run — carry on and
        # report against whatever metadata we already have.
        warn "Package list refresh reported an error — continuing with cached metadata"
        sum_warn "${PKG_MGR}: metadata refresh failed"
    fi

    PKG_COUNT=$(pkg_pending)
    PKG_COUNT=${PKG_COUNT:-0}

    if (( PKG_COUNT == 0 )); then
        skip "No package updates available"
        sum_ok "${PKG_MGR}: already up to date  ${DIM}($(section_time $T))${RESET}"
    else
        header "${PKG_COUNT} package(s) pending"
        pkg_list_pending | sed 's/^/    /'

        if (( REPORT_ONLY )); then
            sum_warn "${PKG_MGR}: ${BOLD}${PKG_COUNT}${RESET} package(s) pending  ${DIM}($(section_time $T))${RESET}"
        else
            header "Upgrading packages"
            if pkg_upgrade; then
                success "Packages upgraded"
                header "Cleaning package cache"
                pkg_clean
                success "Package cache cleaned"
                sum_ok "${PKG_MGR}: ${BOLD}${PKG_COUNT}${RESET} package(s) upgraded  ${DIM}($(section_time $T))${RESET}"
            else
                fail "Package upgrade reported an error"
                sum_fail "${PKG_MGR}: upgrade failed  ${DIM}($(section_time $T))${RESET}"
            fi
        fi
    fi
else
    skip "No supported package manager found — skipping native packages"
    sum_skip "No native package manager detected"
fi

# ── Orphaned packages ────────────────────────────────────────────────────────
# Deliberately prompt-only and excluded from --yes: autoremove has form for
# taking libraries that something outside the package graph still needs.
if [[ "$PKG_MGR" == "apt-get" ]] && (( ! REPORT_ONLY )); then
    ORPHANS=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}')
    ORPHAN_COUNT=$(count_lines "$ORPHANS")
    if (( ORPHAN_COUNT > 0 )); then
        header "${ORPHAN_COUNT} orphaned package(s) could be removed"
        echo "$ORPHANS" | sed 's/^/    /'
        warn "Read this list before agreeing — autoremove can take libraries"
        warn "that AppImages and other non-packaged software still depend on."
        if [[ "${ASSUME_YES}" == "1" ]]; then
            skip "Orphan removal skipped (needs a human, even with --yes)"
            sum_skip "${BOLD}${ORPHAN_COUNT}${RESET} orphaned package(s) not removed"
        elif confirm "Remove these orphaned packages?"; then
            if $SUDO apt-get -y autoremove; then
                success "Orphaned packages removed"
                sum_ok "${BOLD}${ORPHAN_COUNT}${RESET} orphaned package(s) removed"
            else
                fail "Orphan removal reported an error"
                sum_fail "Orphan removal failed"
            fi
        else
            skip "Orphaned packages kept"
            sum_skip "${BOLD}${ORPHAN_COUNT}${RESET} orphaned package(s) kept"
        fi
    fi
fi

# ── Snap ─────────────────────────────────────────────────────────────────────
if command -v snap &>/dev/null; then
    T=$SECONDS
    header "Checking snap packages"
    SNAP_PENDING=$(snap refresh --list 2>/dev/null | awk 'NR>1 {print $1}' || true)
    SNAP_COUNT=$(count_lines "$SNAP_PENDING")

    if (( SNAP_COUNT == 0 )); then
        skip "Snaps up to date"
        sum_ok "snap: already up to date  ${DIM}($(section_time $T))${RESET}"
    else
        echo "$SNAP_PENDING" | sed 's/^/    /'
        if (( REPORT_ONLY )); then
            sum_warn "snap: ${BOLD}${SNAP_COUNT}${RESET} pending  ${DIM}($(section_time $T))${RESET}"
        else
            if $SUDO snap refresh; then
                success "Snaps refreshed"
                sum_ok "snap: ${BOLD}${SNAP_COUNT}${RESET} refreshed  ${DIM}($(section_time $T))${RESET}"
            else
                fail "Snap refresh reported an error"
                sum_fail "snap: refresh failed  ${DIM}($(section_time $T))${RESET}"
            fi
        fi
    fi
fi

# ── Flatpak ──────────────────────────────────────────────────────────────────
if command -v flatpak &>/dev/null; then
    T=$SECONDS
    header "Checking flatpaks"

    # flatpak keeps two separate installations: system-wide and per-user. A
    # plain `flatpak update` run as a normal user tries to do both, and the
    # system half asks polkit for authorisation — which nothing can answer over
    # SSH, so it dies with "Deploy not allowed for user". Drive each scope
    # explicitly with the privileges it actually needs.
    FLAT_USER=$(flatpak remote-ls --updates --user --columns=application 2>/dev/null || true)
    FLAT_SYS=$(flatpak remote-ls --updates --system --columns=application 2>/dev/null || true)
    FLAT_USER_COUNT=$(count_lines "$FLAT_USER")
    FLAT_SYS_COUNT=$(count_lines "$FLAT_SYS")
    FLAT_COUNT=$(( FLAT_USER_COUNT + FLAT_SYS_COUNT ))

    if (( FLAT_COUNT == 0 )); then
        skip "Flatpaks up to date"
        sum_ok "flatpak: already up to date  ${DIM}($(section_time $T))${RESET}"
    else
        if (( FLAT_USER_COUNT > 0 )); then
            note "  user installation:"
            echo "$FLAT_USER" | sed 's/^/    /'
        fi
        if (( FLAT_SYS_COUNT > 0 )); then
            note "  system installation:"
            echo "$FLAT_SYS" | sed 's/^/    /'
        fi

        if (( REPORT_ONLY )); then
            sum_warn "flatpak: ${BOLD}${FLAT_COUNT}${RESET} pending (${FLAT_USER_COUNT} user, ${FLAT_SYS_COUNT} system)  ${DIM}($(section_time $T))${RESET}"
        else
            FLAT_FAILED=0
            if (( FLAT_USER_COUNT > 0 )); then
                header "Updating user flatpaks"
                if flatpak update -y --user; then
                    success "User flatpaks updated"
                else
                    fail "User flatpak update reported an error"
                    FLAT_FAILED=1
                fi
            fi
            if (( FLAT_SYS_COUNT > 0 )); then
                header "Updating system flatpaks"
                if $SUDO flatpak update -y --system; then
                    success "System flatpaks updated"
                else
                    fail "System flatpak update reported an error"
                    FLAT_FAILED=1
                fi
            fi

            if (( FLAT_FAILED )); then
                sum_fail "flatpak: update failed  ${DIM}($(section_time $T))${RESET}"
            else
                sum_ok "flatpak: ${BOLD}${FLAT_COUNT}${RESET} updated (${FLAT_USER_COUNT} user, ${FLAT_SYS_COUNT} system)  ${DIM}($(section_time $T))${RESET}"
            fi
        fi
    fi
fi

# ── Firmware ─────────────────────────────────────────────────────────────────
# Report always, apply only on an explicit yes — a bad flash on a remote host
# is unrecoverable over SSH, so --yes never applies firmware.
if command -v fwupdmgr &>/dev/null; then
    header "Checking firmware"
    fwupdmgr refresh --force &>/dev/null || true
    # get-updates exits 0 when something is upgradable, 2 when nothing is —
    # more reliable than matching its prose, which lists "no updates" devices
    # even when other devices do have updates.
    FW=""
    FW_RC=0
    FW=$(fwupdmgr get-updates 2>/dev/null) || FW_RC=$?
    if (( FW_RC != 0 )); then
        skip "No firmware updates"
    elif [[ -n "$FW" ]]; then
        echo "$FW" | sed 's/^/    /'
        if (( REPORT_ONLY )) || [[ "${ASSUME_YES}" == "1" ]]; then
            sum_warn "Firmware updates available (not applied)"
        elif confirm "Apply firmware updates? This may require a reboot."; then
            if $SUDO fwupdmgr update; then
                sum_ok "Firmware updated"
            else
                fail "Firmware update reported an error"
                sum_fail "Firmware update failed"
            fi
        else
            sum_skip "Firmware updates available (skipped)"
        fi
    fi
fi

# ── Docker service stacks (report only) ──────────────────────────────────────
# Pinned stacks are never pulled automatically: a `pull` can cross a major
# version with breaking schema or config changes. Report, then read the
# release notes before deciding.
if command -v docker &>/dev/null; then
    header "Docker containers (report only)"
    if DOCKER_PS=$($SUDO docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null); then
        if [[ -n "$DOCKER_PS" ]]; then
            printf '%s\n' "$DOCKER_PS" | column -t -s $'\t' 2>/dev/null | sed 's/^/    /' \
                || printf '%s\n' "$DOCKER_PS" | sed 's/^/    /'
            DOCKER_COUNT=$(count_lines "$DOCKER_PS")
            note "Not upgraded automatically — check release notes before pulling."
            sum_warn "Docker: ${BOLD}${DOCKER_COUNT}${RESET} container(s) running (upgrade manually)"
        else
            skip "No running containers"
        fi
    else
        skip "Docker present but not queryable by this user"
    fi
fi

# ── Pi-hole ──────────────────────────────────────────────────────────────────
if command -v pihole &>/dev/null; then
    T=$SECONDS
    header "Pi-hole"
    pihole -v 2>/dev/null | sed 's/^/    /' || true

    if (( REPORT_ONLY )); then
        sum_warn "Pi-hole: version shown above (not updated)"
    else
        # Gravity is routine maintenance Pi-hole schedules for itself weekly,
        # so it's in the safe subset. `pihole -up` changes the Pi-hole version
        # itself and stays prompt-only.
        header "Updating Pi-hole gravity (blocklists)"
        if $SUDO pihole -g; then
            success "Gravity updated"
            sum_ok "Pi-hole: gravity updated  ${DIM}($(section_time $T))${RESET}"
        else
            fail "Gravity update failed"
            sum_fail "Pi-hole: gravity update failed"
        fi

        if [[ "${ASSUME_YES}" == "1" ]]; then
            sum_skip "Pi-hole: version upgrade skipped (needs a human, even with --yes)"
        elif confirm "Run 'pihole -up' to upgrade Pi-hole itself?"; then
            if $SUDO pihole -up; then
                sum_ok "Pi-hole: upgraded"
            else
                fail "Pi-hole upgrade reported an error"
                sum_fail "Pi-hole: upgrade failed"
            fi
        fi
    fi
fi

# ── Reboot required ──────────────────────────────────────────────────────────
header "Checking whether a reboot is required"
REBOOT_NEEDED=0
REBOOT_REASON=""

if [[ -f /var/run/reboot-required ]]; then
    REBOOT_NEEDED=1
    if [[ -r /var/run/reboot-required.pkgs ]]; then
        REBOOT_REASON=$(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')
    fi
elif command -v needs-restarting &>/dev/null; then
    # dnf's needs-restarting -r exits 1 when a reboot is needed.
    needs-restarting -r &>/dev/null || REBOOT_NEEDED=1
else
    # Fallback: the newest installed kernel isn't the one we booted.
    NEWEST_KERNEL=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1 || true)
    RUNNING_KERNEL=$(uname -r)
    if [[ -n "$NEWEST_KERNEL" && "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]]; then
        REBOOT_NEEDED=1
        REBOOT_REASON="kernel ${NEWEST_KERNEL} installed, running ${RUNNING_KERNEL}"
    fi
fi

if (( REBOOT_NEEDED )); then
    warn "Reboot required"
    [[ -n "$REBOOT_REASON" ]] && note "  ${REBOOT_REASON}"
    if (( REPORT_ONLY )) || [[ "${ASSUME_YES}" == "1" ]]; then
        sum_warn "${BOLD}Reboot required${RESET} (not rebooted)"
    elif confirm "Reboot now?"; then
        sum_warn "${BOLD}Rebooting${RESET}"
        print_summary
        $SUDO reboot
        exit 0
    else
        sum_warn "${BOLD}Reboot required${RESET} (deferred)"
    fi
else
    success "No reboot required"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
print_summary
