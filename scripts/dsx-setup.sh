#!/usr/bin/env bash
# dsx-setup.sh — PROVISION the DSX Blueprint on a fresh Brev instance.
#
#   Installs deps, pulls + extracts the NGC content pack, clones the blueprint,
#   points the scene at the local pack, builds, and records state in ~/.dsx/config.
#   It does NOT launch anything — that's dsx-run.sh, so the booth can restart the
#   demo (runbook §7 Levels 2/3) without re-running provisioning.
#
#   Target: Ubuntu 22.04/24.04, x86, RTX Pro 6000 Blackwell (RT cores).
#   Run:    bash dsx-setup.sh && bash dsx-run.sh start
#           (usually driven from your laptop by launch-dsx-brev.sh)
#
#   Env:  NGC_API_KEY     REQUIRED — pulls the ~33 GB content pack.
#         NVIDIA_API_KEY  optional — AI-agent extension only; persisted to ~/.dsx/env
#                                    (600) so dsx-run.sh can re-export it on restart.
#         DSX_DATA_DIR    optional — content-pack location   (default /data/dsx)
#         DSX_WORKDIR     optional — blueprint checkout      (default ~/omniverse-...)
#         DSX_SKIP_BUILD  DEFAULT 1 since 2026-09-02 — the pre-build is skipped
#                         and run_streaming.sh builds on first launch. That is
#                         the plain README path and it resolves livestream
#                         9.1.0/9.2.0 (streams); ./repo.sh build here resolved
#                         9.0.0 (cannot stream). See [6/7].
#         DSX_PREBUILD    optional — set to 1 to force the old ./repo.sh build.
#         DSX_PORTS_DECLARED  optional — set to 1 when something upstream has
#                             already declared the ports (a Brev Launchable does;
#                             the CLI path does not). Suppresses the "open the
#                             firewall by hand" notice, which is wrong there.
#
#   Idempotent: safe to re-run. Skips the download/clone/build if already present.
set -euo pipefail

REPO_URL="https://github.com/NVIDIA-Omniverse-blueprints/omniverse-dsx-blueprint-for-ai-factories.git"
WORKDIR="${DSX_WORKDIR:-$HOME/omniverse-dsx-blueprint-for-ai-factories}"
# Content pack location. PREFER THE ROOT VOLUME when it has room: it survives a
# Brev stop/start, where /opt/dlami/nvme (instance-store) is WIPED and costs a
# 33 GB re-download. Root volume size varies a lot between instances -- 248 GB
# (196 free) and 117 GB (64 free) both observed -- so choose at runtime rather
# than hardcoding either. Needs ~70 GB for archive + extraction.
pick_data_dir() {
  local root_avail
  root_avail="$(df -BG --output=avail / 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
  if [ "${root_avail:-0}" -ge 80 ]; then
    echo "/data/dsx"
  elif [ -d /opt/dlami/nvme ]; then
    echo "/opt/dlami/nvme/dsx"
  else
    echo "/data/dsx"
  fi
}
DATA_DIR="${DSX_DATA_DIR:-$(pick_data_dir)}"
# Where NGC drops the ~33 GB archive. Split from DATA_DIR so the download can land
# on a big fast scratch disk while the EXTRACTED scene lives somewhere persistent —
# on AWS g7e the 1.7 TB /opt/dlami/nvme is instance-store and is wiped by a stop/start,
# while the root volume survives but has only ~64 GB free (too tight for both).
DOWNLOAD_DIR="${DSX_DOWNLOAD_DIR:-$DATA_DIR}"
CONTENT_PACK="nvidia/omniverse/dsx_dataset:2.1"
NGC_CLI_URL="https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/4.34.10/files/ngccli_linux.zip"
STATE_DIR="$HOME/.dsx"

# ---------------------------------------------------------------------------
# ports — THE CONTRACT THIS SHARES WITH THE LAUNCHABLE
# ---------------------------------------------------------------------------
# The three ports the demo needs reachable from outside. How they get opened is
# the ONE thing that differs between the two ways of running this:
#   * CLI path (launch-dsx-brev.sh) — opened BY HAND in the Brev dashboard.
#     No brev CLI command edits firewall rules; `brev port-forward` is TCP-only
#     and so cannot carry the media port.
#   * Launchable — a declared field of the Launchable itself. These are the
#     numbers to put in that field; nothing is manual.
# Keep in agreement with dsx-run.sh and launch-dsx-brev.sh.
WEB_PORT=8081
SIGNAL_PORT=49100
MEDIA_PORT=47998
PORTS_DECLARED="${DSX_PORTS_DECLARED:-0}"

ports_table() {
  local i="${1:-    }"
  printf '%s%-7s web UI      TCP\n' "$i" "$WEB_PORT"
  printf '%s%-7s signaling   TCP\n' "$i" "$SIGNAL_PORT"
  printf '%s%-7s media       TCP *and* UDP   <-- UDP carries the video\n' "$i" "$MEDIA_PORT"
}

ME="$(id -un)"                                   # $USER is unset in non-login/Launchable shells
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"     # a Launchable setup script runs as root, where sudo may not exist

# The NGC CLI animates a progress bar even when stdout is NOT a tty, so a
# redirected provisioning log fills with ANSI redraw frames. Measured live
# 2026-09-01: 303 of 800 log lines were progress frames, and they drown every
# real message in both the live follow and the post-mortem. Collapse the frames
# (split on CR, strip ANSI, drop the redraw lines); real output passes through.
# Download success is not inferred from this output anyway -- the archive is
# validated with `unzip -l` before use.
strip_progress() {
  # 's/.*\r//' keeps only what a terminal would finally show on each line, which
  # is the correct emulation and also drops the redraw history in one step.
  sed -u -e 's/.*\r//' -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | grep -v -E --line-buffered 'Remaining:.*Elapsed:|^[[:space:]]*$'
  return 0
}

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

: "${NGC_API_KEY:?NGC_API_KEY must be set (org secret / Launch Parameter / env)}"

# ---------------------------------------------------------------------------
log "[0/7] sanity checks"
# ---------------------------------------------------------------------------
. /etc/os-release 2>/dev/null || true
info "OS: ${PRETTY_NAME:-unknown}"
case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  25.04) die "Ubuntu 25.04 is not supported by DSX (runbook §1) — reimage to 22.04 or 24.04." ;;
  *)     warn "untested OS version '${VERSION_ID:-?}' — DSX targets Ubuntu 22.04 / 24.04." ;;
esac

if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
  DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  info "GPU: ${GPU_NAME:-<none>}  driver: ${DRIVER:-?}"
  case "$GPU_NAME" in
    *"RTX PRO 6000"*|*"RTX Pro 6000"*) ;;
    *) warn "this is NOT an RTX Pro 6000 Blackwell. DSX needs RT cores; rendering fidelity" \
            "and performance are UNVALIDATED on '${GPU_NAME:-unknown}'. (runbook §1)" ;;
  esac
  # driver floor is 570.169: if the OLDEST of {driver, 570.169} isn't 570.169, the driver is too old
  if [ -n "$DRIVER" ]; then
    [ "$(printf '%s\n570.169\n' "$DRIVER" | sort -V | head -n1)" = "570.169" ] \
      || warn "driver $DRIVER is below the 570.169 floor — expect GPU errors on start (runbook §1)."
  fi
else
  warn "nvidia-smi not found — no GPU visible in this instance. Kit will hang at renderer init (runbook §8)."
fi

# Early topology warning. dsx-run.sh does the authoritative check, but catching a
# pod-mapped instance here saves ~40 min of provisioning down the wrong path.
BREV_CTX="/etc/brev/environment-context.json"
if [ -f "$BREV_CTX" ] && grep -q '"ports"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]' "$BREV_CTX"; then
  warn "$BREV_CTX lists remapped ports => this looks like the POD-MAPPED Brev topology."
  warn "The primaryStream.publicIp recipe these scripts use applies to a DIRECT-PUBLIC-IP VM."
  warn "See runbook 'Brev gotcha 3 — SOLVED recipe for the POD-MAPPED topology' before relying on this."
fi

# Said up front, not only in the completion banner. On the CLI path, opening the
# firewall is the one step here a human has to do in a browser, and everything
# below buys 30-45 minutes in which to do it. Left to the end it gets discovered
# the expensive way: a build that worked and a viewport that stays black.
if [ "$PORTS_DECLARED" = "1" ]; then
  info "ports $WEB_PORT/TCP, $SIGNAL_PORT/TCP, $MEDIA_PORT/TCP+UDP: declared upstream, nothing to open"
  info "  (not verifiable from in here — if the viewport is black, check $MEDIA_PORT/UDP first)"
else
  cat <<PORTS

------------------------------------------------------------
NOW, WHILE THIS RUNS — open these ports for this instance in the
Brev dashboard (TCP/UDP Ports). No brev CLI command does it:

$(ports_table)

Provisioning needs none of them open. 'dsx-run.sh start' does.

(A Launchable declares these instead of you opening them; on that
 path set DSX_PORTS_DECLARED=1 and this notice goes away.)
------------------------------------------------------------
PORTS
fi

# ---------------------------------------------------------------------------
log "[1/7] system deps (GL/X, git-lfs, node 20, build tools, tmux)"
# ---------------------------------------------------------------------------
# A freshly-booted cloud image is usually still running its own apt work
# (cloud-init, unattended-upgrades). Racing it fails with
#   E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process N
# and aborts provisioning ~10 seconds in. DPkg::Lock::Timeout (apt 2.0+, so
# fine on 22.04/24.04) makes apt WAIT for the lock instead of failing; the
# retry loop covers the apt-lists lock and transient mirror errors.
APT_LOCK_WAIT=600

# Single attempt, no retry. For probing whether a package exists at all.
apt_try() { $SUDO apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT" "$@"; }

# Retries ONLY transient failures. A real error — an unknown package, say — must
# fail immediately: retrying `install libxt6` ten times on 24.04 (where it is
# libxt6t64) would burn five minutes before reaching the fallback.
apt_get() {
  local tries=0 max=10 out rc
  while :; do
    # `|| rc=$?` is required: under `set -e` an assignment whose command
    # substitution fails aborts the script before `rc=$?` is ever reached.
    rc=0
    out="$($SUDO apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT" "$@" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    [ "$rc" -eq 0 ] && return 0
    case "$out" in
      *"Could not get lock"*|*"Unable to acquire"*|*"Temporary failure resolving"*|\
      *"Connection failed"*|*"Hash Sum mismatch"*|*"Could not connect"*|*"Undetermined Error"*)
        tries=$((tries+1))
        if [ "$tries" -ge "$max" ]; then
          warn "apt-get $1: still failing after $max attempts"
          return "$rc"
        fi
        warn "apt-get $1: transient failure (dpkg lock / mirror) — retry $tries/$max in 30s"
        sleep 30 ;;
      *)
        return "$rc" ;;
    esac
  done
}

info "waiting for any boot-time apt/unattended-upgrades to release the dpkg lock..."
$SUDO apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT" check >/dev/null 2>&1 || true

apt_get update

# The GL/X bundle Kit needs on a headless image (runbook §3).
apt_get install -y \
  libglu1-mesa libgl1 libxrandr2 libxinerama1 libxcursor1 libxi6 libxext6 \
  libsm6 libice6 libxkbcommon0 \
  build-essential curl wget ca-certificates unzip tmux

# libxt6 is installed SEPARATELY on purpose: Ubuntu 24.04's t64 transition renamed it
# to libxt6t64, and folding it into the bundle above means one missing package takes
# the whole GL install down with it -- which silently reintroduces the
# "cannot open shared object" wall (runbook §3).
apt_try install -y libxt6 || apt_get install -y libxt6t64

if ! command -v git-lfs >/dev/null 2>&1; then
  curl -fsSL https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | $SUDO bash
  apt_get install -y git-lfs
fi
git lfs install

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash -
  apt_get install -y nodejs
fi
info "node $(node --version 2>/dev/null || echo '<missing>') · git-lfs $(git lfs version 2>/dev/null | head -n1 || echo '<missing>')"

# ---------------------------------------------------------------------------
log "[2/7] NGC CLI"
# ---------------------------------------------------------------------------
if ! command -v ngc >/dev/null 2>&1; then
  # Installed under /opt, NOT /tmp: a /tmp symlink dies on reboot or tmp-clean,
  # which would break any later re-provision.
  wget -q --content-disposition "$NGC_CLI_URL" -O /tmp/ngccli.zip
  $SUDO rm -rf /opt/ngc-cli
  $SUDO unzip -qo /tmp/ngccli.zip -d /opt
  $SUDO chmod u+x /opt/ngc-cli/ngc
  $SUDO ln -sf /opt/ngc-cli/ngc /usr/local/bin/ngc
  rm -f /tmp/ngccli.zip
fi
mkdir -p "$HOME/.ngc"
( umask 077
  printf '[CURRENT]\napikey = %s\nformat_type = ascii\norg = nvidia\n' "$NGC_API_KEY" > "$HOME/.ngc/config" )
chmod 600 "$HOME/.ngc/config"
info "ngc $(ngc --version 2>/dev/null | head -n1 || echo '?')"

# ---------------------------------------------------------------------------
log "[3/7] content pack (~33 GB) -> $DATA_DIR"
# ---------------------------------------------------------------------------
$SUDO mkdir -p "$DATA_DIR"
$SUDO chown "$ME" "$DATA_DIR"
if [ "$DOWNLOAD_DIR" != "$DATA_DIR" ]; then
  $SUDO mkdir -p "$DOWNLOAD_DIR"
  $SUDO chown "$ME" "$DOWNLOAD_DIR"
  info "download dir: $DOWNLOAD_DIR  (archive)"
  info "extract  dir: $DATA_DIR      (scene)"
fi

AVAIL_GB="$(df -BG --output=avail "$DATA_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
info "free space on $DATA_DIR: ${AVAIL_GB:-?} GB"
if [ "${AVAIL_GB:-0}" -lt 60 ]; then
  warn "under 60 GB free on $DATA_DIR — the pack is ~33 GB (and extraction needs about that much again)."
  # Many GPU cloud images keep a small root volume and a large instance-store NVMe.
  BIGGEST="$(df -BG --output=avail,target 2>/dev/null | tail -n +2 \
             | grep -vE '/(dev|proc|sys|run|boot)' | sort -rn | head -n1 || true)"
  if [ -n "$BIGGEST" ]; then
    warn "the largest mount on this box is: $BIGGEST"
    warn "re-run with DSX_DATA_DIR pointing there, e.g.:"
    warn "  DSX_DATA_DIR=$(echo "$BIGGEST" | awk '{print $2}' || true)/dsx bash dsx-setup.sh"
    warn "⚠️ if that mount is instance-store/ephemeral it is WIPED by a stop/start —"
    warn "   fine for the pack (re-downloadable), and dsx-run.sh will tell you if it vanishes."
  fi
fi

find_scene() { find "$DATA_DIR" -name 'DSX_Main_BP.usda' -print -quit 2>/dev/null; }

PACK_LEAF="${CONTENT_PACK##*/}"                                  # dsx_dataset:2.1
PACK_DIR="$DOWNLOAD_DIR/${PACK_LEAF%%:*}_v${PACK_LEAF##*:}"      # …/dsx_dataset_v2.1

SCENE="$(find_scene)"
if [ -z "$SCENE" ]; then
  # An interrupted run (instance stopped, network drop) leaves a TRUNCATED archive.
  # Without this check the bare existence of $PACK_DIR was taken as "already
  # downloaded", and the failure surfaced much later as a confusing unzip error.
  # `unzip -l` only reads the central directory — which lives at the END of the
  # file — so it is fast even on 33 GB and detects truncation exactly.
  NEED_DOWNLOAD=1
  if [ -d "$PACK_DIR" ]; then
    ARCHIVES=0; BAD=0
    while IFS= read -r z; do
      ARCHIVES=$((ARCHIVES+1))
      if unzip -l "$z" >/dev/null 2>&1; then :; else
        warn "incomplete/corrupt archive: $z"; BAD=1
      fi
    done < <(find "$PACK_DIR" -maxdepth 3 -name '*.zip' 2>/dev/null)
    if [ "$ARCHIVES" -gt 0 ] && [ "$BAD" -eq 0 ]; then
      info "pack already downloaded and intact at $PACK_DIR — skipping download"
      NEED_DOWNLOAD=0
    else
      warn "re-downloading (previous attempt was interrupted)"
      rm -rf "$PACK_DIR"
    fi
  fi
  if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    info "downloading $CONTENT_PACK (~33 GB; the long pole)"
    # pipefail is set, so the subshell's status still governs despite the filter
    ( cd "$DOWNLOAD_DIR" && ngc registry resource download-version "$CONTENT_PACK" ) 2>&1 \
      | strip_progress
  fi
  # The pack ships as an archive; without this the scene never lands on disk.
  while IFS= read -r z; do
    zsize="$(du -m "$z" 2>/dev/null | cut -f1 || true)"
    dest_avail="$(df -BM --output=avail "$DATA_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
    info "extracting $(basename "$z") (${zsize:-?} MB) -> $DATA_DIR (${dest_avail:-?} MB free)"
    if [ -n "${zsize:-}" ] && [ -n "${dest_avail:-}" ] && [ "$dest_avail" -lt "$zsize" ]; then
      die "not enough room in $DATA_DIR to extract $(basename "$z").
  archive is ${zsize} MB, destination has ${dest_avail} MB free.
  Re-run pointing DSX_DATA_DIR at a bigger filesystem, e.g.:
    DSX_DATA_DIR=/opt/dlami/nvme/dsx DSX_DOWNLOAD_DIR=/opt/dlami/nvme/dsx bash dsx-setup.sh"
    fi
    unzip -qn "$z" -d "$DATA_DIR"
  done < <(find "$DOWNLOAD_DIR" -maxdepth 4 -name '*.zip' 2>/dev/null)
  SCENE="$(find_scene)"
fi
[ -n "$SCENE" ] || die "DSX_Main_BP.usda not found under $DATA_DIR after download+extract.
  Inspect what NGC actually delivered:  find '$DATA_DIR' -maxdepth 3 | head -50"
info "scene: $SCENE"

# ---------------------------------------------------------------------------
log "[4/7] clone blueprint"
# ---------------------------------------------------------------------------
if [ -d "$WORKDIR/.git" ]; then
  info "already cloned at $WORKDIR"
else
  git clone "$REPO_URL" "$WORKDIR"
fi
cd "$WORKDIR"

# ---------------------------------------------------------------------------
log "[5/7] patch source config (scene path + vite host check)"
# ---------------------------------------------------------------------------
# auto_load_usd defaults to a remote Nucleus URL a Brev box can't reach -> ~130 s
# hang then failure (runbook Brev gotcha 0). Repoint the SOURCE .kit files so the
# fix survives a rebuild; dsx-run.sh additionally patches the BUILT copy, which is
# what repo.sh launch actually reads (runbook BUILD-COPY GOTCHA).
PATCHED=0
while IFS= read -r kitfile; do
  sed -i -E "s|^([[:space:]]*auto_load_usd[[:space:]]*=[[:space:]]*).*|\1\"$SCENE\"|" "$kitfile"
  if grep -q "auto_load_usd.*$SCENE" "$kitfile"; then
    info "scene path set in $kitfile"
    PATCHED=$((PATCHED+1))
  fi
done < <(grep -rl 'auto_load_usd' source 2>/dev/null || true)
[ "$PATCHED" -gt 0 ] || warn "no source .kit file had an auto_load_usd key — dsx-run.sh will still pass it as a CLI override, but verify with: grep -rn auto_load_usd '$WORKDIR/source'"

VITE="web/vite.config.ts"
if [ -f "$VITE" ]; then
  if grep -q 'allowedHosts' "$VITE"; then
    info "vite allowedHosts already present"
  else
    # sed exits 0 even when nothing matched, so verify with grep rather than trusting $?
    sed -i 's/server:[[:space:]]*{/server: { allowedHosts: true,/' "$VITE"
    if grep -q 'allowedHosts' "$VITE"; then
      info "vite allowedHosts added (Brev gotcha 1)"
    else
      warn "could not patch $VITE — if the web UI is blocked by a host check, add 'allowedHosts: true' to its server:{} block by hand."
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "[6/7] build (15-20 min on a cold instance)"
# ---------------------------------------------------------------------------
# ⚠️ DEFAULT CHANGED 2026-09-02: we now SKIP this pre-build.
# `./repo.sh build` here resolved livestream app-9.0.0/core-9.0.0/webrtc-9.1.1,
# which CANNOT stream (the primaryStream.publicIp setting is silently ignored on
# 9.0.0, so Kit advertises only private ICE candidates). A plain
# `./run_streaming.sh`, which builds on first launch, resolved 9.1.0/9.1.0/9.2.0
# and streamed successfully. `dsx_streaming.kit` sets no version constraint, so
# the versions come from the registry and the two build paths differ.
# Set DSX_PREBUILD=1 to restore the old behaviour (and see the version guard).
if [ "${DSX_SKIP_BUILD:-1}" = "1" ] && [ "${DSX_PREBUILD:-0}" != "1" ]; then
  info "skipping pre-build — run_streaming.sh builds on first launch (resolves"
  info "  livestream 9.1.0/9.2.0, which is the combination that can stream)"
elif [ -d "_build" ]; then
  info "_build already present — skipping (delete it to force a rebuild)"
elif [ -x ./repo.sh ]; then
  # The build tree lands next to the checkout, which is usually the small root
  # volume -- on a g7e the DLAMI image already uses ~53 GB of 117 GB, and the
  # build itself consumed ~28 GB on the 2026-08-31 run. Fail early and clearly
  # rather than halfway through a 20-minute build.
  BUILD_AVAIL_GB="$(df -BG --output=avail "$WORKDIR" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
  info "free space for the build on $(df --output=target "$WORKDIR" 2>/dev/null | tail -n1 || echo '?'): ${BUILD_AVAIL_GB:-?} GB"
  if [ -n "${BUILD_AVAIL_GB:-}" ] && [ "$BUILD_AVAIL_GB" -lt 40 ]; then
    warn "under 40 GB free — the build needed ~28 GB when last measured, and the"
    warn "shader cache grows on top of that. If this fails with ENOSPC, put the"
    warn "checkout on a bigger filesystem:"
    warn "  DSX_WORKDIR=<big-mount>/dsx-build bash dsx-setup.sh"
    warn "(note: on instance-store that is wiped by a stop/start, costing a rebuild)"
  fi
  if ./repo.sh build; then
    info "build OK"
    # ---- livestream version guard -----------------------------------------
    # 2026-09-01: THE streaming bug. `dsx_streaming.kit` declares
    #   "omni.kit.livestream.app" = {}
    # with NO version constraint, so it resolves against the remote registry.
    # A plain `./run_streaming.sh` build (the README path) resolved
    #   app-9.1.0 / core-9.1.0 / webrtc-9.2.0   -> streaming WORKS
    # while every build made through this script resolved
    #   app-9.0.0 / core-9.0.0 / webrtc-9.1.1   -> streaming CANNOT work
    # On 9.0.0 the primaryStream.publicIp setting is accepted and does nothing,
    # so Kit advertises only private ICE candidates and media never connects.
    # Root cause of the version difference is NOT yet known -- prime suspect is
    # `./repo.sh build` here versus run_streaming.sh's own build path.
    # NOTE: this only runs on the DSX_PREBUILD=1 path. The authoritative check
    # is check_livestream_versions() in dsx-run.sh, which reads the Kit log after
    # launch -- the versions are not knowable until Kit loads its extensions.
    # Fail loudly rather than hand over a build that cannot stream.
    LS_VERS="$(find "$WORKDIR/_build" "$HOME/.local/share/ov/data/exts" \
                 -maxdepth 6 -name 'omni.kit.livestream.*-9*' -printf '%f\n' 2>/dev/null \
               | sed 's/+.*//' | sort -u | tr '\n' ' ')"
    info "livestream extensions resolved: ${LS_VERS:-<none found>}"
    case "$LS_VERS" in
      *app-9.0.0*|*core-9.0.0*)
        warn "🔴 livestream 9.0.0 resolved — STREAMING WILL NOT WORK with this build."
        warn "   Need app-9.1.0 / core-9.1.0 / webrtc-9.2.0. On 9.0.0 the"
        warn "   primaryStream.publicIp setting is silently ignored, Kit advertises"
        warn "   only private ICE candidates, and the browser stalls at 'checking'."
        warn "   Workaround that is KNOWN to produce the newer set: skip this"
        warn "   pre-build entirely (DSX_SKIP_BUILD=1) and let ./run_streaming.sh"
        warn "   build on first launch, which is the plain README path." ;;
      *app-9.1.0*) info "✅ livestream 9.1.0/9.2.0 — the combination proven to stream" ;;
    esac
  else
    warn "'./repo.sh build' failed. dsx-run.sh will fall back to letting run_streaming.sh"
    warn "build on first launch, but read the output above first — this is usually a real error."
  fi
else
  info "no repo.sh — run_streaming.sh will build on first launch"
fi

# ---------------------------------------------------------------------------
log "[7/7] record state for dsx-run.sh"
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/config" <<CFG
# written by dsx-setup.sh on $(date -Is)
DSX_WORKDIR="$WORKDIR"
DSX_DATA_DIR="$DATA_DIR"
DSX_DOWNLOAD_DIR="$DOWNLOAD_DIR"
DSX_SCENE="$SCENE"
CFG
info "state: $STATE_DIR/config"

if [ -n "${NVIDIA_API_KEY:-}" ]; then
  # Persisted so a restart still has it -- the old script accepted this variable
  # and then dropped it, so the agent extension died on any relaunch.
  ( umask 077; printf 'export NVIDIA_API_KEY=%s\n' "$NVIDIA_API_KEY" > "$STATE_DIR/env" )
  chmod 600 "$STATE_DIR/env"
  info "NVIDIA_API_KEY persisted to $STATE_DIR/env (600) for the AI-agent extension"
fi

if [ "$PORTS_DECLARED" = "1" ]; then
  PORTS_NOTE="OK  Ports $WEB_PORT/TCP, $SIGNAL_PORT/TCP, $MEDIA_PORT/TCP+UDP are declared upstream —
    nothing to open by hand."
else
  PORTS_NOTE="⚠️  IF YOU HAVE NOT ALREADY (this was flagged at the start of provisioning) —
    expose these ports for this instance in the Brev dashboard. No brev CLI
    command opens the firewall:
$(ports_table '      ')
    Without $MEDIA_PORT/UDP the page loads and the viewport stays black."
fi

cat <<EOF

============================================================
PROVISIONING COMPLETE — nothing is running yet.

  Start it:   bash dsx-run.sh start      # waits for "RTX Ready"
  Then:       bash dsx-run.sh status

  Workdir : $WORKDIR
  Scene   : $SCENE

$PORTS_NOTE
============================================================
EOF
