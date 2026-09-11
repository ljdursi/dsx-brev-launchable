#!/usr/bin/env bash
# dsx-launchable-setup.sh — setup script for a Brev Launchable running the
# NVIDIA Omniverse DSX Blueprint for AI Factory Digital Twins.
#
#   Brev VM Mode runs this automatically, AS ROOT, after the instance starts.
#   It is self-contained: it clones the public blueprint itself and needs
#   nothing else from this repo, so it works pasted into the dashboard or
#   cloned from a repo.
#
#   LAUNCH PARAMETERS (Brev passes these in as environment variables):
#     NGC_API_KEY     REQUIRED. Define it with NO DEFAULT and back it with an
#                     organization secret -- never a parameter default.
#     NVIDIA_API_KEY  optional. AI-agent extension only; the 3D viewer,
#                     camera controls and configurator all work without it.
#     DSX_INSTANCE_NAME optional. Brev display name used only in the printed
#                     post-resume command. Falls back to Brev's stable env ID.
#
#   PORTS the Launchable must declare (see README-LAUNCHABLE.md):
#     8081/TCP  web UI      49100/TCP  signalling      47998/TCP+UDP  media
#     8012/TCP  AI agent
#   47998 MUST include UDP. Without it the page loads, the globe renders
#   (that is drawn client-side) and the viewport stays black.
#
#   ⚠️ ONE VIEWER AT A TIME. primaryStream serves a single interactive client;
#   a second browser can kick the first (NVST_R_BUSY). Note that restricting the
#   port rules to the deploying host does NOT work (tested 2026-09-02: every
#   port timed out) -- use "all IPs" and control access above the network.
set -uo pipefail

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

: "${NGC_API_KEY:?NGC_API_KEY launch parameter is required (back it with an org secret)}"

# A Launchable setup script runs as root and sudo may be absent; the CLI path
# runs as a normal user and needs it. Support both.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Kit must not run as root. Find the real desktop/login user to run it as.
APP_USER="${DSX_APP_USER:-}"
if [ -z "$APP_USER" ]; then
  for u in ubuntu brev nvidia; do id "$u" >/dev/null 2>&1 && { APP_USER="$u"; break; }; done
fi
[ -n "$APP_USER" ] || APP_USER="$(id -un)"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
[ -n "$APP_HOME" ] || die "could not determine a home directory for '$APP_USER'"
info "app user: $APP_USER ($APP_HOME)"

REPO_URL="https://github.com/NVIDIA-Omniverse-blueprints/omniverse-dsx-blueprint-for-ai-factories.git"
WORKDIR="$APP_HOME/omniverse-dsx-blueprint-for-ai-factories"
CONTENT_PACK="nvidia/omniverse/dsx_dataset:2.1"
RUNTIME_SCRIPT_URL="https://raw.githubusercontent.com/ljdursi/dsx-brev-launchable/v1/scripts/dsx-run.sh"
STATE_DIR="$APP_HOME/.dsx"
RESTART_TARGET="${DSX_INSTANCE_NAME:-${BREV_ENV_ID:-<instance-name>}}"

# ---------------------------------------------------------------------------
log "[1/6] system dependencies"
# ---------------------------------------------------------------------------
# A freshly booted cloud image is often still running cloud-init/unattended
# upgrades. DPkg::Lock::Timeout makes apt WAIT rather than fail ~10s in.
APT="$SUDO apt-get -o DPkg::Lock::Timeout=600"
$APT update -y >/dev/null 2>&1 || true

# ⚠️ The GL/X bundle is NOT in the blueprint README, and Kit will not start
# without it on a headless cloud image: "libXt.so.6: cannot open shared object".
$APT install -y \
  libglu1-mesa libgl1 libxrandr2 libxinerama1 libxcursor1 libxi6 libxext6 \
  libsm6 libice6 libxkbcommon0 \
  build-essential curl wget ca-certificates unzip tmux git python3-pip \
  || die "dependency install failed"

# Installed separately on purpose: Ubuntu 24.04's t64 transition renamed this to
# libxt6t64, and folding it into the line above means one missing package takes
# the whole GL install down with it.
$APT install -y libxt6 || $APT install -y libxt6t64 || warn "no libxt6/libxt6t64 — Kit may fail to start"

if ! command -v git-lfs >/dev/null 2>&1; then
  curl -fsSL https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | $SUDO bash >/dev/null 2>&1
  $APT install -y git-lfs || warn "git-lfs install failed"
fi
sudo -u "$APP_USER" git lfs install >/dev/null 2>&1 || true

# The blueprint needs Node 20+/npm 9+; Ubuntu's own package is far too old.
if ! command -v node >/dev/null 2>&1 || [ "$(node -v 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)" -lt 20 ] 2>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash - >/dev/null 2>&1
  $APT install -y nodejs || die "node install failed"
fi
info "node $(node --version 2>/dev/null) · npm $(npm --version 2>/dev/null)"

# ---------------------------------------------------------------------------
log "[2/6] NGC CLI + content pack location"
# ---------------------------------------------------------------------------
# The DLAMI usually ships the NGC CLI already; install only if missing.
if ! command -v ngc >/dev/null 2>&1; then
  wget -q --content-disposition \
    "https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/4.34.10/files/ngccli_linux.zip" \
    -O /tmp/ngccli.zip || die "NGC CLI download failed"
  $SUDO rm -rf /opt/ngc-cli && $SUDO unzip -q /tmp/ngccli.zip -d /opt \
    && $SUDO ln -sf /opt/ngc-cli/ngc /usr/local/bin/ngc
fi
info "ngc $(ngc --version 2>/dev/null | head -1)"

# ⚠️ NOT in the blueprint README: the CLI needs an ORG or the download fails
# with "Missing org - If Authenticated, org is also required."
# Written with umask 077. Retained after setup so a re-download works without a
# re-deploy; DSX_SHRED_NGC_CONFIG=1 removes it once the pack is down.
# (An NGC_CLI_ORG=nvidia env var may avoid the on-disk config entirely, but that
# is untested; this file form is the one proven to work.)
$SUDO -u "$APP_USER" mkdir -p "$APP_HOME/.ngc"
$SUDO -u "$APP_USER" bash -c "umask 077; printf '[CURRENT]\napikey = %s\nformat_type = ascii\norg = nvidia\n' '$NGC_API_KEY' > '$APP_HOME/.ngc/config'"

# Prefer the ROOT volume when it has room: it survives a stop/start, whereas
# /opt/dlami/nvme is instance-store and is WIPED, costing a 33 GB re-download.
# Root volume size varies a lot between instances (248 GB and 117 GB both seen),
# so decide at runtime. Needs ~70 GB for the archive plus its extraction.
ROOT_AVAIL="$(df -BG --output=avail / 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
if [ "${ROOT_AVAIL:-0}" -ge 80 ]; then
  DATA_DIR=/data/dsx
  info "root volume has ${ROOT_AVAIL} GB free — using $DATA_DIR (survives a stop/start)"
elif [ -d /opt/dlami/nvme ]; then
  DATA_DIR=/opt/dlami/nvme/dsx
  warn "root volume has only ${ROOT_AVAIL} GB free — using $DATA_DIR"
  warn "  (instance-store: a stop/start WIPES this and costs a 33 GB re-download)"
else
  DATA_DIR=/data/dsx
  warn "only ${ROOT_AVAIL} GB free on / and no instance store — this may fail"
fi
$SUDO mkdir -p "$DATA_DIR" && $SUDO chown "$APP_USER" "$DATA_DIR"

# ---------------------------------------------------------------------------
log "[3/6] content pack (~33 GB)"
# ---------------------------------------------------------------------------
SCENE="$(find "$DATA_DIR" -name DSX_Main_BP.usda 2>/dev/null | head -1)"
if [ -z "$SCENE" ]; then
  ARCHIVE="$(find "$DATA_DIR" -name '*.zip' 2>/dev/null | head -1)"
  # An interrupted download leaves a truncated zip that a "directory exists"
  # check would happily accept. unzip -l reads the central directory (at the END
  # of the file), so it detects truncation and is fast even on 33 GB.
  if [ -n "$ARCHIVE" ] && ! unzip -l "$ARCHIVE" >/dev/null 2>&1; then
    warn "existing archive is truncated — removing and re-downloading"
    rm -f "$ARCHIVE"; ARCHIVE=""
  fi
  if [ -z "$ARCHIVE" ]; then
    info "downloading $CONTENT_PACK"
    # The NGC CLI animates a progress bar even when stdout is NOT a tty, which
    # floods a Launchable's log with ANSI redraw frames. Keep only the final
    # state of each line and drop the frames.
    $SUDO -u "$APP_USER" bash -c "cd '$DATA_DIR' && ngc registry resource download-version '$CONTENT_PACK'" 2>&1 \
      | sed -u -e 's/.*\r//' -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
      | grep -v -E 'Remaining:.*Elapsed:|^[[:space:]]*$' || true
    ARCHIVE="$(find "$DATA_DIR" -name '*.zip' 2>/dev/null | head -1)"
  fi
  [ -n "$ARCHIVE" ] || die "content pack download produced no archive"
  info "extracting $(basename "$ARCHIVE")"
  $SUDO -u "$APP_USER" unzip -qn "$ARCHIVE" -d "$DATA_DIR" || die "extraction failed"
  # ⚠️ The archive expands with an EXTRA directory level -- the scene is at
  # <extract>/DSX_BP_/DSX_BP/Assembly/, not <extract>/DSX_BP/Assembly/ as the
  # README's example implies. Never hardcode it; find it.
  SCENE="$(find "$DATA_DIR" -name DSX_Main_BP.usda 2>/dev/null | head -1)"
fi
[ -n "$SCENE" ] || die "DSX_Main_BP.usda not found under $DATA_DIR after download+extract"
info "scene: $SCENE"

# The NGC credential stays in ~/.ngc/config by DESIGN: it is expected to be a
# READ-ONLY key on a VM that is stopped when idle and revoked when the demo is
# retired. Keeping it means a stop/start that wipes the instance-store content
# pack can re-download without re-deploying. Set DSX_SHRED_NGC_CONFIG=1 if your
# threat model differs.
# The real risk is a key committed to a searchable public repo -- which is why
# it lives in a Brev org secret and reaches this script as a launch parameter,
# and never appears in any file under version control.
if [ "${DSX_SHRED_NGC_CONFIG:-0}" = "1" ] && [ -f "$APP_HOME/.ngc/config" ]; then
  shred -u "$APP_HOME/.ngc/config" 2>/dev/null || rm -f "$APP_HOME/.ngc/config"
  info "NGC credential shredded (DSX_SHRED_NGC_CONFIG=1)"
fi

# ---------------------------------------------------------------------------
log "[4/6] blueprint checkout + scene wiring"
# ---------------------------------------------------------------------------
if [ ! -d "$WORKDIR/.git" ]; then
  $SUDO -u "$APP_USER" git clone --quiet "$REPO_URL" "$WORKDIR" || die "git clone failed"
fi
# Submodules (deps/kit-cae, deps/kit-usd-agents) initialise themselves on the
# first ./run_streaming.sh — verified, the README is correct about this.

# auto_load_usd lives in dsx.kit; dsx_streaming.kit declares "dsx" = {} and
# inherits it. Default is a REMOTE Nucleus URL that a cloud box cannot reach,
# which hangs ~2 min and then errors. Repoint it at the local pack.
$SUDO -u "$APP_USER" sed -i \
  "s|^auto_load_usd = .*|auto_load_usd = \"$SCENE\"|" "$WORKDIR/source/apps/dsx.kit" \
  || die "could not set auto_load_usd"
info "$(grep -n '^auto_load_usd' "$WORKDIR/source/apps/dsx.kit")"

# Vite refuses unknown hostnames; harmless to allow them on a throwaway box.
VITE="$WORKDIR/web/vite.config.ts"
if [ -f "$VITE" ] && ! grep -q 'allowedHosts' "$VITE"; then
  $SUDO -u "$APP_USER" sed -i '0,/server: *{/s//server: {\n    allowedHosts: true,/' "$VITE" || true
fi

if [ -n "${NVIDIA_API_KEY:-}" ]; then
  $SUDO -u "$APP_USER" bash -c "umask 077; printf 'export NVIDIA_API_KEY=%s\n' '$NVIDIA_API_KEY' > '$APP_HOME/.dsx-agent-env'"
  info "NVIDIA_API_KEY stored for the AI-agent extension"
fi

# Brev does not rerun a Launchable setup script after a stopped VM resumes.
# Persist the existing runtime-only helper and the state it expects so the
# operator can redetect the public IP and restart both services with one command.
curl -fsSL "$RUNTIME_SCRIPT_URL" -o /tmp/dsx-run.sh \
  || die "could not download the persistent DSX restart helper"
$SUDO install -o "$APP_USER" -g "$(id -gn "$APP_USER")" -m 0755 \
  /tmp/dsx-run.sh "$APP_HOME/dsx-run.sh"
$SUDO mkdir -p "$STATE_DIR"
$SUDO tee "$STATE_DIR/config" >/dev/null <<STATE
# written by dsx-launchable-setup.sh on $(date -Is)
DSX_WORKDIR="$WORKDIR"
DSX_DATA_DIR="$DATA_DIR"
DSX_DOWNLOAD_DIR="$DATA_DIR"
DSX_SCENE="$SCENE"
STATE
$SUDO chown -R "$APP_USER:$(id -gn "$APP_USER")" "$STATE_DIR"
if [ -f "$APP_HOME/.dsx-agent-env" ]; then
  $SUDO -u "$APP_USER" ln -sf "$APP_HOME/.dsx-agent-env" "$STATE_DIR/env"
fi
info "persistent restart helper: $APP_HOME/dsx-run.sh"

# ---------------------------------------------------------------------------
log "[5/6] launch"
# ---------------------------------------------------------------------------
# ⚠️ DO NOT pre-build with ./repo.sh build. It resolves livestream
# app-9.0.0/core-9.0.0/webrtc-9.1.1, which CANNOT stream: on 9.0.0 the
# primaryStream.publicIp setting is silently ignored, so Kit advertises only
# private ICE candidates and the browser stalls at "checking". Letting
# run_streaming.sh build on first launch resolves 9.1.0/9.1.0/9.2.0, which
# streams. Verified both ways, 2026-09-01/02.

# The public IP must come from the instance's own metadata: this is the INGRESS
# address the ICE candidate needs. External reflectors report the EGRESS address,
# which is only the same when there is no separate NAT path.
TOK="$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token \
       -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
PUB_IP="$(curl -fsS -m 3 ${TOK:+-H "X-aws-ec2-metadata-token: $TOK"} \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
case "$PUB_IP" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) : ;;
  *) PUB_IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)" ;;
esac
[ -n "$PUB_IP" ] || die "could not determine this instance's public IP"
info "public IP: $PUB_IP"

# primaryStream.publicIp is REQUIRED. Kit is ICE-Lite and otherwise advertises
# only 127.0.0.1 / 172.31.x.x / 172.17.0.1, none of which a browser can route to.
KIT_LOG="$APP_HOME/dsx-kit.log"
WEB_LOG="$APP_HOME/dsx-web.log"
AGENT_PORT=8012
AGENT_MODEL="nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

patch_agent_model() {
  local workflow
  while IFS= read -r workflow; do
    [ -f "$workflow" ] || continue
    grep -qF "model_name: $AGENT_MODEL" "$workflow" && continue
    $SUDO -u "$APP_USER" sed -i -E \
      "s|^([[:space:]]*model_name:[[:space:]]*).*|\\1$AGENT_MODEL|" "$workflow"
  done < <(find "$WORKDIR/source/extensions/omni.ai.aiq.dsx" "$WORKDIR/_build" \
    -path '*/omni.ai.aiq.dsx/data/workflow.yaml' -print 2>/dev/null || true)
}

start_kit() {
  patch_agent_model
  $SUDO -u "$APP_USER" bash -c "cd '$WORKDIR' && \
    tmux kill-session -t dsx-kit 2>/dev/null; : > '$KIT_LOG'; \
    tmux new-session -d -s dsx-kit \
    \"if [ -f '$APP_HOME/.dsx-agent-env' ]; then . '$APP_HOME/.dsx-agent-env'; fi; \
      export DSX_AGENT_PORT=$AGENT_PORT; \
      ./run_streaming.sh --/exts/omni.kit.livestream.app/primaryStream/publicIp=$PUB_IP \
      2>&1 | tee '$KIT_LOG'\""
}

wait_renderer() {
  READY=0
  for i in $(seq 1 90); do          # 90 x 20s = 30 min; first build ~12 min
    if grep -qi 'RTX ready' "$KIT_LOG" 2>/dev/null; then READY=1; break; fi
    sleep 20
  done
}

agent_early_pip_target() {
  local target

  # Kit loads omni.kit.pip_archive before the AI extensions, so its cached
  # packages must be repaired first. Packman exposes it as a symlink.
  target="$(find "$WORKDIR/_build" \( -type d -o -type l \) \
    -path '*/release/extscache/omni.kit.pip_archive-*' -print -quit 2>/dev/null || true)"
  if [ -n "$target" ] && [ -d "$target/pip_prebundle" ]; then
    printf '%s\n' "$target/pip_prebundle"
    return
  else
    find "$WORKDIR/_build" \( -type d -o -type l \) \
      -path '*/release/exts/omni.ai.langchain.core/pip_core_prebundle' \
      -print -quit 2>/dev/null || true
  fi
}

agent_nat_pip_target() {
  find "$WORKDIR/_build" \( -type d -o -type l \) \
    -path '*/release/exts/omni.ai.langchain.nat/pip_nat_prebundle' \
    -print -quit 2>/dev/null || true
}

repair_agent_dependencies() {
  local early_target nat_target python marker
  early_target="$(agent_early_pip_target)"
  nat_target="$(agent_nat_pip_target)"
  if [ -z "$early_target" ] || [ -z "$nat_target" ]; then
    warn "AI agent hit a bundled dependency error, but no repair target was found"
    return 1
  fi
  marker="$early_target/.dsx-agent-dependencies-v2"
  if [ -f "$marker" ]; then
    warn "AI agent still reports a dependency error after the bundled repair"
    return 1
  fi
  python="$WORKDIR/tools/packman/python.sh"
  [ -x "$python" ] || python=python3

  log "repairing bundled AI-agent dependencies"
  $SUDO -u "$APP_USER" "$python" -m pip install \
    --disable-pip-version-check --no-cache-dir --upgrade --target "$early_target" \
    'typing_extensions==4.16.0' 'websockets==16.0' || return 1
  $SUDO -u "$APP_USER" "$python" -m pip install \
    --disable-pip-version-check --no-cache-dir --upgrade --target "$nat_target" \
    'tqdm==4.67.1' || return 1
  $SUDO -u "$APP_USER" touch "$marker"
  info "agent dependencies repaired; restarting Kit once"
}

$SUDO -u "$APP_USER" bash -c "tmux kill-session -t dsx-web 2>/dev/null; true"
start_kit
$SUDO -u "$APP_USER" bash -c "cd '$WORKDIR' && tmux new-session -d -s dsx-web \
  \"VITE_OMNIVERSE_SERVER='$PUB_IP' VITE_SIGNALING_PORT=49100 \
    VITE_DSX_AGENT_PORT=$AGENT_PORT ./run_web.sh 2>&1 | tee '$WEB_LOG'\""
info "kit + web launched under tmux (logs: $KIT_LOG, $WEB_LOG)"

# ---------------------------------------------------------------------------
log "[6/6] waiting for the renderer"
# ---------------------------------------------------------------------------
# ⚠️ The ready line is "RTX ready" -- LOWERCASE 'r' -- and it is written to
# STDOUT ONLY, never to ~/.nvidia-omniverse/logs/.../kit_*.log. Grepping that
# file, or matching "RTX Ready" case-sensitively, finds nothing on a perfectly
# healthy run. That one character cost a full day on 2026-09-01.
# "app ready" (~25s) is NOT readiness: the scene is still loading.
wait_renderer

# The prebundles do not exist until run_streaming.sh completes its first build.
# Any one of these errors proves the affected dependency layout is present, so
# install the complete tested set and restart only once.
if [ -n "${NVIDIA_API_KEY:-}" ] &&
   grep -qiE 'extra_items|No module named.*tqdm|cannot import name.*backoff.*websockets\.client' "$KIT_LOG" 2>/dev/null; then
  if repair_agent_dependencies; then
    start_kit
    wait_renderer
  else
    warn "AI agent dependency repair failed"
  fi
fi

AGENT_READY=0
if [ -n "${NVIDIA_API_KEY:-}" ]; then
  for i in $(seq 1 30); do
    AGENT_HEALTH="$(curl -fsS -m 3 \
      "http://127.0.0.1:$AGENT_PORT/api/agent/health" 2>/dev/null || true)"
    if [[ "$AGENT_HEALTH" =~ \"agent_available\"[[:space:]]*:[[:space:]]*true ]] &&
       [[ "$AGENT_HEALTH" =~ \"api_key_set\"[[:space:]]*:[[:space:]]*true ]] &&
       grep -qF 'NAT LLM and plugin registrations loaded' "$KIT_LOG" 2>/dev/null; then
      AGENT_READY=1
      break
    fi
    sleep 2
  done
  if [ "$AGENT_READY" -eq 1 ]; then
    AGENT_SMOKE="$(curl -fsS -m 60 -H 'Content-Type: application/json' \
      --data '{"message":"Reply with OK only. Do not change the scene.","user_id":"launchable-startup-check","history":[]}' \
      "http://127.0.0.1:$AGENT_PORT/api/agent/chat" 2>/dev/null || true)"
    if [[ "$AGENT_SMOKE" =~ \"response\" ]] &&
       [[ "$AGENT_SMOKE" != *"An error occurred while processing your request"* ]]; then
      info "AI agent ready on $AGENT_PORT/TCP (NIM smoke test passed)"
    else
      AGENT_READY=0
      warn "AI agent HTTP server is up, but its NIM smoke test failed"
      warn "  ${AGENT_SMOKE:-<no response>}"
    fi
  else
    warn "AI agent did not load its NIM registrations on $AGENT_PORT/TCP"
  fi
  if [ "$AGENT_READY" -ne 1 ]; then
    warn "AI agent is optional; continuing because the DSX viewer is ready"
  fi
else
  info "AI agent disabled (NVIDIA_API_KEY launch parameter was not supplied)"
fi

LS_VERS="$(grep -ohE 'omni\.kit\.livestream\.[a-z]+-[0-9.]+' \
           "$APP_HOME/.nvidia-omniverse/logs/Kit/DSX Streaming/2.0/"*.log 2>/dev/null | sort -u | tr '\n' ' ')"

cat <<BANNER

============================================================
$( [ "$READY" -eq 1 ] && echo "DSX IS READY." || echo "DSX did not report ready within 30 minutes." )

  Open:  http://$PUB_IP:8081/?server=$PUB_IP&signalingPort=49100
         (NOT /streaming.html — that page does not exist in this build)

  livestream: ${LS_VERS:-<unknown>}
$( case "$LS_VERS" in
     *app-9.1.0*) echo "  ✅ the combination proven to stream" ;;
     *app-9.0.0*) echo "  🔴 9.0.0 CANNOT STREAM — publicIp is silently ignored on it" ;;
     *)           echo "  ⚠️ could not read the livestream versions" ;;
   esac )

  AI agent: $( if [ -z "${NVIDIA_API_KEY:-}" ]; then
                 echo "disabled (no NVIDIA_API_KEY)"
               elif [ "$AGENT_READY" -eq 1 ]; then echo "ready"; else echo "NOT READY (optional; viewer is available)"; fi )

  Ports this Launchable must declare:
    8081/TCP   web UI
    49100/TCP  signalling
    47998/TCP + UDP   media   <-- UDP is what carries the video
    8012/TCP   AI agent

  ⚠️ ONE VIEWER AT A TIME. A second browser on this URL can kick the first
     (NVST_R_BUSY). IP-restricting the ports does NOT work -- use "all IPs"
     and keep the URL off shared channels.

  Logs:  $KIT_LOG   $WEB_LOG

  After a VM stop/start, restart DSX with:
    brev exec $RESTART_TARGET 'bash $APP_HOME/dsx-run.sh start'
============================================================
BANNER
[ "$READY" -eq 1 ] || exit 1
