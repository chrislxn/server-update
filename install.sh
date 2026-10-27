#!/bin/sh
# Self-contained installer for the 'update' Linux maintenance command.
# Publish this ONE file at an HTTPS raw-text URL, then run:
#   curl -fsSL https://example.org/install.sh | sh
# Do not use `sudo sh` for the entire download: this installer invokes sudo/doas
# only to place the checked payload into privileged directories.
set -eu

VERSION=2.2.0
INSTALL_DIR=${UPDATE_INSTALL_DIR:-/usr/local/bin}
CONFIG_DIR=${UPDATE_CONFIG_DIR:-/etc/update}
DEST=$INSTALL_DIR/update
ALLOWLIST=$CONFIG_DIR/compose-projects
LEGACY_ALLOWLIST=$CONFIG_DIR/compose-dirs
PAYLOAD_SHA256=23da3aef3585651597d1797c38963138638aec7cf626f7ec67464c1b61ca1df8
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

VERSION=2.2.0
INSTALL_PATH=/usr/local/bin/update
COMPOSE_DIRS=/etc/update/compose-dirs
COMPOSE_PROJECTS=/etc/update/compose-projects
PROTECT_ENGINE=0
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
update - Unified Linux + Docker + SafeLine maintenance tool (v2.2.0)

Usage:
  update                        Update OS + Flatpak/Snap/Brew; print local Docker inventory
  update --check                Read-only package check + remote Docker image digest audit
  update --docker-check         Remote Docker image audit only (no pull/recreate)
  update --docker-discover      Print discovered Compose projects, exact files and manager
  update --safeline-check       Read-only SafeLine release check (official HTTPS feed)
  update --safeline             Invoke OFFICIAL SafeLine updater after typed confirmation
  update --docker              Pull / preview / deploy *allowlisted* custom Compose projects
  update --docker --check      Same read-only audit as --docker-check
  update --all                 OS updates + selected Compose deployment (EXCLUDES SafeLine)
  update --yes                 Auto-confirm normal package manager prompts
  update --all --yes           Auto-confirm allowlisted CUSTOM Compose deployments
  update --protect-engine      Abort OS package stage when it may update a running Docker engine
  update --install             First-time installation (refuses overwrite)
  update --version | --help

Compose allowlist: /etc/update/compose-projects (one exact project name per line)
Legacy v1 directory allowlist /etc/update/compose-dirs remains supported.
Docker 1Panel / SafeLine / AzuraCast / known manager projects are never
redeployed via Compose, even if allowlisted. Only --safeline explicitly invokes
the OFFICIAL SafeLine manager. --yes NEVER authorizes WAF downtime.

--check never pulls images, installs packages or recreates containers. Remote
image check compares the SAME tag digest, NOT newer version numbers or releases.
No OS release upgrades, autoremove/prune, or reboots.
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
    if [ ! -e "$COMPOSE_PROJECTS" ]; then
        printf '# Exact Compose project names, one per line. See: update --docker-discover\n' |
            as_root tee "$COMPOSE_PROJECTS" >/dev/null || die 'Could not create project allowlist.'
        as_root chmod 644 "$COMPOSE_PROJECTS" || die 'Could not set allowlist permissions.'
    fi
    log "Installed: $INSTALL_PATH"
    log "Compose allowlist: $COMPOSE_PROJECTS (legacy: $COMPOSE_DIRS)"
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
        --protect-engine) PROTECT_ENGINE=1 ;;
        -y|--yes) YES=1 ;;
        --docker|--docker-check|--docker-discover|--safeline|--safeline-check|--all)
            [ "$MODE" = normal ] || die 'Choose exactly one Docker mode.'
            case "$1" in
                --docker) MODE=docker ;;
                --docker-check) MODE=docker-check ;;
                --docker-discover) MODE=docker-discover ;;
                --safeline) MODE=safeline ;;
                --safeline-check) MODE=safeline-check ;;
                --all) MODE=all ;;
            esac ;;
        *) die "Unknown option: $1 (try --help)." ;;
    esac
    shift
done
if [ "$INSTALL" -eq 1 ]; then
    [ "$CHECK" -eq 0 ] && [ "$YES" -eq 0 ] && [ "$MODE" = normal ] &&
    [ "$PROTECT_ENGINE" -eq 0 ] || die '--install cannot be combined with operations.'
    install_self
    exit 0
fi
if [ "$MODE" = safeline ] || [ "$MODE" = safeline-check ]; then
    [ "$YES" -eq 0 ] && [ "$PROTECT_ENGINE" -eq 0 ] && [ "$CHECK" -eq 0 ] ||
        die 'SafeLine modes require a separate explicit invocation; --yes cannot approve WAF downtime.'
fi
if [ "$MODE" = docker-check ] || [ "$MODE" = docker-discover ]; then
    [ "$YES" -eq 0 ] && [ "$PROTECT_ENGINE" -eq 0 ] ||
        die 'Read-only Docker mode does not accept --yes / --protect-engine.'
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

# Alibaba Cloud Linux 4 ships both RPM and Deb Edition images.
# Require explicit Deb image metadata; never guess from locally present tools.
alinux_is_deb_edition() {
    case " ${ID_LIKE:-} " in
        *' debian '*|*' ubuntu '*) return 0 ;;
    esac
    case "${PRETTY_NAME:-} ${VARIANT:-} ${VARIANT_ID:-}" in
        *'Deb Edition'*|*'DEB Edition'*|*'deb edition'*|*'Adebe'*|*'adebe'*|*'ADeBe'*) return 0 ;;
    esac
    return 1
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
    OS_VERSION=${VERSION_ID:-}
    OS_MAJOR=${OS_VERSION%%.*}
    case "${ID:-}" in
        # Alibaba Cloud Linux: v2 yum, v3 RPM/dnf, v4 RPM/dnf or Deb/apt.
        alinux|aliyunlinux|aliyun)
            case "$OS_MAJOR" in
                2) FAMILY=yum ;;
                3) FAMILY=dnf ;;
                4) if alinux_is_deb_edition; then FAMILY=apt; else FAMILY=dnf; fi ;;
                *) FAMILY=unsupported ;;
            esac ;;
        # TencentOS Server (also known as Tlinux): v2 yum; v3/v4 dnf.
        tencentos|tlinux|tencentos-server|tencentosserver)
            case "$OS_MAJOR" in
                2) FAMILY=yum ;;
                3|4) FAMILY=dnf ;;
                *) FAMILY=unsupported ;;
            esac ;;
        # Anolis OS 7 is CentOS 7-compatible; Anolis 8/23 use dnf.
        anolis|anolisos)
            case "$OS_MAJOR" in
                7) FAMILY=yum ;;
                8|23) FAMILY=dnf ;;
                *) FAMILY=unsupported ;;
            esac ;;
        # OpenCloudOS recommends dnf in preference to compatible yum.
        opencloudos|opencloudos-stream)
            FAMILY=dnf ;;
        adebe|debian|ubuntu|linuxmint|raspbian|pop|elementary|kali|devuan|neon|zorin)
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
            # Some TencentOS cloud images may use inherited CentOS IDs.
            case "${NAME:-} ${PRETTY_NAME:-}" in
                *'TencentOS Server'*)
                    case "$OS_MAJOR" in
                        2) FAMILY=yum ;;
                        3|4) FAMILY=dnf ;;
                        *) FAMILY=unsupported ;;
                    esac
                    return 0 ;;
            esac
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

# Legacy RHEL/CentOS 7-era vendor distros should prefer the vendor's yum CLI.
choose_yum() {
    if have yum; then PKG=yum
    else
        warn 'YUM not found for this OS release; refusing to guess another package manager.'
        return 1
    fi
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
    if [ "$PROTECT_ENGINE" -eq 1 ] && [ "$CHECK" -eq 0 ] && have docker && ! docker_daemon_accessible; then
        warn '--protect-engine: cannot determine Docker daemon state; refusing OS package upgrade.'
        return 1
    fi
    if [ "$PROTECT_ENGINE" -eq 1 ] && [ "$FAMILY" != apt ] && [ "$CHECK" -eq 0 ] && docker_running_containers; then
        warn '--protect-engine on this non-APT Docker host cannot safely exclude Engine updates; skipping OS packages.'
        return 1
    fi
    case "$FAMILY" in
        apt)
            have apt-get || { warn 'apt-get not found'; return 1; }
            if [ "$CHECK" -eq 1 ]; then
                log 'APT available upgrades (current local metadata; may be stale):'
                if have apt; then apt list --upgradable 2>/dev/null || return 1
                else apt-get -s upgrade || return 1; fi
            else
                as_root apt-get update || return 1
                if [ "$PROTECT_ENGINE" -eq 1 ] && docker_running_containers; then
                    if apt-get -s upgrade 2>/dev/null | grep -E '^Inst (docker|containerd|moby-|runc|buildkit)' >/dev/null; then
                        warn 'Docker Engine / containerd upgrade pending on a running Docker host.'
                        warn '--protect-engine is set: skipping ENTIRE APT upgrade (not silently leaving Docker packages behind).'
                        warn 'Review manually, or run without --protect-engine during a maintenance window.'
                        return 1
                    fi
                fi
                if [ "$YES" -eq 1 ]; then
                    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade || return 1
                else
                    as_root apt-get upgrade || return 1
                fi
            fi ;;
        yum)
            choose_yum || return 1
            if [ "$CHECK" -eq 1 ]; then
                "$PKG" check-update
                status=$?
                [ "$status" -eq 0 ] || [ "$status" -eq 100 ] || return "$status"
            elif [ "$YES" -eq 1 ]; then
                as_root "$PKG" -y update || return 1
            else
                as_root "$PKG" update || return 1
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

# Safety helper: packages such as docker-ce can restart Engine and containers.
docker_daemon_accessible() {
    docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 && return 0
    if [ "$(id -u)" -ne 0 ]; then
        if have sudo; then sudo -n docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 && return 0; fi
        if have doas; then doas -n docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 && return 0; fi
    fi
    return 1
}
docker_running_containers() {
    have docker || return 1
    docker ps -q 2>/dev/null | grep -q . && return 0
    if [ "$(id -u)" -ne 0 ]; then
        if have sudo; then sudo -n docker ps -q 2>/dev/null | grep -q . && return 0; fi
        if have doas; then doas -n docker ps -q 2>/dev/null | grep -q . && return 0; fi
    fi
    return 1
}

# The embedded Python helper reads Docker Compose's structured JSON, not
# pretty-printed CLI tables. Python is optional for normal OS-only updates.
get_docker_access() {
    have docker || { warn 'Docker CLI missing.'; return 1; }
    DOCKER_AS_ROOT=user
    DOCKER_WRAPPER=sudo
    if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then :
    elif [ "$(id -u)" -ne 0 ] && have sudo && sudo -n docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        DOCKER_AS_ROOT=root
        DOCKER_WRAPPER=sudo
    elif [ "$(id -u)" -ne 0 ] && have doas && doas -n docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        DOCKER_AS_ROOT=root
        DOCKER_WRAPPER=doas
    elif [ "$(id -u)" -ne 0 ] && [ -t 0 ] && have sudo && sudo docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        DOCKER_AS_ROOT=root
        DOCKER_WRAPPER=sudo
    else
        warn 'Docker daemon inaccessible or not running.'
        return 1
    fi
    docker_cmd compose version >/dev/null 2>&1 || { warn 'Docker Compose v2 missing.'; return 1; }
}

docker_cmd() {
    if [ "${DOCKER_AS_ROOT:-user}" = root ]; then
        if [ "$DOCKER_WRAPPER" = doas ]; then doas docker "$@"; else sudo docker "$@"; fi
    else docker "$@"; fi
}

docker_python() {
    action=$1
    python3 - "$action" "$YES" "$COMPOSE_PROJECTS" "$COMPOSE_DIRS" "$DOCKER_AS_ROOT" "$DOCKER_WRAPPER" <<'__UPDATE_DOCKER_PY__'
# This module is embedded in the POSIX-shell 'update' command and runs with Python 3.8+.
# It uses the Docker CLI and standard library only. Never log Docker inspect environment values.
import collections
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ACTION = sys.argv[1]  # inventory, audit, upgrade
AUTO_YES = sys.argv[2] == '1'
ALLOWLIST_FILE = Path(sys.argv[3])
LEGACY_ALLOWLIST_FILE = Path(sys.argv[4])
DOCKER_AS_ROOT = sys.argv[5] == 'root'
DOCKER_WRAPPER = sys.argv[6] if len(sys.argv) > 6 else 'sudo'
MANAGED_OVERRIDE = sys.argv[7] == '1' if len(sys.argv) > 7 else False
REMOTE_TIMEOUT = 16
DOCKER_TIMEOUT = 40
MAX_REMOTE_IMAGES = 80


def out(s):
    print('[update/docker] ' + s, flush=True)


def warn(s):
    print('[update/docker] WARNING: ' + s, file=sys.stderr, flush=True)


class DockerError(Exception):
    pass


prefix = ([DOCKER_WRAPPER, 'docker'] if DOCKER_AS_ROOT else ['docker'])


def run(*parts, cwd=None, timeout=DOCKER_TIMEOUT, must=True, quiet=False):
    cmd = prefix + list(parts)
    try:
        p = subprocess.run(cmd, cwd=cwd, stdin=None, capture_output=True,
                           text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        if must:
            raise DockerError('{}: {}'.format(' '.join(parts[:3]), str(e)))
        return None
    if p.returncode != 0:
        if must:
            # Compose may include sensitive values in errors. Only print the first short line.
            detail = (p.stderr or '').strip().splitlines()
            summary = (detail[0] if detail else 'exit {}'.format(p.returncode))
            raise DockerError('{}: {}'.format(' '.join(parts[:3]), summary[:220]))
        return None
    if not quiet and p.stderr.strip():
        # Avoid dumping warnings with variable substitutions into logs.
        pass
    return p.stdout


def parse_json(text, description):
    try:
        return json.loads(text)
    except (ValueError, TypeError) as e:
        raise DockerError('Invalid Docker JSON for {}: {}'.format(description, e))


def projects_inventory():
    raw = run('compose', 'ls', '--all', '--format', 'json')
    entries = parse_json(raw, 'compose ls')
    if not isinstance(entries, list):
        raise DockerError('Expected an array from docker compose ls --format json')
    projects = {}
    for item in entries:
        if not isinstance(item, dict):
            continue
        name = item.get('Name')
        if not isinstance(name, str) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', name):
            warn('Ignoring project with invalid/missing name: {!r}'.format(name))
            continue
        paths = item.get('ConfigFiles', '')
        if isinstance(paths, str):
            # Compose stores these in container labels as comma-separated paths.
            files = [p.strip() for p in paths.split(',') if p.strip()]
        elif isinstance(paths, list):
            files = paths
        else:
            files = []
        # Never attempt to read a file from an ambiguous/untrusted path.
        if not all(isinstance(f, str) and f.startswith('/') and '\n' not in f for f in files):
            files = []
        first = files[0] if files else ''
        category = classify(name, files)
        projects[name] = {'name': name, 'files': files, 'status': item.get('Status', '?'),
                          'category': category, 'directory': os.path.dirname(first) if first else ''}
    return projects


def classify(name, files):
    joined = ' '.join(files).lower()
    if '/opt/1panel/' in joined:
        return '1PANEL'
    if name == 'safeline' or '/data/safeline/' in joined:
        return 'SAFELINE'
    if name == 'azuracast' or '/var/azuracast/' in joined:
        return 'AZURACAST'
    if name in ('mysql', 'mariadb', 'postgres', 'postgresql', 'redis'):
        return 'DATABASE'
    return 'CUSTOM'


def containers_inventory():
    ids = (run('ps', '-a', '--format', '{{.ID}}') or '').splitlines()
    if not ids:
        return []
    # docker inspect returns sensitive Env and Mounts; parse in memory, never write or print raw.
    containers = parse_json(run('inspect', '--type', 'container', *ids), 'docker inspect')
    if not isinstance(containers, list):
        raise DockerError('Expected a container array from docker inspect')
    records = []
    for c in containers:
        conf = c.get('Config') or {}
        labels = conf.get('Labels') or {}
        state = c.get('State') or {}
        records.append({
            'name': str(c.get('Name') or '').lstrip('/'),
            'image_ref': str(conf.get('Image') or ''),
            'image_id': str(c.get('Image') or ''),
            'project': str(labels.get('com.docker.compose.project') or ''),
            'service': str(labels.get('com.docker.compose.service') or ''),
            'workdir': str(labels.get('com.docker.compose.project.working_dir') or ''),
            'state': str(state.get('Status') or 'unknown'),
            'health': str((state.get('Health') or {}).get('Status') or '-'),
        })
    return sorted(records, key=lambda c: (c['project'], c['name']))


def normalize_repo(ref):
    # Strip tag/digest, normalize Docker Hub implicit registry and library namespace.
    ref = ref.split('@', 1)[0]
    last = ref.rsplit('/', 1)[-1]
    if ':' in last:
        ref = ref[:-(len(last) - last.rfind(':'))]
    parts = ref.split('/')
    if '.' not in parts[0] and ':' not in parts[0] and parts[0] != 'localhost':
        if len(parts) == 1:
            return 'docker.io/library/' + ref
        return 'docker.io/' + ref
    if parts[0] == 'index.docker.io':
        return 'docker.io/' + '/'.join(parts[1:])
    return ref


def reference_qualifier(ref):
    if '@sha256:' in ref:
        return 'digest-pinned'
    tail = ref.rsplit('/', 1)[-1]
    if ':' not in tail:
        return 'floating (latest)'
    tag = tail.rsplit(':', 1)[-1]
    if tag.lower() in ('latest', 'stable', 'main', 'master', 'edge', 'nightly', 'dev'):
        return 'floating ({})'.format(tag)
    return 'tag:{}'.format(tag)


def get_local_digests(image_ids):
    result = {}
    for image_id in sorted(image_ids):
        if not image_id:
            continue
        raw = run('image', 'inspect', image_id, '--format', '{{json .RepoDigests}}',
                  must=False, timeout=DOCKER_TIMEOUT)
        try:
            parsed = json.loads(raw) if raw else []
        except ValueError:
            parsed = []
        result[image_id] = parsed if isinstance(parsed, list) else []
    return result


def remote_manifest(ref):
    # Inspection is read-only: NO pull, no local image/tag modifications.
    raw = run('buildx', 'imagetools', 'inspect', ref,
              '--format', '{{json .Manifest}}', must=False, timeout=REMOTE_TIMEOUT)
    if not raw:
        return None
    try:
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) and re.fullmatch(r'sha256:[0-9a-f]{64}',
                                                             str(obj.get('digest', ''))) else None
    except (ValueError, TypeError):
        return None


def audit_one(ref, local_digests, manifest):
    if ref.startswith('sha256:') or not ref or '/' not in normalize_repo(ref):
        return 'LOCAL_ONLY'
    if '@sha256:' in ref:
        return 'DIGEST_PINNED'
    repo = normalize_repo(ref)
    known = set()
    for x in local_digests:
        if isinstance(x, str) and '@sha256:' in x:
            local_repo, local_digest = x.rsplit('@', 1)
            if normalize_repo(local_repo) == repo:
                known.add(local_digest)
    if not known:
        return 'NO_LOCAL_DIGEST'
    if not manifest:
        return 'REGISTRY_UNKNOWN'
    remote = {manifest['digest']}
    # Local engines may record a platform-specific digest instead of index digest.
    for child in manifest.get('manifests', []) or []:
        if not isinstance(child, dict):
            continue
        platform = child.get('platform') or {}
        if platform.get('os') != 'linux' and platform.get('os') != 'windows':
            continue  # Attestations and non-runtime manifests.
        digest = child.get('digest')
        if isinstance(digest, str):
            remote.add(digest)
    if known.intersection(remote):
        return 'SAME_TAG_DIGEST'
    return 'TAG_DIGEST_CHANGED'


def print_projects(projects, selected=None):
    out('Discovered {} Compose projects:'.format(len(projects)))
    for p in sorted(projects.values(), key=lambda p: p['name']):
        flag = 'ALLOWLISTED' if selected and p['name'] in selected else '-'
        out('  {:<20} {:<10} {:<12} {}'.format(p['name'], p['category'], flag, p['status']))
        if p['files']:
            for f in p['files']:
                out('    config: {}'.format(f))
        else:
            warn('    {} has no trustworthy saved Compose config paths'.format(p['name']))


def read_allowlist(projects):
    chosen = set()
    errors = []
    seen = []
    for path in (ALLOWLIST_FILE, LEGACY_ALLOWLIST_FILE):
        if not path.exists():
            continue
        if path.is_symlink():
            errors.append('{} is a symlink'.format(path))
            continue
        st = path.stat()
        if st.st_uid != 0 or st.st_mode & 0o022:
            errors.append('{} must be root-owned and not group/world writable'.format(path))
            continue
        try:
            entries = path.read_text().splitlines()
        except OSError as e:
            errors.append('{}: {}'.format(path, e))
            continue
        for line in entries:
            entry = line.strip()
            if not entry or entry.startswith('#'):
                continue
            seen.append(entry)
            if entry.startswith('/'):
                # Compatibility with v1: old allowlist contained absolute project directories.
                matches = [p['name'] for p in projects.values() if p['directory'] == entry]
                if len(matches) == 1:
                    chosen.add(matches[0])
                else:
                    errors.append('Legacy path {!r} matches {} projects'.format(entry, len(matches)))
            elif entry in projects:
                chosen.add(entry)
            else:
                errors.append('Project {!r} was not found'.format(entry))
    return chosen, seen, errors


def project_workdir(p, containers):
    active = [c for c in containers if c['project'] == p['name'] and c['state'] == 'running']
    workdirs = {c['workdir'] for c in active if c['workdir']}
    if len(workdirs) != 1:
        raise DockerError('{}: missing or inconsistent working directory in Compose labels'.format(p['name']))
    wd = workdirs.pop()
    if not os.path.isdir(wd):
        raise DockerError('{}: working directory does not exist: {}'.format(p['name'], wd))
    if not p['files'] or not all(os.path.isfile(f) for f in p['files']):
        raise DockerError('{}: one or more original Compose files are missing'.format(p['name']))
    return wd


def compose_args(p):
    cmd = ['compose', '-p', p['name']]
    for f in p['files']:
        cmd.extend(['-f', f])
    return cmd


def require_confirm(message, force=False):
    # force=True means --yes cannot bypass this additional safety barrier.
    if AUTO_YES and not force:
        return True
    if not sys.stdin.isatty():
        warn('Interactive confirmation required: {}'.format(message))
        return False
    try:
        ans = input('[update/docker] {} [y/N] '.format(message)).strip().lower()
    except EOFError:
        return False
    return ans in ('y', 'yes')


def run_stream(parts, cwd=None, timeout=300):
    try:
        completed = subprocess.run(prefix + list(parts), cwd=cwd, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        warn('{}: {}'.format(' '.join(parts[:3]), e))
        return False
    return completed.returncode == 0


def update_project(p, containers):
    name = p['name']
    if p['category'] != 'CUSTOM':
        warn('{} is {}-managed / high-risk; use its native manager'.format(name, p['category']))
        return 1
    current = [c for c in containers if c['project'] == name and c['state'] == 'running']
    if not current:
        out('{}: no running services; skip'.format(name))
        return 0
    if not p['files']:
        warn('{} lacks trustworthy Compose source files; skip'.format(name))
        return 1
    try:
        workdir = project_workdir(p, containers)
        cmd = compose_args(p)
        run(*(cmd + ['config', '--quiet']), cwd=workdir)
        configured = set(run(*(cmd + ['config', '--services']), cwd=workdir).splitlines())
        running = sorted(set(c['service'] for c in current))
        if not all(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', s or '') for s in running):
            raise DockerError('{}: invalid/missing service label'.format(name))
        extra = set(running) - configured
        if extra:
            raise DockerError('{}: running service(s) not in current config: {}'.format(name, ','.join(sorted(extra))))
        counts = collections.Counter(c['service'] for c in current)
        if any(n != 1 for n in counts.values()):
            raise DockerError('{}: scaled services detected; manual Compose update required'.format(name))
        # Live project may still have database/service dependencies. User explicitly allowlisted it.
        out('{}: running services: {}'.format(name, ', '.join(running)))
        if not require_confirm('Pull images for project {}?'.format(name)):
            out('Skipped {}'.format(name))
            return 0
        if not run_stream(cmd + ['pull', '--ignore-buildable'] + running, cwd=workdir, timeout=600):
            warn('{}: image pull failed, refusing deploy'.format(name))
            return 1
        out('{}: Compose dry-run preview:'.format(name))
        if not run_stream(cmd + ['--dry-run', 'up', '-d', '--no-build', '--no-deps', '--pull', 'never'] + running,
                          cwd=workdir):
            warn('{}: dry-run failed; refusing deploy'.format(name))
            return 1
        if not require_confirm('Apply changes to {}?'.format(name)):
            out('{}: deployment declined (images may be in local cache)'.format(name))
            return 0
        # Re-read running services to detect external changes while images were being pulled.
        latest = containers_inventory()
        after_running = sorted(set(c['service'] for c in latest if c['project'] == name and c['state'] == 'running'))
        if after_running != running:
            raise DockerError('{}: service state changed during pull; refusing deploy'.format(name))
        if not run_stream(cmd + ['up', '-d', '--no-build', '--no-deps', '--pull', 'never',
                                 '--wait', '--wait-timeout', '180'] + running,
                          cwd=workdir, timeout=300):
            warn('{}: deploy/readiness failed; no automatic rollback'.format(name))
            return 1
        final = containers_inventory()
        bad = [c['name'] for c in final if c['project'] == name and c['service'] in running and
               (c['state'] != 'running' or c['health'] == 'unhealthy')]
        if bad:
            warn('{}: container check failed: {}'.format(name, ', '.join(bad)))
            return 1
        out('{}: deployment finished; running services checked'.format(name))
        return 0
    except DockerError as e:
        warn(str(e))
        return 1


def audit_images(containers):
    image_ids = {c['image_id'] for c in containers}
    known = get_local_digests(image_ids)
    refs = {c['image_ref'] for c in containers if c['image_ref']}
    # Only query images that have a comparable local digest. Docker records
    # docker.io/library/foo, library/foo and foo under different spellings.
    # Earlier versions compared the raw string, incorrectly reducing 25 images
    # to only 2 remote queries on some hosts.
    usable = set()
    for c in containers:
        ref = c['image_ref']
        repo = normalize_repo(ref)
        if c['image_id'] and ref and '@sha256:' not in ref:
            if any(isinstance(d, str) and '@sha256:' in d and
                   normalize_repo(d.rsplit('@', 1)[0]) == repo
                   for d in known.get(c['image_id'], [])):
                usable.add(ref)
    remote = {}
    to_check = sorted(usable)[:MAX_REMOTE_IMAGES]
    out('Comparable image tags: {} / {} unique references; {} lack matching local digests.'.format(
        len(usable), len(refs), len(refs - usable)))
    if not shutil.which('docker'):
        warn('docker CLI not found; remote checks unavailable')
    elif not to_check:
        out('No locally comparable registry digests; remote status is UNKNOWN.')
    else:
        out('Checking {} distinct image references against registries (read-only; up to {} s per request).'.format(
            len(to_check), REMOTE_TIMEOUT))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = {pool.submit(remote_manifest, r): r for r in to_check}
            for fut in concurrent.futures.as_completed(futures):
                ref = futures[fut]
                try:
                    remote[ref] = fut.result()
                except Exception:
                    remote[ref] = None
    out('Container image audit (TAG_DIGEST_CHANGED = same tag changed, not a newer version tag):')
    for c in containers:
        ref = c['image_ref']
        status = audit_one(ref, known.get(c['image_id'], []), remote.get(ref))
        if ref in usable and ref not in to_check:
            status = 'NOT_QUERIED'
        if not ref:
            status = 'UNKNOWN'
        extra = reference_qualifier(ref)
        out('  {:<27} {:<22} {:<19} {}'.format(c['name'][:27], c['project'][:22] or '-', status, extra))
    out('SAME_TAG_DIGEST only means the CURRENT tag digest matches; it does NOT discover newer semver tags.')
    out('NO_LOCAL_DIGEST / REGISTRY_UNKNOWN are unknown, not evidence of being up-to-date.')


def main():
    projects = projects_inventory()
    containers = containers_inventory()
    chosen, entries, errors = read_allowlist(projects)
    if errors:
        for e in errors:
            warn('Allowlist: ' + e)
        if ACTION == 'upgrade':
            return 1  # strict fail closed: no partial changes with untrusted allowlist
    print_projects(projects, chosen)
    out('Containers: {} total, {} running'.format(len(containers), sum(c['state'] == 'running' for c in containers)))
    for c in containers:
        if not c['project']:
            out('  standalone: {} ({}, {})'.format(c['name'], c['image_ref'], c['state']))
    if ACTION == 'inventory':
        out('Local inventory only; registry image versions were not checked.')
        return 0
    if ACTION == 'audit':
        audit_images(containers)
        return 0
    if ACTION == 'upgrade':
        if not chosen:
            out('No Compose projects allowlisted; Docker was not modified.')
            out('Add explicit project names to {}'.format(ALLOWLIST_FILE))
            return 0
        unsafe = [n for n in sorted(chosen) if projects[n]['category'] != 'CUSTOM']
        if unsafe:
            warn('Allowlist includes manager-owned/high-risk projects: {}'.format(', '.join(unsafe)))
            warn('Failing closed BEFORE pulling or rebuilding any container. Remove them from allowlist.')
            return 1
        failures = 0
        for name in sorted(chosen):
            failures += update_project(projects[name], containers)
        return 1 if failures else 0
    raise DockerError('Unknown action {}'.format(ACTION))


try:
    sys.exit(main())
except DockerError as error:
    warn(str(error))
    sys.exit(1)
__UPDATE_DOCKER_PY__
}

docker_report_and_update() {
    section Docker
    if ! have docker; then
        case "$MODE" in
            docker|docker-check|docker-discover) warn 'Docker CLI not installed.'; return 1 ;;
            *) log 'Docker not installed; skipped.'; return 0 ;;
        esac
    fi
    if ! get_docker_access; then
        case "$MODE" in
            docker|docker-check|docker-discover|all) return 1 ;;
            *) log 'Docker status unavailable; skipped.'; return 0 ;;
        esac
    fi
    if ! have python3; then
        if [ "$MODE" = normal ] && [ "$CHECK" -eq 0 ]; then
            docker_cmd ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
            log 'Python 3 absent: advanced Docker discovery requires Python 3.'
            return 0
        fi
        warn 'Python 3 is required for structured Docker discovery and registry checks.'
        return 1
    fi
    action=inventory
    if [ "$CHECK" -eq 1 ] || [ "$MODE" = docker-check ]; then action=audit; fi
    if [ "$MODE" = docker-discover ]; then action=inventory; fi
    if { [ "$MODE" = docker ] || [ "$MODE" = all ]; } && [ "$CHECK" -eq 0 ]; then action=upgrade; fi
    docker_python "$action"
}

safeline_python() {
    action=$1
    expected=${2:-}
    # Status and verification need only Docker metadata, so never request
    # sudo to inspect an already-running SafeLine instance. The vendor upgrade
    # preflight, however, must verify protected files and .env as root.
    if [ "$action" = path ] || [ "$action" = preflight ]; then
        set -- python3 - "$action" direct "$DOCKER_WRAPPER" "$expected"
        if [ "$(id -u)" -ne 0 ]; then
            if have sudo; then set -- sudo "$@"
            elif have doas; then set -- doas "$@"
            else warn 'sudo/doas required for protected SafeLine upgrade configuration'; return 1
            fi
        fi
    else
        set -- python3 - "$action" "$DOCKER_AS_ROOT" "$DOCKER_WRAPPER" "$expected"
    fi
    "$@" <<'__UPDATE_SAFELINE_PY__'
# Embedded SafeLine adapter (Python 3 standard library only).
# Read-only discovery/status; vendor scripts are executed only by shell after explicit confirmation.
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ACTION = sys.argv[1]  # local | remote | path | preflight | verify
DOCKER_AS_ROOT = sys.argv[2] == 'root'
DOCKER_WRAPPER = sys.argv[3] if len(sys.argv) > 3 else 'sudo'
EXPECTED_VERSION = sys.argv[4] if len(sys.argv) > 4 else ''
DOCKER_CMD = ([DOCKER_WRAPPER, 'docker'] if DOCKER_AS_ROOT else ['docker'])
VERSION_URL = 'https://waf-ce.chaitin.cn/release/latest/version.json'
VERSION_PATTERN = re.compile(r'^v?(\d+)\.(\d+)\.(\d+)(?:-lts)?$')


def show(text):
    print('[update/safeline] ' + text, flush=True)


def warn(text):
    print('[update/safeline] WARNING: ' + text, file=sys.stderr, flush=True)


def docker(*args):
    try:
        p = subprocess.run(DOCKER_CMD + list(args), capture_output=True,
                           text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError('Docker inquiry failed: {}'.format(str(exc)[:150]))
    if p.returncode:
        raise RuntimeError('Docker inquiry failed ({})'.format(' '.join(args[:3])))
    return p.stdout


def safe_env(path):
    result = {}
    try:
        data = path.read_text(encoding='utf-8', errors='replace')
    except (OSError, UnicodeError):
        return None
    for line in data.splitlines():
        match = re.match(r'^\s*(SAFELINE_DIR|IMAGE_TAG|RELEASE|CHANNEL)\s*=\s*(.*?)\s*$', line)
        if match:
            v = match.group(2)
            if len(v) > 1 and v[0] == v[-1] and v[0] in ('"', "'"):
                v = v[1:-1]
            result[match.group(1)] = v
    return result


def get_installation():
    try:
        entries = json.loads(docker('compose', 'ls', '--all', '--format', 'json'))
    except (ValueError, TypeError):
        raise RuntimeError('Cannot parse Compose project JSON')
    if not isinstance(entries, list):
        raise RuntimeError('Unexpected Docker Compose response')
    matches = [p for p in entries if isinstance(p, dict) and p.get('Name') == 'safeline']
    if not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError('Ambiguous SafeLine Compose project')
    project = matches[0]
    files = project.get('ConfigFiles', '')
    if isinstance(files, str):
        files = [p.strip() for p in files.split(',') if p.strip()]
    if not isinstance(files, list) or not files or any(not isinstance(f, str) or not f.startswith('/') or '\n' in f for f in files):
        raise RuntimeError('SafeLine Compose configuration paths are missing or invalid')
    # Read-only checks must not stat() or resolve() a private Compose file.
    # Docker already reports the exact file paths; walking /data/safeline can
    # raise PermissionError for members of the docker group who are not root.
    roots = {os.path.normpath(os.path.dirname(f)) for f in files}
    if len(roots) != 1:
        raise RuntimeError('SafeLine Compose configuration spans multiple directories; manual upgrade needed')
    folder = Path(next(iter(roots)))
    # File verification is required for launching the vendor updater, but NOT
    # for an unprivileged read-only version check (or its postflight check).
    if ACTION in ('path', 'preflight'):
        try:
            files_exist = folder.is_dir() and all(Path(f).is_file() for f in files)
        except OSError:
            raise RuntimeError('Cannot access SafeLine Compose files; run with sudo')
        if not files_exist:
            raise RuntimeError('SafeLine Compose files are missing; refusing automatic vendor upgrade')
    return folder, project


def current_image_version():
    ids = docker('ps', '-a', '--filter', 'label=com.docker.compose.project=safeline',
                 '--format', '{{.ID}}').splitlines()
    if not ids:
        raise RuntimeError('SafeLine project found, but no Compose containers are present')
    try:
        details = json.loads(docker('inspect', '--type', 'container', *ids))
    except (ValueError, TypeError):
        raise RuntimeError('Cannot parse SafeLine container metadata')
    running = 0
    mgt_image = ''
    for c in details:
        if (c.get('State') or {}).get('Status') == 'running':
            running += 1
        config = c.get('Config') or {}
        labels = config.get('Labels') or {}
        image = str(config.get('Image') or '')
        if labels.get('com.docker.compose.service') == 'mgt' or re.search(r'(?:^|/)safeline-mgt(?:-g)?:', image):
            mgt_image = image
    match = re.search(r'(?:^|/)safeline-mgt(?:-g)?:v?(\d+\.\d+\.\d+)(?:-lts)?(?:$|@)', mgt_image)
    version = match.group(1) if match else None
    return version, mgt_image, running


def semver(value):
    m = VERSION_PATTERN.fullmatch(str(value or ''))
    return tuple(map(int, m.groups())) if m else None


def get_remote_version(lts):
    request = urllib.request.Request(VERSION_URL, headers={'User-Agent': 'linux-update-safeline/2.1'})
    try:
        with urllib.request.urlopen(request, timeout=9) as response:
            data = response.read(65537)
            if len(data) > 65536:
                raise ValueError('Version response exceeds limit')
            obj = json.loads(data)
    except (urllib.error.URLError, TimeoutError, ValueError, OSError, json.JSONDecodeError) as exc:
        warn('Cannot verify official version over HTTPS: {}'.format(type(exc).__name__))
        return None
    if not isinstance(obj, dict):
        return None
    version = obj.get('lts_version' if lts else 'latest_version')
    return version if semver(version) else None


def main():
    installation = get_installation()
    if not installation:
        if ACTION == 'path':
            warn('SafeLine Compose project not detected. Refusing to run installer.')
            return 2
        show('SafeLine not detected; skipped.')
        return 0
    folder, project = installation
    env = safe_env(folder / '.env')
    current, image, running = current_image_version()
    if ACTION == 'path':
        if not running:
            warn('SafeLine has no running containers; use the official manual recovery procedure')
            return 2
        if env is None:
            warn('Cannot read SafeLine .env; run sudo update --safeline or check permissions')
            return 2
        declared = env.get('SAFELINE_DIR', '')
        if declared and (not declared.startswith('/') or str(Path(declared).resolve()) != str(folder.resolve())):
            warn('SAFELINE_DIR does not match the detected install directory; refusing upgrade')
            return 2
        if env.get('RELEASE', '').strip() or env.get('CHANNEL', '').strip().lower() in ('beta', 'lts'):
            warn('Non-default SafeLine release/channel detected; use the channel-specific official updater')
            return 2
        if not current:
            warn('Cannot reliably identify running management version; manual upgrade recommended')
            return 2
        print(str(folder))
        return 0
    if ACTION == 'preflight':
        if env is None or not current or not semver(current):
            warn('Cannot establish current SafeLine version; refusing automated handoff')
            return 2
        if env.get('RELEASE', '').strip() or env.get('CHANNEL', '').strip().lower() in ('beta', 'lts'):
            warn('Non-standard SafeLine release detected; use channel-specific official instructions')
            return 2
        remote = get_remote_version(False)
        if not remote:
            warn('Cannot verify official latest version; do not blindly execute updater')
            return 2
        if semver(current) > semver(remote):
            warn('Installed version is newer than official feed; refusing possible downgrade')
            return 2
        if semver(current) == semver(remote):
            print('ALREADY_CURRENT')
        else:
            print('UPGRADE_TO=' + remote)
        return 0
    if ACTION == 'verify':
        # This deliberately uses only Docker metadata. It must not turn an
        # already successful vendor upgrade into a false failure merely because
        # the invoking user cannot stat /data/safeline/docker-compose.yaml.
        if not running or not current:
            warn('Postflight could not identify a running SafeLine manager')
            return 2
        if EXPECTED_VERSION and semver(current) != semver(EXPECTED_VERSION):
            warn('Postflight version mismatch: running {}, expected {}'.format(current, EXPECTED_VERSION))
            return 2
        show('upgrade verified: running {} ({} containers running)'.format(current, running))
        return 0
    if ACTION == 'local':
        show('running {} ({} containers running)'.format(current or 'unknown', running))
        return 0
    if ACTION == 'remote':
        # When .env is unreadable, the image name can still indicate LTS.
        is_lts = bool((env and '-lts' in env.get('RELEASE', '').lower()) or
                      '-lts' in (image or '').lower())
        remote = get_remote_version(is_lts)
        if remote is None:
            show('version unknown (running: {}; official feed unavailable)'.format(current or 'unknown'))
        else:
            if current and semver(current):
                local_version = semver(current)
                official_version = semver(remote)
                if local_version < official_version:
                    show('update available: {} -> {}'.format(current, remote))
                    show('Run update --safeline after reviewing release notes and scheduling downtime.')
                elif local_version == official_version:
                    show('up to date ({})'.format(current))
                else:
                    show('local version newer than official feed: {} > {} (check channel)'.format(current, remote))
            else:
                show('version unknown (running: {}; official: {})'.format(current or 'unknown', remote))
    return 0


try:
    sys.exit(main())
except RuntimeError as error:
    warn(str(error))
    sys.exit(2)
except (OSError, PermissionError) as error:
    warn('SafeLine metadata access denied/unavailable: {}'.format(type(error).__name__))
    sys.exit(2)
__UPDATE_SAFELINE_PY__
}

safeline_status() {
    action=$1
    have docker || { log 'SafeLine check skipped: Docker not installed.'; return 0; }
    have python3 || { warn 'SafeLine check requires Python 3.'; return 1; }
    get_docker_access || return 1
    section SafeLine
    safeline_python "$action"
}

safeline_upgrade() {
    # This NEVER runs from 'update', '--all', '--docker', '--check' or '--yes'.
    section 'SafeLine official upgrade'
    have bash || { warn 'bash is required by the official SafeLine manager.'; return 1; }
    have curl || { warn 'curl is required to fetch the official SafeLine manager.'; return 1; }
    have python3 || { warn 'Python 3 is required for installation detection.'; return 1; }
    get_docker_access || return 1
    install_dir=$(safeline_python path) || return 1
    # The privileged `path` action already verifies the directory and files.
    [ -n "$install_dir" ] || { warn 'Invalid SafeLine installation directory.'; return 1; }
    sf_ready=$(safeline_python preflight) || return 1
    if [ "$sf_ready" = ALREADY_CURRENT ]; then
        log 'SafeLine is already at the official latest stable version; no manager execution needed.'
        return 0
    fi
    case "$sf_ready" in UPGRADE_TO=*) log "SafeLine ${sf_ready}" ;; *) warn 'Unsafe SafeLine preflight result.'; return 1 ;; esac
    [ -t 0 ] || { warn 'Interactive terminal required. Over SSH, use ssh -tt host update --safeline.'; return 1; }
    log "Detected SafeLine installation: $install_dir"
    log 'Upstream manager: https://waf-ce.chaitin.cn/release/latest/manager.sh'
    warn 'Upgrade restarts SafeLine, temporarily interrupts protected traffic, and may migrate data.'
    warn 'Back up the WAF directory and database, review changelog, and check APISIX/cluster dependencies.'
    safeline_python local || return 1
    umask 077
    sf_work=$(mktemp -d "${TMPDIR:-/tmp}/update-safeline.XXXXXXXX") || return 1
    sf_script=$sf_work/manager.sh
    # A separate subshell makes cleanup robust even on errors and signals.
    (
        trap 'rm -rf "$sf_work"' 0
        trap 'exit 1' 1 2 3 15
        log 'Downloading upstream manager with certificate verification (no curl -k)...'
        curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 90 \
            'https://waf-ce.chaitin.cn/release/latest/manager.sh' -o "$sf_script" || exit 1
        [ -s "$sf_script" ] && bash -n "$sf_script" || {
            warn 'Upstream script was empty or failed shell syntax validation.'; exit 1;
        }
        log "Manager SHA256: $(sha256sum "$sf_script" | awk '{print $1}')"
        printf '[update/safeline] Type UPGRADE SAFELINE to accept service downtime: '
        IFS= read -r confirmation || exit 1
        [ "$confirmation" = 'UPGRADE SAFELINE' ] || {
            warn 'SafeLine update cancelled; no vendor script executed.'; exit 1;
        }
        log 'Invoking official SafeLine manager from its original installation directory.'
        as_root sh -c 'cd "$1" && exec bash "$2"' safeline-updater "$install_dir" "$sf_script" || {
            warn 'Official SafeLine manager returned a failure. Check WAF health and manager logs.'; exit 1;
        }
        log 'Official manager completed. Checking local SafeLine service metadata...'
        expected=${sf_ready#UPGRADE_TO=}
        if ! safeline_python verify "$expected"; then
            warn 'Official manager finished, but post-upgrade verification is inconclusive.'
            warn 'Do NOT retry blindly; inspect running containers and WAF health.'
            exit 3
        fi
    )
}

# SafeLine is a separate, intentionally non-automatable safety boundary.
if [ "$MODE" = safeline-check ]; then
    safeline_status remote || die 'SafeLine status inspection failed.'
    log 'Finished.'
    exit 0
fi
if [ "$MODE" = safeline ]; then
    safeline_upgrade
    safeline_result=$?
    case "$safeline_result" in
        0) ;;
        3) die 'SafeLine updater completed; post-upgrade verification needs manual review (not an upgrade failure).' ;;
        *) die 'SafeLine upgrade was not confirmed completed; review manager logs before retrying.' ;;
    esac
    log 'Finished.'
    exit 0
fi

if [ "$MODE" != docker ] && [ "$MODE" != docker-check ] && [ "$MODE" != docker-discover ]; then
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

# Report SafeLine separately from generic Compose. Do not execute its updater by default.
if have docker && have python3 && { [ "$MODE" = docker-check ] || [ "$CHECK" -eq 1 ]; }; then
    safeline_status remote || warn 'SafeLine version inquiry failed (nonfatal).'
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
        '# Allowed Compose project names (one per line)' \
        '# Check: update --docker-discover' \
        '# Example: subconverter' |
        as_root tee "$ALLOWLIST" >/dev/null || err 'Could not create the Compose allowlist.'
    as_root chmod 644 "$ALLOWLIST" || err 'Could not set allowlist permissions.'
fi

say "Installed/updated $DEST (version $VERSION)"
say "Project allowlist: $ALLOWLIST (legacy $LEGACY_ALLOWLIST remains supported)"
case ":${PATH:-}:" in
    *:"$INSTALL_DIR":*) say 'Ready: update --check' ;;
    *) say "Note: $INSTALL_DIR is not in PATH; use $DEST or add this directory to PATH." ;;
esac
