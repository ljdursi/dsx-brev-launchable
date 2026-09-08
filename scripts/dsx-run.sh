#!/usr/bin/env bash
# dsx-run.sh — LAUNCH / RESTART / INSPECT the DSX demo on a provisioned instance.
#
#   Implements the tiered restart from ai-factory-demo-setup-runbook.md §7 so the
#   booth has a scripted recovery path instead of hand-typed override flags.
#
#     ./dsx-run.sh start    start both, wait for readiness, print the booth URL
#     ./dsx-run.sh web      §7 Level 2 — restart the web frontend only  (~30-60 s)
#     ./dsx-run.sh kit      §7 Level 3 — restart the Kit server only    (5-8 min)
#     ./dsx-run.sh stop     stop both
#     ./dsx-run.sh status   what's running, current IP, drift, readiness, the URL
#     ./dsx-run.sh logs [kit|web]     tail a log
#     ./dsx-run.sh url      print the booth URL and exit
#     ./dsx-run.sh check-ports [secs]
#                           verify the Brev dashboard firewall rules -- prints the
#                           probe commands to run from your laptop and captures
#                           inbound 47998/UDP here. The only way to tell an open
#                           port from a blocked one before a browser fails.
#     ./dsx-run.sh wait     re-attach to a launch already in progress (after an
#                           SSH drop -- the tmux sessions survive it, so this
#                           resumes watching rather than restarting anything)
#
#   Flags:  --no-wait               return as soon as the sessions are up
#           --timeout <seconds>     readiness timeout (default 3600; generous on
#                                   purpose). Measured: RTX ready ~252s cold
#                                   (scene load + shaders), ~45-55s warm. The
#                                   ">25 min" once recorded here was the
#                                   case-sensitive grep bug, not real.
#
#   Re-derives the instance's public IP on EVERY launch and feeds it to
#   primaryStream.publicIp, which is REQUIRED for streaming (Kit is ICE-Lite and
#   otherwise advertises only private candidates). A Brev stop/start reassigns
#   the IP and a stale value fails SILENTLY -- black viewport, ICE stuck at
#   "checking". `status` flags that drift. See start_kit().
set -euo pipefail

STATE_DIR="$HOME/.dsx"
KIT_SESSION="dsx-kit"
WEB_SESSION="dsx-web"
KIT_LOG="$HOME/dsx-kit.log"
WEB_LOG="$HOME/dsx-web.log"
READY_TIMEOUT=3600
WAIT=1

WEB_PORT=8081
SIGNAL_PORT=49100
MEDIA_PORT=47998
AGENT_PORT=8012
AGENT_MODEL="nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
[ -f "$STATE_DIR/config" ] || die "no $STATE_DIR/config — run 'bash dsx-setup.sh' first."
# shellcheck source=/dev/null
. "$STATE_DIR/config"
if [ -f "$STATE_DIR/env" ]; then
  # shellcheck source=/dev/null
  . "$STATE_DIR/env"                              # NVIDIA_API_KEY, if provisioned
fi

: "${DSX_WORKDIR:?DSX_WORKDIR missing from $STATE_DIR/config}"
: "${DSX_SCENE:?DSX_SCENE missing from $STATE_DIR/config}"
[ -d "$DSX_WORKDIR" ] || die "workdir $DSX_WORKDIR is gone — re-run dsx-setup.sh."
# The content pack often lives on instance-store/ephemeral NVMe (e.g. AWS
# /opt/dlami/nvme), which is WIPED by a stop/start. Checked before LAUNCHING only:
# status/stop/logs must keep working when the scene is gone -- that is precisely
# when you need them to diagnose.
require_scene() {
  [ -f "$DSX_SCENE" ] && return 0
  warn "the scene file recorded in $STATE_DIR/config no longer exists:"
  warn "  $DSX_SCENE"
  case "$DSX_SCENE" in
    /opt/dlami/nvme/*|/mnt/*|/ephemeral/*|/scratch/*)
      warn "That path is on EPHEMERAL/instance-store storage, which a Brev stop/start wipes." ;;
  esac
  die "re-run 'bash ~/dsx-setup.sh' to restore the content pack (the clone and build are unaffected)."
}

# ---------------------------------------------------------------------------
# public IP discovery
# ---------------------------------------------------------------------------
valid_ip() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

detect_public_ip() {
  local ip tok
  # 1. explicit override always wins
  if valid_ip "${DSX_PUBLIC_IP:-}"; then printf '%s' "$DSX_PUBLIC_IP"; return 0; fi
  # 2. cloud metadata — this is the INGRESS address, which is what the ICE
  #    candidate needs. ipify/ifconfig.me report the EGRESS address, which is
  #    only the same thing when there's no separate NAT path.
  tok="$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [ -n "$tok" ]; then
    ip="$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $tok" \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    valid_ip "$ip" && { printf '%s' "$ip"; return 0; }
  fi
  ip="$(curl -fsS -m 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  valid_ip "$ip" && { printf '%s' "$ip"; return 0; }
  # 3. external reflectors (egress; may differ from ingress behind NAT)
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    valid_ip "$ip" && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

check_topology() {
  local ctx="/etc/brev/environment-context.json"
  [ -f "$ctx" ] || { info "no $ctx — assuming a plain VM with a direct public IP"; return 0; }
  if grep -q '"ports"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$ctx"; then
    info "topology: direct-public-IP VM (ports: []) — the publicIp recipe applies"
  elif grep -q '"ports"' "$ctx"; then
    warn "topology: this instance has REMAPPED PORTS (pod-mapped Brev environment)."
    warn "primaryStream.publicIp alone will NOT get media through — Kit will advertise"
    warn "a pod IP the browser can't route to. See the runbook's pod-mapped recipe"
    warn "(socat + iceHijack.ts). Continuing anyway, but expect ICE to stall."
  fi
}

# ---------------------------------------------------------------------------
# config patching
# ---------------------------------------------------------------------------
# repo.sh launch runs the BUILT .kit, not source/ (runbook BUILD-COPY GOTCHA), and
# a rebuild wipes the built copy. Re-apply on every launch; it's idempotent.
patch_built_kit() {
  local kit n=0
  while IFS= read -r kit; do
    grep -q 'auto_load_usd' "$kit" || continue
    sed -i -E "s|^([[:space:]]*auto_load_usd[[:space:]]*=[[:space:]]*).*|\1\"$DSX_SCENE\"|" "$kit"
    n=$((n+1))
  done < <(find "$DSX_WORKDIR/_build" -maxdepth 5 -name '*.kit' -path '*/apps/*' 2>/dev/null || true)
  if [ "$n" -gt 0 ]; then info "scene path re-applied to $n built .kit file(s)"; fi
  return 0
}

patch_agent_model() {
  local workflow n=0
  while IFS= read -r workflow; do
    [ -f "$workflow" ] || continue
    grep -qF "model_name: $AGENT_MODEL" "$workflow" && continue
    sed -i -E "s|^([[:space:]]*model_name:[[:space:]]*).*|\1$AGENT_MODEL|" "$workflow"
    n=$((n+1))
  done < <(find "$DSX_WORKDIR/source/extensions/omni.ai.aiq.dsx" "$DSX_WORKDIR/_build" \
    -path '*/omni.ai.aiq.dsx/data/workflow.yaml' -print 2>/dev/null || true)
  [ "$n" -eq 0 ] || info "AI agent model set to $AGENT_MODEL in $n workflow file(s)"
}

# ---------------------------------------------------------------------------
# process control
# ---------------------------------------------------------------------------
session_up() { tmux has-session -t "$1" 2>/dev/null; }

kill_session() {
  if session_up "$1"; then
    tmux kill-session -t "$1"
    info "stopped $1"
  fi
}

start_kit() {
  local pub_ip="$1"
  kill_session "$KIT_SESSION"
  patch_built_kit
  patch_agent_model
  # Truncate: otherwise the readiness check matches the PREVIOUS run's ready line
  # and reports success against a server that never came up.
  : > "$KIT_LOG"
  printf '%s' "$pub_ip" > "$STATE_DIR/current-ip"

  # ---- primaryStream.publicIp: REQUIRED. Do not remove. --------------------
  # ✅ PROVEN WORKING 2026-09-01 (and originally 2026-08-26).
  # Kit is ICE-Lite and advertises only host candidates -- 127.0.0.1,
  # 172.31.x.x, 172.17.0.1 -- so without this the browser's ICE checks go to
  # unroutable addresses, stall at "checking", and Kit logs
  #   [Fatal] StreamSdkException ... Got stop event while waiting for client connection.
  #
  # ⚠️ It is only HALF the fix. It requires livestream app-9.1.0 / core-9.1.0 /
  # webrtc-9.2.0. On 9.0.0 the setting is accepted and does nothing (and passing
  # it alone stops session creation entirely). 2026-09-01 tested every
  # combination: newer exts alone -> ICE stuck; override alone on 9.0.0 -> no
  # session; BOTH -> streams. See the runbook's "THE FIX".
  #
  # ⚠️ The IP is re-derived on every launch because a Brev stop/start reassigns
  # it, and a stale value fails silently (black viewport, ICE stuck).
  local stream_args="--/exts/omni.kit.livestream.app/primaryStream/publicIp=$pub_ip"

  tmux new-session -d -s "$KIT_SESSION" \
    "cd '$DSX_WORKDIR' && DSX_AGENT_PORT='$AGENT_PORT' ./run_streaming.sh $stream_args \
       --/app/auto_load_usd='$DSX_SCENE' 2>&1 | tee '$KIT_LOG'"
  info "kit server launched (tmux: $KIT_SESSION, log: $KIT_LOG)"
  info "  publicIp override: $pub_ip  (requires livestream 9.1.0/9.2.0 — see runbook)"
}

start_web() {
  local pub_ip="$1"
  kill_session "$WEB_SESSION"
  : > "$WEB_LOG"
  # Point the browser client at the Kit server up front rather than making whoever
  # is staffing the booth append ?server=... by hand (runbook Brev gotcha 2).
  tmux new-session -d -s "$WEB_SESSION" \
    "cd '$DSX_WORKDIR' && VITE_OMNIVERSE_SERVER='$pub_ip' VITE_SIGNALING_PORT='$SIGNAL_PORT' \
       VITE_DSX_AGENT_PORT='$AGENT_PORT' \
       ./run_web.sh 2>&1 | tee '$WEB_LOG'"
  info "web frontend launched (tmux: $WEB_SESSION, log: $WEB_LOG)"
}

booth_url() {
  local ip="${1:-$(cat "$STATE_DIR/current-ip" 2>/dev/null || echo '<ip>')}"
  # NO streaming.html in this build -- `ls web/` has index.html and nothing else.
  # Vite's dev server falls back to index.html for unknown paths, so a wrong path
  # still renders the globe and looks fine; verified live 2026-09-01. The query
  # params are still read (main.tsx / OmniverseApiProvider getParam).
  printf 'http://%s:%s/?server=%s&signalingPort=%s\n' \
    "$ip" "$WEB_PORT" "$ip" "$SIGNAL_PORT"
}

# ---------------------------------------------------------------------------
# readiness
# ---------------------------------------------------------------------------
# Is the streaming server actually accepting connections?
serving() {
  ss -tln 2>/dev/null | grep -q ":$SIGNAL_PORT " && ss -tln 2>/dev/null | grep -q ":$WEB_PORT "
}

# THE READY LINE -- and the single most expensive bug of 2026-09-01.
#
# Kit prints  "[252.291s] RTX ready"  -- lowercase 'r' in "ready".
# The runbook, and this script, grepped case-SENSITIVELY for "RTX Ready".
# It therefore never matched, and a normal ~4-minute startup was diagnosed as a
# 25+ minute hang. Three separate wrong theories were built on that (readiness
# is gated on a client connecting; the scene load hangs; "app ready" is the real
# signal). A log filed as evidence of a 30-minute stall in fact contains
# "[239.804s] RTX ready".
#
# ⚠️ It is emitted on STDOUT ONLY. It never appears in
#    ~/.nvidia-omniverse/logs/Kit/DSX Streaming/2.0/kit_*.log -- grepping that
#    file for it returns 0 even on a fully successful run. We tee stdout to
#    $KIT_LOG, which is why matching works here.
#
# ⚠️ "app ready" is NOT readiness. It fires ~10-25s in and means only that the
#    application started; the scene is still loading and nothing is renderable.
#    Do not treat it as ready -- at the booth that is the difference between
#    "we're live" and "we're live in four minutes".
READY_RE='RTX ready'

wait_ready() {
  local timeout="$1" start now elapsed last="" serve_since=0
  start="$(date +%s)"
  info "waiting for \"RTX ready\" (cold: ~4 min scene load+shaders; warm: ~1 min)"
  while :; do
    if grep -qiE "$READY_RE" "$KIT_LOG" 2>/dev/null; then
      elapsed=$(( $(date +%s) - start ))
      log "RTX ready after ${elapsed}s"
      return 0
    fi
    # Some builds do not print "RTX Ready" until a client actually connects: the
    # renderer finishes initialising against a real stream consumer. Waiting for
    # the log line alone then hangs forever on a server that is in fact up, and
    # Kit eventually gives up with "Got stop event while waiting for client
    # connection". So treat "web + signaling both listening, held for 60s" as
    # serving, and hand back to the operator to connect a browser.
    # Ports listening is NOT readiness. Measured 2026-09-02: this fired at 554s
    # and printed "DSX IS UP" while the scene was still loading and RTX ready was
    # ~4 more minutes away. Now that the real signal is matched correctly
    # (lowercase, case-insensitive) this is a LAST RESORT only -- it must not
    # pre-empt a signal that is genuinely coming. 10 minutes of listening without
    # a ready line means something is actually wrong.
    if serving; then
      if [ "$serve_since" -eq 0 ]; then
        serve_since="$(date +%s)"
      elif [ $(( $(date +%s) - serve_since )) -ge 600 ]; then
        elapsed=$(( $(date +%s) - start ))
        warn "no ready line after ${elapsed}s, but web+signaling have been listening"
        warn "for 10 min. Treating as SERVING, but this is NOT confirmed ready."
        warn "(no app-ready line logged — unexpected on this build, which prints"
        warn " \"app ready\" within ~10s. Open the booth URL and check the Kit log.)"
        warn " If the browser cannot reach it, the Brev dashboard ports are the first"
        warn " thing to check: $WEB_PORT/TCP + $SIGNAL_PORT/TCP to load the page at all,"
        warn " $MEDIA_PORT/UDP for pixels. No client can connect until those are open,"
        warn " so without them this state cannot be distinguished from a hung start."
        return 0
      fi
    else
      serve_since=0
    fi
    if ! session_up "$KIT_SESSION"; then
      warn "the $KIT_SESSION tmux session exited before becoming ready."
      return 2
    fi
    now="$(date +%s)"; elapsed=$(( now - start ))
    [ "$elapsed" -lt "$timeout" ] || { warn "timed out after ${timeout}s"; return 1; }
    if [ $(( elapsed % 60 )) -lt 5 ] && [ "$elapsed" -ge 55 ]; then
      last="$(tail -n1 "$KIT_LOG" 2>/dev/null | cut -c1-100 || true)"
      info "still building/starting — ${elapsed}s elapsed | $last"
    fi
    sleep 5
  done
}

# The agent dependency bundles are created by run_streaming.sh's first build,
# so compatibility repairs cannot run during provisioning. Any one of the known
# errors proves the affected bundle layout is present; install the complete
# tested set, then let the caller restart Kit only once.
agent_enabled() { [ -n "${NVIDIA_API_KEY:-}" ]; }

agent_early_pip_target() {
  local target

  # Kit loads omni.kit.pip_archive before the AI extensions, so its cached
  # packages must be repaired first. Packman exposes it as a symlink.
  target="$(find "$DSX_WORKDIR/_build" \( -type d -o -type l \) \
    -path '*/release/extscache/omni.kit.pip_archive-*' -print -quit 2>/dev/null || true)"
  if [ -n "$target" ] && [ -d "$target/pip_prebundle" ]; then
    printf '%s\n' "$target/pip_prebundle"
    return
  fi

  find "$DSX_WORKDIR/_build" \( -type d -o -type l \) \
    -path '*/release/exts/omni.ai.langchain.core/pip_core_prebundle' \
    -print -quit 2>/dev/null || true
}

agent_nat_pip_target() {
  find "$DSX_WORKDIR/_build" \( -type d -o -type l \) \
    -path '*/release/exts/omni.ai.langchain.nat/pip_nat_prebundle' \
    -print -quit 2>/dev/null || true
}

repair_agent_dependencies() {
  local early_target nat_target marker python
  agent_enabled || return 1
  grep -qiE 'extra_items|No module named.*tqdm|cannot import name.*backoff.*websockets\.client' \
    "$KIT_LOG" 2>/dev/null || return 1

  early_target="$(agent_early_pip_target)"
  nat_target="$(agent_nat_pip_target)"
  if [ -z "$early_target" ] || [ -z "$nat_target" ]; then
    warn "AI agent hit a bundled dependency error, but no repair target was found."
    return 2
  fi
  marker="$early_target/.dsx-agent-dependencies-v2"
  if [ -f "$marker" ]; then
    warn "AI agent still reports a dependency error after the bundled repair."
    return 2
  fi
  python="$DSX_WORKDIR/tools/packman/python.sh"
  if [ ! -x "$python" ]; then
    warn "blueprint Python wrapper not found at $python"
    return 2
  fi

  log "repairing bundled AI-agent dependencies"
  "$python" -m pip install --disable-pip-version-check --no-cache-dir \
    --upgrade --target "$early_target" \
    'typing_extensions==4.16.0' 'websockets==16.0' || {
      warn "could not repair typing_extensions/websockets in $early_target"
      return 2
    }
  "$python" -m pip install --disable-pip-version-check --no-cache-dir \
    --upgrade --target "$nat_target" 'tqdm==4.67.1' || {
      warn "could not install tqdm==4.67.1 into $nat_target"
      return 2
    }
  touch "$marker"
  info "agent dependencies repaired; Kit must restart once"
  return 0
}

agent_health() {
  local body
  body="$(curl -fsS -m 3 "http://127.0.0.1:$AGENT_PORT/api/agent/health" 2>/dev/null || true)"
  [[ "$body" =~ \"agent_available\"[[:space:]]*:[[:space:]]*true ]] &&
    [[ "$body" =~ \"api_key_set\"[[:space:]]*:[[:space:]]*true ]]
}

agent_registration_ready() {
  grep -qF 'NAT LLM and plugin registrations loaded' "$KIT_LOG" 2>/dev/null
}

agent_smoke_test() {
  local body
  body="$(curl -fsS -m 60 -H 'Content-Type: application/json' \
    --data '{"message":"Reply with OK only. Do not change the scene.","user_id":"launchable-startup-check","history":[]}' \
    "http://127.0.0.1:$AGENT_PORT/api/agent/chat" 2>/dev/null || true)"
  if [[ "$body" =~ \"response\" ]] &&
     [[ "$body" != *"An error occurred while processing your request"* ]]; then
    return 0
  fi
  warn "AI agent HTTP server is up, but its NIM smoke test failed:"
  warn "  ${body:-<no response>}"
  return 1
}

wait_agent_ready() {
  local i
  if ! agent_enabled; then
    info "AI agent: disabled (NVIDIA_API_KEY was not provisioned)"
    return 0
  fi
  for i in $(seq 1 30); do
    if agent_health && agent_registration_ready; then
      agent_smoke_test || return 1
      info "AI agent: ready on $AGENT_PORT/TCP (NIM smoke test passed)"
      return 0
    fi
    sleep 2
  done
  warn "AI agent did not load its NIM registrations at http://127.0.0.1:$AGENT_PORT"
  return 1
}

# Known-bad patterns straight out of the runbook's gotcha table.
diagnose() {
  local hit=0
  grep -q 'cannot open shared object' "$KIT_LOG" 2>/dev/null && {
    warn "missing shared library — install the matching package (runbook §3 GL/X bundle):"
    grep -o '[^ ]*\.so[^:]*: cannot open shared object' "$KIT_LOG" | sort -u | sed 's/^/     /'
    hit=1; }
  grep -q 'Failed to open : omniverse://' "$KIT_LOG" 2>/dev/null && {
    warn "scene load hit a REMOTE Nucleus URL — auto_load_usd did not take."
    warn "  expected: $DSX_SCENE"
    warn "  check:    grep -rn auto_load_usd '$DSX_WORKDIR/_build'/*/*/apps/*.kit"
    hit=1; }
  grep -q 'Got stop event while waiting for client connection' "$KIT_LOG" 2>/dev/null && {
    warn "WebRTC media never traversed (runbook Brev gotcha 3). Check, in order:"
    warn "  1. is $MEDIA_PORT exposed as TCP *and UDP* in the Brev dashboard?"
    warn "  2. does the advertised candidate match the current public IP? ('$0 status')"
    warn "  3. sudo tcpdump -ni any udp port $MEDIA_PORT and not host 127.0.0.1"
    hit=1; }
  grep -q 'NVST_R_BUSY' "$KIT_LOG" 2>/dev/null && {
    warn "NVST_R_BUSY — TWO VIEWERS FOUGHT OVER ONE SESSION."
    warn "  primaryStream serves exactly ONE interactive client. A second browser"
    warn "  opening the demo URL gets a timeout box offering 'start a new session',"
    warn "  and retrying can KICK the first viewer. Reported live 2026-09-02."
    warn "  Use 'all IPs' for the Brev port rules — restricting them to the booth"
    warn "  machine was tested and made every port unreachable. Control access with"
    warn "  Secure Links / bearer authentication, or keep the URL private."
    warn "  Use separate instances for concurrent practice; spectatorStream is an"
    warn "  untested option for additional viewers (see runbook)."
    hit=1; }
  grep -qiE 'extra_items|No module named.*tqdm|cannot import name.*backoff.*websockets\.client' "$KIT_LOG" 2>/dev/null && {
    warn "AI agent dependency error: incompatible typing_extensions/tqdm/websockets bundles."
    warn "  Restart with '$0 kit'; startup repairs this automatically after the first build."
    hit=1; }
  return $hit
}

# The livestream version is the difference between a demo and a black viewport,
# and it is only knowable after Kit has loaded its extensions. Prefer the stdout
# capture for the current run (it is truncated by start_kit), then fall back to
# the newest native Kit log when checking an older or externally-started run.
check_livestream_versions() {
  local kitlog="" candidate vers
  local version_re='omni\.kit\.livestream\.[a-z]+-[0-9.]+'
  local native_log_dir="$HOME/.nvidia-omniverse/logs/Kit/DSX Streaming/2.0"

  if grep -qE "$version_re" "$KIT_LOG" 2>/dev/null; then
    kitlog="$KIT_LOG"
  else
    while IFS= read -r candidate; do
      if [ -z "$kitlog" ] || [ "$candidate" -nt "$kitlog" ]; then
        kitlog="$candidate"
      fi
    done < <(find "$native_log_dir" -maxdepth 1 -type f -name '*.log' -print 2>/dev/null || true)
  fi

  if [ -z "$kitlog" ]; then
    info "not found yet (Kit may still be starting)"
    return 0
  fi

  vers="$(grep -oE "$version_re" "$kitlog" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
  if [ -z "$vers" ]; then
    info "not found in $kitlog"
    return 0
  fi

  info "$vers"
  if [[ "$vers" == *app-9.0.0* || "$vers" == *core-9.0.0* ]]; then
    warn "🔴 livestream 9.0.0 loaded — STREAMING CANNOT WORK."
    warn "   On 9.0.0 primaryStream.publicIp is silently ignored, so Kit advertises"
    warn "   only private ICE candidates and the browser stalls at 'checking'."
    warn "   Fix: rebuild WITHOUT ./repo.sh build (DSX_SKIP_BUILD=1, the default)"
    warn "   and let run_streaming.sh build on first launch."
  elif [[ "$vers" == *app-9.1.0* && "$vers" == *core-9.1.0* && "$vers" == *webrtc-9.2.0* ]]; then
    info "  ✅ the combination proven to stream"
  else
    warn "unverified livestream version combination — expected app/core 9.1.0 and webrtc 9.2.0"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------
cmd_start() {
  local which="${1:-both}" pub_ip repair_rc=1
  check_topology
  pub_ip="$(detect_public_ip)" || die "could not determine this instance's public IP.
  Set it explicitly and re-run:  DSX_PUBLIC_IP=<ip> $0 $which"
  info "public IP: $pub_ip"

  case "$which" in
    both) require_scene; start_kit "$pub_ip"; start_web "$pub_ip" ;;
    kit)  require_scene; start_kit "$pub_ip" ;;
    web)  start_web "$pub_ip"; log "web restarted — refresh the browser tab."; return 0 ;;
  esac

  if [ "$WAIT" -eq 0 ]; then
    log "started (--no-wait). Poll with: $0 status"
    return 0
  fi

  local rc=0
  wait_ready "$READY_TIMEOUT" || rc=$?
  if [ "$rc" -eq 0 ]; then
    repair_rc=0
    repair_agent_dependencies || repair_rc=$?
    if [ "$repair_rc" -eq 0 ]; then
      start_kit "$pub_ip"
      wait_ready "$READY_TIMEOUT" || rc=$?
    elif [ "$repair_rc" -eq 2 ]; then
      rc=1
    fi
  fi
  check_livestream_versions
  diagnose || true
  if [ "$rc" -eq 0 ]; then
    wait_agent_ready || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    warn "not ready. Last 30 lines of $KIT_LOG:"
    tail -n 30 "$KIT_LOG" 2>/dev/null | sed 's/^/     /'
    return 1
  fi

  cat <<EOF

============================================================
DSX IS UP.

  Booth URL:  $(booth_url "$pub_ip")

  (run_web.sh prints TWO urls on this build — Local and Network — not three.
   The URL above sets server/signalingPort explicitly, so prefer it.)

  Ports that MUST be exposed in the Brev dashboard (no CLI command does this):
    $WEB_PORT    web UI      TCP
    $SIGNAL_PORT   signaling   TCP
    $MEDIA_PORT   media       TCP + UDP   <-- UDP carries the video
    $AGENT_PORT    AI agent    TCP

  Restart tiers (runbook §7):
    L1 browser froze   -> refresh the tab
    L2 web died        -> $0 web      (~30-60 s)
    L3 kit crashed     -> $0 kit      (5-8 min shader recompile)
============================================================
EOF
}

cmd_stop() {
  kill_session "$KIT_SESSION"
  kill_session "$WEB_SESSION"
  log "stopped."
}

cmd_status() {
  local cur recorded ready
  log "sessions"
  session_up "$KIT_SESSION" && info "kit: RUNNING" || info "kit: stopped"
  session_up "$WEB_SESSION" && info "web: RUNNING" || info "web: stopped"

  log "scene"
  if [ -f "$DSX_SCENE" ]; then
    info "present: $DSX_SCENE"
  else
    warn "MISSING: $DSX_SCENE"
    case "$DSX_SCENE" in
      /opt/dlami/nvme/*|/mnt/*|/ephemeral/*|/scratch/*)
        warn "that path is ephemeral/instance-store — wiped by a stop/start" ;;
    esac
    warn "re-run 'bash ~/dsx-setup.sh' before launching"
  fi

  log "readiness"
  if grep -qiE "$READY_RE" "$KIT_LOG" 2>/dev/null; then
    ready="yes"; info "RTX ready: YES"
  else
    ready="no";  info "RTX ready: not yet (log: $KIT_LOG)"
  fi

  log "listeners (LOCAL sockets only)"
  for p in "$WEB_PORT" "$SIGNAL_PORT" "$MEDIA_PORT" "$AGENT_PORT"; do
    if ss -tuln 2>/dev/null | grep -q ":$p "; then info "port $p: listening"; else info "port $p: NOT listening"; fi
  done
  # Worth stating plainly: on 2026-08-31 every port here was listening and the
  # demo was still unreachable, because nothing had opened the Brev firewall.
  info "NB: 'listening' only means the process is bound HERE — it says nothing"
  info "    about whether the Brev firewall admits traffic ($MEDIA_PORT needs TCP"
  info "    *and* UDP). To verify that: $0 check-ports"
  info "    ($MEDIA_PORT shows NOT listening until a client connects — that is normal.)"

  log "public IP"
  recorded="$(cat "$STATE_DIR/current-ip" 2>/dev/null || echo '<none>')"
  cur="$(detect_public_ip || echo '<undetectable>')"
  info "kit was launched advertising: $recorded"
  info "instance's IP right now     : $cur"
  if [ "$recorded" != "$cur" ] && [ "$recorded" != "<none>" ]; then
    warn "IP DRIFT — the address Kit is advertising is stale (a Brev stop/start reassigns it)."
    warn "Media will never connect until you re-launch:  $0 kit"
  fi

  log "livestream extensions"; check_livestream_versions
  log "AI agent"
  if agent_enabled; then
    agent_health && agent_registration_ready &&
      info "ready on $AGENT_PORT/TCP" || warn "not ready; check $KIT_LOG"
  else
    info "disabled (NVIDIA_API_KEY was not provisioned)"
  fi
  if [ "$ready" = "yes" ]; then log "booth URL"; info "$(booth_url "$cur")"; fi
  diagnose || true
}

# INSTANCE SIDE ONLY -- this is deliberately half of the test.
# The probes must originate OUTSIDE the instance to traverse the Brev firewall,
# and this script runs ON the instance, so it can only ever listen. Running it
# alone in one terminal produces an empty capture that looks like a blocked
# port, which is exactly how it misled us on 2026-09-02.
#
# ✅ Prefer the laptop-side version, which drives both ends automatically:
#      ./launch-dsx-brev.sh <name> --check-ports
#
# Use this only if you want to watch the capture yourself, in which case send
# the probes from another machine WHILE it runs.
# tcpdump -l is load-bearing: unbuffered, a mid-capture read shows zero packets.
cmd_check_ports() {
  local ip secs="${1:-30}"
  ip="$(detect_public_ip || echo '<ip>')"
  log "local listeners"
  for p in "$WEB_PORT" "$SIGNAL_PORT" "$MEDIA_PORT" "$AGENT_PORT"; do
    if ss -tuln 2>/dev/null | grep -q ":$p "; then info "port $p: listening"; else info "port $p: not listening"; fi
  done
  info "($MEDIA_PORT stays 'not listening' until a client connects — that is normal.)"
  warn "This only LISTENS. For the real end-to-end check run, from your laptop:"
  warn "    ./launch-dsx-brev.sh <name> --check-ports"
  cat <<EOF

   Or, to drive it by hand, run this from another machine DURING the capture:
     for i in \$(seq 1 12); do printf probe > /dev/udp/$ip/$MEDIA_PORT; done

EOF
  log "capturing inbound $MEDIA_PORT/UDP for ${secs}s"
  sudo timeout "$secs" tcpdump -l -ni any "udp port $MEDIA_PORT and not host 127.0.0.1" 2>/dev/null \
    | grep -E '^[0-9]' | head -20 || true
  info "(no lines = nothing arrived: either the UDP rule is missing, or nothing"
  info " was sent during the window. $MEDIA_PORT/UDP is what carries video.)"
}

cmd_logs() {
  case "${1:-kit}" in
    kit) tail -f "$KIT_LOG" ;;
    web) tail -f "$WEB_LOG" ;;
    *)   die "logs: expected 'kit' or 'web'" ;;
  esac
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
CMD=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-wait)  WAIT=0 ;;
    --timeout)  READY_TIMEOUT="${2:?--timeout needs a value}"; shift ;;
    -h|--help)  sed -n '2,34p' "$0"; exit 0 ;;
    -*)         die "unknown flag: $1" ;;
    *)          if [ -z "$CMD" ]; then CMD="$1"; else ARGS+=("$1"); fi ;;
  esac
  shift
done

case "${CMD:-start}" in
  start)          cmd_start both ;;
  kit|restart-kit) cmd_start kit ;;
  web|restart-web) cmd_start web ;;
  stop)           cmd_stop ;;
  status)         cmd_status ;;
  logs)           cmd_logs "${ARGS[0]:-kit}" ;;
  check-ports)    cmd_check_ports "${ARGS[0]:-30}" ;;
  wait)           session_up "$KIT_SESSION" || die "no $KIT_SESSION session running — use '$0 start'."
                  rc=0; wait_ready "$READY_TIMEOUT" || rc=$?
                  if [ "$rc" -eq 0 ]; then
                    repair_rc=0
                    repair_agent_dependencies || repair_rc=$?
                    if [ "$repair_rc" -eq 0 ]; then
                      pub_ip="$(detect_public_ip)" || die "could not determine public IP for the agent repair restart"
                      start_kit "$pub_ip"
                      wait_ready "$READY_TIMEOUT" || rc=$?
                    elif [ "$repair_rc" -eq 2 ]; then
                      rc=1
                    fi
                  fi
                  check_livestream_versions
                  diagnose || true
                  if [ "$rc" -eq 0 ]; then
                    wait_agent_ready || rc=1
                  fi
                  if [ "$rc" -ne 0 ]; then tail -n 30 "$KIT_LOG" | sed 's/^/     /'; exit 1; fi
                  log "booth URL"; info "$(booth_url)" ;;
  url)            booth_url ;;
  *)              die "unknown command '$CMD' (start|kit|web|stop|status|logs|url|wait|check-ports)" ;;
esac
