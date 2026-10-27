#!/bin/sh
# Self-contained installer for the 'update' Linux maintenance command.
# Publish this ONE file at an HTTPS raw-text URL, then run:
#   curl -fsSL https://example.org/install.sh | sh
# Do not use `sudo sh` for the entire download: this installer invokes sudo/doas
# only to place the checked payload into privileged directories.
set -eu

VERSION=1.0.0
INSTALL_DIR=${UPDATE_INSTALL_DIR:-/usr/local/bin}
CONFIG_DIR=${UPDATE_CONFIG_DIR:-/etc/update}
DEST=$INSTALL_DIR/update
ALLOWLIST=$CONFIG_DIR/compose-dirs
PAYLOAD_SHA256=1bcef39231ef4556845f95ba7e1a092136bb7f5438146602a2674a1677bcd37c
STAGE=
WORKDIR=

say() { printf '[update-install] %s\n' "$*"; }
err() { printf '[update-install] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    elif have doas; then
        doas "$@"
    else
        err 'Root access required. Install sudo/doas, or run this installer as root.'
    fi
}
cleanup() {
    if [ -n "$STAGE" ]; then as_root rm -f "$STAGE" || :; fi
    if [ -n "$WORKDIR" ]; then rm -rf "$WORKDIR"; fi
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

case "$INSTALL_DIR" in /*) ;; *) err 'UPDATE_INSTALL_DIR must be absolute.' ;; esac
case "$CONFIG_DIR" in /*) ;; *) err 'UPDATE_CONFIG_DIR must be absolute.' ;; esac
[ ! -L "$INSTALL_DIR" ] || err "Refusing symlinked install directory: $INSTALL_DIR"
[ ! -L "$CONFIG_DIR" ] || err "Refusing symlinked config directory: $CONFIG_DIR"

# Never overwrite another program that happens to be called `update`.
if [ -L "$DEST" ]; then
    err "Refusing to replace symlink: $DEST"
fi
if [ -e "$DEST" ]; then
    [ -f "$DEST" ] || err "Existing path is not a regular file: $DEST"
    if ! grep -Fxq '# update - Unified Linux package and opt-in Docker Compose updater.' "$DEST"; then
        err "Existing $DEST is not our updater. Refusing to overwrite it."
    fi
fi
# A second update executable elsewhere in PATH can cause ambiguous invocation.
RESOLVED=$(command -v update 2>/dev/null || true)
if [ -n "$RESOLVED" ] && [ "$RESOLVED" != "$DEST" ]; then
    err "Another 'update' command resolves to $RESOLVED; choose a different name or inspect PATH."
fi

have sha256sum || err 'sha256sum is required to verify the bundled updater.'
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/update-installer.XXXXXXXX") || err 'mktemp failed.'
PAYLOAD=$WORKDIR/update
cat > "$PAYLOAD" <<'__UPDATE_PAYLOAD_75B3A1__'
#!/bin/sh
# update - Unified Linux package and opt-in Docker Compose updater.
# Requires: POSIX /bin/sh. Does not reboot, prune Docker, or change OS releases.
set -u

VERSION=1.0.0
INSTALL_PATH=/usr/local/bin/update
COMPOSE_DIRS=/etc/update/compose-dirs
CHECK=0
YES=0
MODE=normal
ERRORS=0
DOCKER_ACCESS=

log()  { printf '[update] %s\n' "$*"; }
warn() { printf '[update] WARNING: %s\n' "$*" >&2; }
die()  { printf '[update] ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n[update] === %s ===\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    elif have doas; then
        doas "$@"
    else
        warn 'Administrator access required, but neither sudo nor doas exists.'
        return 1
    fi
}

usage() {
    cat <<'EOF'
update - Unified Linux updater (v1.0.0)

Usage:
  update                 Update OS packages + Flatpak/Snap/Homebrew; show Docker status
  update --check         Check available updates + Docker state; change no installed packages
  update --docker        Update allowlisted, *already running* Docker Compose services only
  update --check --docker  Inspect Docker without changing containers/images
  update --all           Update OS/packages + allowlisted Docker Compose projects
  update --all --yes     Noninteractive, including Compose redeployments (use with care)
  update --yes           Approve package manager prompts; Docker still status-only
  update --install       Install to /usr/local/bin/update (refuses to overwrite)
  update --help          Show this help

Compose allowlist: /etc/update/compose-dirs (one absolute directory per line)
Notes:
  --check can refresh metadata caches, but never installs packages or pulls images.
  Docker --check does NOT query registries for remote image updates.
  --docker and --all may restart selected running containers.
  No auto reboot, Docker prune, or cross-release OS upgrades are performed.
EOF
}

install_self() {
    [ -f "$0" ] || die 'Save the script to a file before using --install.'
    [ -e "$INSTALL_PATH" ] && die "$INSTALL_PATH already exists; will not overwrite it."
    [ -L "$INSTALL_PATH" ] && die "$INSTALL_PATH is a symlink; will not overwrite it."
    existing=$(command -v update 2>/dev/null || true)
    if [ -n "$existing" ]; then
        die "An 'update' command already resolves to '$existing'. Inspect it before installing."
    fi
    as_root mkdir -p /usr/local/bin || die 'Could not create /usr/local/bin.'
    as_root install -m 755 "$0" "$INSTALL_PATH" || die 'Installation failed.'
    if [ ! -e "$COMPOSE_DIRS" ]; then
        as_root mkdir -p /etc/update || die 'Could not create /etc/update.'
        printf '# Absolute paths to managed Docker Compose project directories\n# /opt/uptime-kuma\n' |
            as_root tee "$COMPOSE_DIRS" >/dev/null || die 'Could not create Compose allowlist.'
        as_root chmod 644 "$COMPOSE_DIRS" || die 'Could not set allowlist permissions.'
    fi
    log "Installed: $INSTALL_PATH"
    log "Compose allowlist: $COMPOSE_DIRS"
    case ":${PATH:-}:" in
        *:/usr/local/bin:*) ;;
        *) warn '/usr/local/bin is not in this shell PATH. Add it to PATH or call /usr/local/bin/update.' ;;
    esac
}

# Parse arguments. --install is intentionally exclusive.
INSTALL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --version) printf '%s\n' "$VERSION"; exit 0 ;;
        --install) INSTALL=1 ;;
        --check) CHECK=1 ;;
        -y|--yes) YES=1 ;;
        --docker)
            [ "$MODE" = normal ] || die '--docker and --all are mutually exclusive.'
            MODE=docker ;;
        --all)
            [ "$MODE" = normal ] || die '--docker and --all are mutually exclusive.'
            MODE=all ;;
        *) die "Unknown option: $1 (try --help)." ;;
    esac
    shift
done
if [ "$INSTALL" -eq 1 ]; then
    [ "$CHECK" -eq 0 ] && [ "$YES" -eq 0 ] && [ "$MODE" = normal ] ||
        die '--install cannot be combined with other operations.'
    install_self
    exit 0
fi

# Exit without an interactive prompt if stdin cannot be used for confirmation.
confirm() {
    if [ "$YES" -eq 1 ]; then return 0; fi
    if [ ! -t 0 ]; then
        warn "No interactive terminal for: $1. Use --yes to authorize it."
        return 1
    fi
    printf '[update] %s [y/N] ' "$1"
    IFS= read -r answer || return 1
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

identify_os() {
    [ -r /etc/os-release ] || { warn '/etc/os-release unavailable'; return 1; }
    # os-release is a trusted OS-provided shell-compatible variables file.
    . /etc/os-release
    OS_NAME=${PRETTY_NAME:-${ID:-Linux}}
    if [ -e /run/ostree-booted ]; then
        FAMILY=ostree
        return 0
    fi
    case "${ID:-}" in
        debian|ubuntu|linuxmint|raspbian|pop|elementary|kali|devuan|neon|zorin)
            FAMILY=apt ;;
        fedora|rhel|centos|rocky|almalinux|ol|amzn)
            FAMILY=dnf ;;
        arch|manjaro|endeavouros|garuda|artix)
            FAMILY=pacman ;;
        opensuse-tumbleweed|opensuse-slowroll)
            FAMILY=tumbleweed ;;
        opensuse-microos|opensuse-aeon|opensuse-kalpa|sle-micro|nixos)
            FAMILY=unsupported ;;
        opensuse*|sles|sled)
            FAMILY=zypper ;;
        alpine)
            FAMILY=apk ;;
        *)
            case " ${ID_LIKE:-} " in
                *' debian '*|*' ubuntu '*) FAMILY=apt ;;
                *' fedora '*|*' rhel '*) FAMILY=dnf ;;
                *' arch '*) FAMILY=pacman ;;
                *' suse '*) FAMILY=zypper ;;
                *) FAMILY=unsupported ;;
            esac ;;
    esac
    return 0
}

choose_dnf() {
    if have dnf5; then PKG=dnf5
    elif have dnf; then PKG=dnf
    elif have yum; then PKG=yum
    else warn 'DNF/YUM not found'; return 1
    fi
}

system_packages() {
    section "OS packages: $OS_NAME ($FAMILY)"
    case "$FAMILY" in
        apt)
            have apt-get || { warn 'apt-get not found'; return 1; }
            if [ "$CHECK" -eq 1 ]; then
                log 'APT available upgrades (current local metadata; may be stale):'
                if have apt; then apt list --upgradable 2>/dev/null || return 1
                else apt-get -s upgrade || return 1; fi
            else
                as_root apt-get update || return 1
                if [ "$YES" -eq 1 ]; then
                    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade || return 1
                else
                    as_root apt-get upgrade || return 1
                fi
            fi ;;
        dnf)
            choose_dnf || return 1
            if [ "$CHECK" -eq 1 ]; then
                if [ "$PKG" = dnf5 ]; then
                    "$PKG" check-upgrade
                else
                    "$PKG" check-update
                fi
                status=$?
                [ "$status" -eq 0 ] || [ "$status" -eq 100 ] || return "$status"
            elif [ "$PKG" = yum ]; then
                if [ "$YES" -eq 1 ]; then as_root yum -y upgrade || return 1
                else as_root yum upgrade || return 1; fi
            else
                if [ "$YES" -eq 1 ]; then as_root "$PKG" -y upgrade --refresh || return 1
                else as_root "$PKG" upgrade --refresh || return 1; fi
            fi ;;
        pacman)
            have pacman || { warn 'pacman not found'; return 1; }
            if [ "$CHECK" -eq 1 ]; then
                if have checkupdates; then
                    log 'checkupdates uses an isolated package database:'
                    checkupdates
                    status=$?
                    [ "$status" -eq 0 ] || [ "$status" -eq 2 ] || return "$status"
                else
                    log 'Installed sync database (may be stale; install pacman-contrib for checkupdates):'
                    pacman -Qu || return 1
                fi
            elif [ "$YES" -eq 1 ]; then
                as_root pacman -Syu --noconfirm || return 1
            else
                as_root pacman -Syu || return 1
            fi ;;
        zypper|tumbleweed)
            have zypper || { warn 'zypper not found'; return 1; }
            if [ "$CHECK" -eq 1 ]; then
                if [ "$FAMILY" = tumbleweed ]; then
                    log 'Tumbleweed distribution-upgrade preview:'
                    zypper --non-interactive dup --dry-run || return 1
                else
                    zypper --non-interactive list-updates || return 1
                fi
            else
                as_root zypper --non-interactive refresh || return 1
                action=update
                [ "$FAMILY" = tumbleweed ] && action=dup
                if [ "$YES" -eq 1 ]; then
                    as_root zypper --non-interactive "$action" || return 1
                else
                    as_root zypper "$action" || return 1
                fi
            fi ;;
        apk)
            have apk || { warn 'apk not found'; return 1; }
            if [ "$CHECK" -eq 1 ]; then
                log 'Available Alpine packages (local metadata may be stale):'
                apk version -l '<' || return 1
            else
                as_root apk update || return 1
                # apk-tools v2 and v3 differ in interactive flags; plain upgrade
                # is supported in both and is noninteractive by default.
                as_root apk upgrade || return 1
            fi ;;
        ostree)
            have rpm-ostree || { warn 'rpm-ostree not found'; return 1; }
            if [ "$CHECK" -eq 1 ]; then
                rpm-ostree upgrade --check || return 1
            else
                as_root rpm-ostree upgrade || return 1
                log 'New deployment (if any) becomes active after a manual reboot.'
            fi ;;
        unsupported)
            warn "Unsupported/transactional OS; refusing automatic system upgrade on $OS_NAME."
            return 1 ;;
    esac
    return 0
}

# Update the current invoking user's apps and the default system Flatpak installation.
flatpak_packages() {
    have flatpak || return 0
    section Flatpak
    for scope in system user; do
        if [ "$scope" = user ] && [ "$(id -u)" -eq 0 ]; then
            log 'Skip root account user Flatpaks.'
            continue
        fi
        installed=$(flatpak list "--$scope" --columns=ref 2>/dev/null) || {
            warn "Flatpak $scope installation could not be queried."
            return 1
        }
        [ -n "$installed" ] || { log "No $scope Flatpaks installed."; continue; }
        if [ "$CHECK" -eq 1 ]; then
            flatpak remote-ls "--$scope" --updates || return 1
        elif [ "$scope" = system ]; then
            if [ "$YES" -eq 1 ]; then as_root flatpak update --system -y || return 1
            else as_root flatpak update --system || return 1; fi
        else
            if [ "$YES" -eq 1 ]; then flatpak update --user -y || return 1
            else flatpak update --user || return 1; fi
        fi
    done
}

snap_packages() {
    have snap || return 0
    section Snap
    if [ "$CHECK" -eq 1 ]; then
        snap refresh --list || return 1
    else
        # snap refresh is noninteractive; updates may restart Snap-managed services.
        as_root snap refresh || return 1
    fi
}

brew_packages() {
    have brew || return 0
    section Homebrew
    if [ "$(id -u)" -eq 0 ]; then
        warn 'Homebrew must not run as root; skip it. Run update as your normal user.'
        return 0
    fi
    if [ "$CHECK" -eq 1 ]; then
        brew outdated || return 1
    else
        HOMEBREW_NO_INSTALL_CLEANUP=1 brew update || return 1
        HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade || return 1
    fi
}

# Docker commands run as the current user if possible, otherwise via sudo/doas.
get_docker_access() {
    have docker || { warn 'Docker CLI not installed.'; return 1; }
    if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        DOCKER_ACCESS=user
    elif [ "$(id -u)" -ne 0 ] && as_root docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        DOCKER_ACCESS=root
    else
        warn 'Docker daemon unavailable or current user lacks access.'
        return 1
    fi
    if ! docker_cmd compose version >/dev/null 2>&1; then
        warn 'Docker Compose v2 plugin missing or inaccessible.'
        return 1
    fi
}
docker_cmd() {
    if [ "$DOCKER_ACCESS" = root ]; then as_root docker "$@"
    else docker "$@"; fi
}

check_allowlist() {
    if [ ! -f "$COMPOSE_DIRS" ]; then
        warn "Allowlist missing: $COMPOSE_DIRS (run update --install, then edit it)."
        return 1
    fi
    if [ -L "$COMPOSE_DIRS" ]; then
        warn 'Refusing symlinked Compose allowlist.'
        return 1
    fi
    if have stat; then
        owner=$(stat -c %u "$COMPOSE_DIRS" 2>/dev/null || true)
        [ -z "$owner" ] || [ "$owner" = 0 ] || {
            warn 'Compose allowlist must be owned by root.'
            return 1
        }
    fi
    if [ -n "$(find "$COMPOSE_DIRS" -perm /022 -print 2>/dev/null)" ]; then
        warn 'Compose allowlist may not be group/world writable.'
        return 1
    fi
    [ -r "$COMPOSE_DIRS" ] || { warn 'Compose allowlist not readable.'; return 1; }
}

# Runs inside a subshell to preserve current directory and avoid caller env overriding the project.
compose_project() (
    dir=$1
    action=$2
    cd "$dir" || return 1
    unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR

    if ! docker_cmd compose config --quiet; then
        warn "Invalid Compose configuration: $dir"
        return 1
    fi
    if [ "$action" = inspect ]; then
        log "Compose project: $dir"
        docker_cmd compose ps --all || return 1
        return 0
    fi

    configured=$(docker_cmd compose config --services) || return 1
    running=$(docker_cmd compose ps --services --status running) || return 1
    set --
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        # Avoid options and unexpected service names from a compromised CLI response.
        case "$service" in
            [a-zA-Z0-9]*) ;;
            *) warn "Ignoring unexpected service name: $service"; continue ;;
        esac
        case "$service" in *[!a-zA-Z0-9_.-]*) continue ;; esac
        case "
$configured
" in
            *"
$service
"*) set -- "$@" "$service" ;;
            *) warn "Ignoring running orphan service: $service" ;;
        esac
    done <<EOF
$running
EOF

    if [ "$#" -eq 0 ]; then
        log "No running Compose services in $dir; nothing will be started."
        return 0
    fi
    log "Running services in $dir: $*"
    if [ "$YES" -eq 0 ] && [ ! -t 0 ]; then
        warn 'Refusing image pull in noninteractive mode without --yes.'
        return 1
    fi
    if ! docker_cmd compose pull --ignore-buildable "$@"; then
        warn "Image pull failed in $dir"
        return 1
    fi
    log 'Preview of potential container changes:'
    if ! docker_cmd compose --dry-run up -d --no-build --no-deps "$@"; then
        warn "Compose dry-run failed in $dir; not deploying. Upgrade Compose v2 if needed."
        return 1
    fi
    if ! confirm "Deploy $dir (may recreate/restart the above services)?"; then
        log "Skipped deployment: $dir (images may already have been pulled)."
        return 0
    fi
    # --no-deps prevents implicitly starting intentionally stopped dependencies.
    # --wait requires Compose v2 and waits for running/healthy (where configured).
    if ! docker_cmd compose up -d --no-build --no-deps --wait --wait-timeout 180 "$@"; then
        warn "Deployment failed or readiness timeout in $dir (no auto rollback)."
        return 1
    fi
    log "Post-update status for $dir:"
    docker_cmd compose ps --all || return 1
    after=$(docker_cmd compose ps --services --status running) || return 1
    for service do
        case "
$after
" in
            *"
$service
"*) ;;
            *) warn "Service '$service' no longer running in $dir"; return 1 ;;
        esac
    done
    return 0
)

process_compose_dirs() {
    action=$1
    check_allowlist || return 1
    found=0
    failed=0
    # Read in current shell (not from a pipeline), so failure count persists.
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim indentation and trailing whitespace around directory paths.
        dir=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$dir" in ''|'#'*) continue ;; /*) ;; *) warn "Skipping non-absolute Compose path: $dir"; failed=$((failed + 1)); continue ;; esac
        if [ ! -d "$dir" ]; then
            warn "Compose directory does not exist: $dir"
            failed=$((failed + 1))
            continue
        fi
        if [ ! -f "$dir/compose.yaml" ] && [ ! -f "$dir/compose.yml" ] &&
           [ ! -f "$dir/docker-compose.yaml" ] && [ ! -f "$dir/docker-compose.yml" ]; then
            warn "No Compose file directly inside: $dir"
            failed=$((failed + 1))
            continue
        fi
        found=$((found + 1))
        if ! compose_project "$dir" "$action"; then failed=$((failed + 1)); fi
    done < "$COMPOSE_DIRS"
    [ "$found" -gt 0 ] || log 'No Compose projects listed in the allowlist.'
    [ "$failed" -eq 0 ] || { warn "$failed Compose project(s) failed or were refused."; return 1; }
}

docker_report_and_update() {
    section Docker
    if ! have docker; then
        if [ "$MODE" = docker ]; then
            warn 'Docker is not installed on this machine.'
            return 1
        fi
        log 'Docker not installed; nothing to inspect or update.'
        return 0
    fi
    if ! get_docker_access; then
        if [ "$MODE" = docker ] || [ "$MODE" = all ]; then return 1; fi
        log 'Docker status unavailable; skipped.'
        return 0
    fi
    log 'Local Docker containers (including ones not managed by this script):'
    docker_cmd ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || return 1
    if [ "$CHECK" -eq 1 ] || [ "$MODE" = normal ]; then
        log 'Allowlisted Compose projects (read-only):'
        if [ -f "$COMPOSE_DIRS" ]; then
            process_compose_dirs inspect || return 1
        else
            log "Allowlist not configured: $COMPOSE_DIRS"
        fi
        log 'Registry image freshness is NOT checked by this read-only inspection.'
    else
        log 'Updating allowlisted Compose projects only (may restart running services).'
        process_compose_dirs upgrade || return 1
    fi
}

if [ "$MODE" != docker ]; then
    if [ -f /etc/unraid-version ] || [ -f /etc/openwrt_release ]; then
        if [ "$CHECK" -eq 1 ]; then
            warn 'Appliance OS detected (Unraid/OpenWrt): system package checks skipped.'
        else
            die 'Unraid/OpenWrt system upgrades are excluded. Use update --docker for allowlisted Compose services.'
        fi
    else
        if identify_os; then
            if [ "$FAMILY" = unsupported ]; then
                if [ "$CHECK" -eq 1 ]; then
                    warn "Unsupported OS $OS_NAME; package checks skipped."
                else
                    die "Unsupported/transactional OS: $OS_NAME. Use its dedicated update procedure."
                fi
            else
                system_packages || { warn 'OS package stage failed.'; ERRORS=$((ERRORS + 1)); }
                flatpak_packages || { warn 'Flatpak stage failed.'; ERRORS=$((ERRORS + 1)); }
                snap_packages || { warn 'Snap stage failed.'; ERRORS=$((ERRORS + 1)); }
                brew_packages || { warn 'Homebrew stage failed.'; ERRORS=$((ERRORS + 1)); }
            fi
        else
            if [ "$CHECK" -eq 0 ]; then die 'Unknown operating system; refusing package changes.'; fi
        fi
    fi
fi

if [ "$MODE" = all ] && [ "$CHECK" -eq 0 ] && [ "$ERRORS" -ne 0 ]; then
    warn 'Skipping Docker deployment because an earlier update stage failed.'
else
    docker_report_and_update || { warn 'Docker stage failed.'; ERRORS=$((ERRORS + 1)); }
fi

if [ "$CHECK" -eq 0 ] && [ -f /var/run/reboot-required ]; then
    warn 'Reboot requested by OS packages; reboot manually after evaluating service impact.'
fi
if [ "$ERRORS" -ne 0 ]; then die "$ERRORS stage(s) failed or were refused."; fi
log 'Finished.'
__UPDATE_PAYLOAD_75B3A1__

ACTUAL=$(sha256sum "$PAYLOAD" | awk '{print $1}')
[ "$ACTUAL" = "$PAYLOAD_SHA256" ] || err "Checksum mismatch for bundled updater (expected $PAYLOAD_SHA256, got $ACTUAL)."
sh -n "$PAYLOAD" || err 'Bundled updater failed shell syntax validation.'

# Install atomically (same-directory rename), rather than truncating a live script.
as_root mkdir -p "$INSTALL_DIR" || err "Could not create $INSTALL_DIR"
STAGE=$(as_root mktemp "$INSTALL_DIR/.update-install.XXXXXXXX") || err 'Could not create installation staging file.'
as_root install -m 755 "$PAYLOAD" "$STAGE" || err 'Could not stage new updater.'
as_root mv -f "$STAGE" "$DEST" || err 'Could not replace updater atomically.'
STAGE=

# Keep an existing allowlist untouched, including permissions and contents.
if [ ! -e "$ALLOWLIST" ] && [ ! -L "$ALLOWLIST" ]; then
    as_root mkdir -p "$CONFIG_DIR" || err "Could not create $CONFIG_DIR"
    printf '%s\n' \
        '# Absolute paths to allowed Docker Compose project directories' \
        '# /opt/immich' \
        '# /opt/uptime-kuma' |
        as_root tee "$ALLOWLIST" >/dev/null || err 'Could not create the Compose allowlist.'
    as_root chmod 644 "$ALLOWLIST" || err 'Could not set allowlist permissions.'
fi

say "Installed/updated $DEST (version $VERSION)"
say "Compose allowlist: $ALLOWLIST"
case ":${PATH:-}:" in
    *:"$INSTALL_DIR":*) say 'Ready: update --check' ;;
    *) say "Note: $INSTALL_DIR is not in PATH; use $DEST or add this directory to PATH." ;;
esac
