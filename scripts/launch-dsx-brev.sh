#!/usr/bin/env bash
# launch-dsx-brev.sh — provision a Brev instance and bring the DSX demo up on it.
#   Run from your laptop, in the same directory as dsx-setup.sh + dsx-run.sh.
#   Prereqs: brev CLI installed + `brev login`.
#
#   ./launch-dsx-brev.sh --check                  # probe CLI + show matching GPU types (no cost)
#   ./launch-dsx-brev.sh                          # create 'dsx-demo' and bring it up
#   ./launch-dsx-brev.sh mydemo                   # ...under a different name
#   ./launch-dsx-brev.sh mydemo --skip-create     # re-run against an existing instance
#   ./launch-dsx-brev.sh --list-types             # what's available right now, with prices
#   ./launch-dsx-brev.sh mydemo -t 8xlarge        # pick a different size
#   ./launch-dsx-brev.sh mydemo -t any            # try every g7e, cheapest first
#
#   Options: -t, --type SPEC  instance type(s), comma-separated, tried IN ORDER.
#                             Accepts shorthand: 8xlarge / 8x / 8 -> g7e.8xlarge.
#                             'any' expands to every usable g7e, cheapest first.
#                             Default: g7e.4xlarge,g7e.8xlarge,g7e.2xlarge
#            --list-types     show live availability + prices, then exit
#            --min-disk N     disk filter in GB (default 250) -- NB this filters
#                             instance TYPES; it does not resize the root volume
#            --skip-create    don't create; use the named instance as-is
#            --setup-only     provision but don't launch
#            --no-wait        don't block on "RTX Ready"
#            --timeout N      readiness timeout in seconds (default 3600 — a cold
#                             first shader compile measured >25 min on a g7e)
#            --org NAME       Brev org to use (default: jonathan-training-workshop;
#                             '-' means use whatever org is currently active)
#            --check          probe the CLI and exit
#            --check-ports    verify the dashboard firewall rules end to end and
#                             exit. Must run from the laptop: the probes have to
#                             originate OUTSIDE to traverse the firewall, and the
#                             arrivals can only be seen ON the instance. Only this
#                             script sees both ends.
#            -- <args>        escape hatch: replaces ALL generated `brev create` args
#
#   ⚠️ ONE MANUAL STEP — THE BREV FIREWALL. Open 8081/TCP, 49100/TCP and
#      47998/TCP+UDP for the instance in the Brev dashboard. No brev CLI command
#      edits firewall rules. This script prints the list, with the instance's
#      public IP, AS SOON AS PROVISIONING STARTS — so you can do it during the
#      30-45 min build instead of discovering it at the end.
#
#   Secret: export NGC_API_KEY before running. It is written to a 0600 file, copied
#   to the instance, sourced, and shredded — it is NEVER passed on a command line,
#   so it does not appear in the remote process list.
#   Optional: export NVIDIA_API_KEY (AI-agent extension only).
#
#   CLI syntax verified against brev v0.6.322 (2026-08-31):
#     brev create <name> --gpu-name X --min-disk N   (blocks until ready unless -d)
#     brev copy <local> <name>:<remote>              (local -> remote; absolute paths)
#     brev exec <name> "<command>"   /   brev exec <name> @<local-script>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="dsx-demo"
SKIP_CREATE=0
SETUP_ONLY=0
CHECK_ONLY=0
CHECK_PORTS=0
# Pinned: this demo's instances and credits live in one org, and `brev login`
# resets the active org, so relying on "whatever is currently active" silently
# creates instances in the wrong place. Override with --org NAME, or --org - to
# use the active org as-is.
# Pinned deliberately: `brev login` resets the active org, so relying on
# "whatever is active" silently creates instances in the wrong place. Override
# with --org NAME, --org - (use the active org), or DSX_BREV_ORG.
# ⚠️ If you are not the original author, change this to your own org.
DEFAULT_ORG="jonathan-training-workshop"
ORG="${DSX_BREV_ORG:-$DEFAULT_ORG}"
RUN_FLAGS=()
CREATE_ARGS=()

# Verified against `brev search` in org jdursi-conference-demo, 2026-08-31.
# (Instance types and prices are org-independent; only credits differ.)
#
# ⚠️ THE INSTANCE-TYPE DECISION, AND WHY:
#   `brev search --gpu-name 6000 --flex-ports` returns ONLY the AWS g7e.* family.
#   The cheaper RTX Pro 6000 options -- massedcompute_RTXPro6000 ($2.63/hr) and
#   the 2-GPU dmz.rtxpro6000x2.pcie ($6.00/hr) -- do NOT support configurable
#   firewall rules, so **47998/UDP can never be opened on them and streaming is
#   impossible.** Do not "save money" by switching to them.
#   g7e is also AWS, i.e. the same topology as the instance that worked on
#   2026-08-26 (direct public IP, `"ports": []`).
#
#   g7e.4xlarge = 1x RTX PRO Server 6000 (96 GB), 128 GB RAM, 16 vCPU, ~$4.80/hr.
#   Fallbacks: 8xlarge (more RAM), then 2xlarge (64 GB RAM = exactly the documented
#   floor, ~$4.04/hr). More than one GPU does NOT help: a single Kit stream renders
#   on ONE GPU, so g7e.12xlarge at ~$9.94/hr buys nothing for a single session.
#
#   --flex-ports : configurable firewall. Non-negotiable (see above).
#   --stoppable  : lets you `brev stop` between sessions to save credits.
#   --jupyter=false : `brev create` INSTALLS JUPYTER BY DEFAULT in vm/k8s mode
#                  ("--jupyter  Install Jupyter (default true for vm/k8s modes)").
#                  We never use it, and the booth wants the smallest possible
#                  surface: one less service to boot, to keep alive, to compete
#                  for the GPU, and to explain. Observed on the 2026-09-01 run,
#                  which got a Jupyter we had not asked for.
#   --min-disk   : g7e disk is configurable (10 GB-16 TB) and defaults LOW, so this
#                  matters -- the content pack alone is ~20 GB, plus build + shaders.
# Tried IN ORDER; brev falls through to the next on capacity failure.
#   4xlarge = 128 GB RAM, ~$4.80/hr  <- default: best RAM-per-dollar for one stream
#   8xlarge = 256 GB RAM, ~$6.32/hr  <- more vCPUs, faster build
#   2xlarge =  64 GB RAM, ~$4.04/hr  <- cheapest that can stream; RAM is exactly the floor
# 12/24/48xlarge are multi-GPU and buy nothing for a single session (one Kit stream
# renders on ONE GPU) -- reachable via `-t any` or by naming them explicitly, for a
# warm-standby second session or if nothing else has capacity.
DEFAULT_TYPES="g7e.4xlarge,g7e.8xlarge,g7e.2xlarge"
ALL_TYPES="g7e.4xlarge,g7e.2xlarge,g7e.8xlarge,g7e.12xlarge,g7e.24xlarge,g7e.48xlarge"
INSTANCE_TYPES="$DEFAULT_TYPES"
MIN_DISK=250
LIST_TYPES=0

# Must match dsx-setup.sh and dsx-run.sh. On this path they are opened BY HAND in
# the Brev dashboard (the banner below prints them as soon as provisioning starts);
# a Brev Launchable declares the same three ports in its own definition instead.
WEB_PORT=8081
SIGNAL_PORT=49100
MEDIA_PORT=47998

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Accept g7e.8xlarge / 8xlarge / 8x / 8 / any, comma-separated, in any mix.
normalize_types() {
  local spec="$1" out="" t
  local oldifs="$IFS"; IFS=','; set -- $spec; IFS="$oldifs"
  for t in "$@"; do
    t="$(printf '%s' "$t" | tr -d '[:space:]' || true)"
    [ -n "$t" ] || continue
    case "$t" in
      any|all|ANY|ALL) out="$out,$ALL_TYPES"; continue ;;
      g7e.*)           ;;
      *xlarge)         t="g7e.$t" ;;
      *[0-9]x)         t="g7e.${t%x}xlarge" ;;
      [0-9]*)          t="g7e.${t}xlarge" ;;
    esac
    out="$out,$t"
  done
  printf '%s' "${out#,}"
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
POSITIONAL_SEEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --)            shift; CREATE_ARGS=("$@"); break ;;
    -t|--type)     INSTANCE_TYPES="$(normalize_types "${2:?--type needs a value, e.g. 8xlarge}")"; shift ;;
    --list-types)  LIST_TYPES=1 ;;
    --min-disk)    MIN_DISK="${2:?--min-disk needs a value}"; shift ;;
    --skip-create) SKIP_CREATE=1 ;;
    --setup-only)  SETUP_ONLY=1 ;;
    --check)       CHECK_ONLY=1 ;;
    --check-ports) CHECK_PORTS=1 ;;
    --org)         ORG="${2:?--org needs a name}"; [ "$ORG" = "-" ] && ORG=""; shift ;;
    --no-wait)     RUN_FLAGS+=(--no-wait) ;;
    --timeout)     RUN_FLAGS+=(--timeout "${2:?--timeout needs a value}"); shift ;;
    -h|--help)     sed -n '2,41p' "$0"; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *)             [ "$POSITIONAL_SEEN" -eq 0 ] || die "unexpected argument: $1"
                   NAME="$1"; POSITIONAL_SEEN=1 ;;
  esac
  shift
done
# `-- <args>` is a full escape hatch and replaces everything; otherwise build the
# arg list from --type / --min-disk so those flags compose with the fixed filters.
if [ "${#CREATE_ARGS[@]}" -eq 0 ]; then
  CREATE_ARGS=( --type "$INSTANCE_TYPES" --min-disk "$MIN_DISK" --flex-ports --stoppable --jupyter=false )
fi

command -v brev >/dev/null 2>&1 || die "brev CLI not on PATH. Install it, then 'brev login'."

# Must happen before any org-scoped call (ls / search / create all are).
select_org() {
  [ -n "$ORG" ] || { info "using the currently-active org"; return 0; }
  brev org set "$ORG" >/dev/null 2>&1 \
    || die "could not switch to Brev org '$ORG' (see 'brev org ls')."
  local active
  active="$(brev org ls 2>/dev/null | awk '/^[[:space:]]*\*/ {print $2; exit}' || true)"
  if [ -n "$active" ] && [ "$active" != "$ORG" ]; then
    die "asked for org '$ORG' but '$active' is active — refusing to continue."
  fi
  info "Brev org: $ORG"
}

# ---------------------------------------------------------------------------
# --check-ports: is the Brev dashboard firewall actually open?
# ---------------------------------------------------------------------------
# Every brev exec here is wrapped in `timeout`. brev exec has hung outright more
# than once (2026-09-01/02), and an unbounded call makes this look like the check
# itself is broken. Budget ~2 min total: three round trips plus a 40s capture.
# The one manual step in the whole pipeline, and previously unverifiable until a
# browser failed with a black viewport. Two tricks make it testable even before
# anything is listening:
#   * TCP -- "connection refused" means the packet REACHED the host and the
#     kernel replied RST, i.e. the firewall is OPEN. A timeout means blocked.
#   * UDP -- nothing ever replies, so arrival has to be observed with tcpdump on
#     the instance while probes are sent from here. `tcpdump -l` is load-bearing:
#     without line buffering a read taken mid-capture shows zero packets and
#     looks exactly like a blocked port.
if [ "$CHECK_PORTS" -eq 1 ]; then
  brev ls --json >/dev/null 2>&1 || die "'brev ls' failed — run 'brev login' first."
  select_org
  log "resolving $NAME's public IP"
  # ⚠️ TWO traps here, both hit for real on 2026-09-02:
  #  1. `brev exec` APPENDS the instance name to stdout with no separator, so a
  #     remote command that does not end in a newline yields "18.191.85.73dsx-x".
  #     An anchored ^...$ match therefore finds nothing. End with a newline AND
  #     match unanchored.
  #  2. Under `set -o pipefail`, a grep that matches nothing fails the pipeline,
  #     fails the assignment, and `set -e` kills the script SILENTLY -- exit 1,
  #     no message, looks like a hang. `|| true` is load-bearing.
  IP="$(timeout 120 brev exec "$NAME" 'TOK=$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null); printf "%s\n" "$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/public-ipv4)"' 2>/dev/null \
        | tr -d '\r' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
  [ -n "$IP" ] || die "could not determine $NAME's public IP (is it running?)"
  info "$IP"

  log "arming the capture on $NAME"
  timeout 120 brev exec "$NAME" "rm -f /tmp/dsx-portcheck.txt; nohup sudo timeout 45 tcpdump -l -ni any 'udp port $MEDIA_PORT and not host 127.0.0.1' > /tmp/dsx-portcheck.txt 2>&1 & echo armed" >/dev/null 2>&1 \
    || die "could not start the capture on $NAME"

  log "probing from here (this machine is outside the instance's firewall)"
  for p in "$WEB_PORT" "$SIGNAL_PORT" "$MEDIA_PORT"; do
    if timeout 8 bash -c "echo > /dev/tcp/$IP/$p" 2>/dev/null; then
      info "$p/TCP  OPEN — and something is listening"
    elif [ $? -eq 124 ]; then
      warn "$p/TCP  BLOCKED (timed out) — add it in the Brev dashboard"
    else
      info "$p/TCP  OPEN — nothing bound (normal: Kit binds $MEDIA_PORT as UDP only)"
    fi
  done
  for i in $(seq 1 12); do printf 'dsx-portcheck' > "/dev/udp/$IP/$MEDIA_PORT" 2>/dev/null || true; done
  info "sent 12 UDP probes to $MEDIA_PORT"

  log "reading the capture back (waiting for it to flush)"
  GOT="$(timeout 180 brev exec "$NAME" 'sleep 40; printf "%s\n" "$(grep -cE "^[0-9]" /tmp/dsx-portcheck.txt 2>/dev/null || echo 0)"' 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+' | head -n1 || true)"
  # NB: the capture counts ALL udp/$MEDIA_PORT traffic, so if a viewer is connected
  # the live media stream is in here too -- 11295 "probes" was observed on
  # 2026-09-02 with a session running. Any arrival proves the rule is open, so
  # report that, never a ratio against the 12 sent.
  if [ "${GOT:-0}" -gt 0 ]; then
    if [ "${GOT:-0}" -gt 100 ]; then
      info "$MEDIA_PORT/UDP  OPEN — $GOT packets seen (includes live stream traffic)"
    else
      info "$MEDIA_PORT/UDP  OPEN — $GOT of 12 probes arrived"
    fi
    log "✅ firewall looks correct. If streaming still fails it is NOT the ports."
  else
    warn "$MEDIA_PORT/UDP  NO PROBES ARRIVED."
    warn "This is the rule people miss: $MEDIA_PORT must be added as **UDP**, not"
    warn "only TCP. Without it the page loads, the globe renders (that is drawn"
    warn "client-side), and the viewport stays black while Kit logs"
    warn "  'Got stop event while waiting for client connection'."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --list-types: what can I actually get right now, and what does it cost?
# ---------------------------------------------------------------------------
if [ "$LIST_TYPES" -eq 1 ]; then
  brev ls --json >/dev/null 2>&1 || die "'brev ls' failed — run 'brev login' first."
  select_org
  log "6000-class GPUs with a CONFIGURABLE FIREWALL, in your active org"
  info "(only these can have 47998/UDP opened, so only these can stream)"
  echo
  brev search --gpu-name "6000" --flex-ports --stoppable --wide 2>&1 | sed 's/^/  /'
  cat <<EOF

  Pick one with -t. Shorthand accepted (8xlarge / 8x / 8 all mean g7e.8xlarge):

    ./launch-dsx-brev.sh $NAME -t 8xlarge          # a single different size
    ./launch-dsx-brev.sh $NAME -t 8xlarge,2xlarge  # try 8, fall back to 2
    ./launch-dsx-brev.sh $NAME -t any              # try every g7e, cheapest first

  Current default order: $DEFAULT_TYPES
  More than one GPU does not speed up a single session — one Kit stream renders
  on ONE GPU — so 12/24/48xlarge are only worth it for a warm-standby second
  session, or when nothing smaller has capacity.
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# --check: probe without spending anything
# ---------------------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
  log "brev CLI"
  info "$(brev --version 2>&1 | grep -i version | head -n1 || true)"
  if brev ls --json >/dev/null 2>&1; then
    info "auth: OK"
  else
    warn "auth: not logged in. Run:  brev login"
    exit 1
  fi
  select_org
  log "orgs"
  brev org ls 2>&1 | sed 's/^/    /' || true
  log "instances"
  brev ls 2>&1 | sed 's/^/    /' || true
  # NB: the GPU names have no spaces ("RTXPro6000", "RTX PRO Server 6000"), so a
  # literal "RTX PRO 6000" filter matches nothing. Match on "6000".
  log "6000-class GPUs you can allocate"
  brev search --gpu-name "6000" --wide 2>&1 | sed 's/^/    /' || true
  log "...of those, the ones with CONFIGURABLE FIREWALL (--flex-ports) — the only usable ones"
  info "(without configurable ports you cannot open 47998/UDP, so streaming is impossible)"
  brev search --gpu-name "6000" --flex-ports --stoppable --wide 2>&1 | sed 's/^/    /' || true
  cat <<EOF

If the SECOND list is empty, DSX streaming cannot work on what you can allocate in
this org — raise it before booking booth time.

Note: creating an instance WITH a configurable firewall does not OPEN anything.
Once it is up you must add $WEB_PORT/TCP, $SIGNAL_PORT/TCP and $MEDIA_PORT/TCP+UDP by hand in
the Brev dashboard — a real run prints the list as soon as provisioning starts.

Instance types this script will try, in order: $INSTANCE_TYPES
  override with:  -t 8xlarge   /   -t 8xlarge,2xlarge   /   -t any
  see prices:     ./launch-dsx-brev.sh --list-types

Dry-run the exact creation without spending anything:
  brev create $NAME --type $INSTANCE_TYPES --min-disk $MIN_DISK --flex-ports --stoppable --jupyter=false --dry-run
EOF
  exit 0
fi

brev ls --json >/dev/null 2>&1 || die "'brev ls' failed — run 'brev login' first."
select_org
: "${NGC_API_KEY:?export NGC_API_KEY before running (or source it from your secret store)}"
for f in dsx-setup.sh dsx-run.sh; do
  [ -f "$HERE/$f" ] || die "$f not found next to this script ($HERE)."
done

TMPDIR_LOCAL="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_LOCAL"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------
# Report the instance's Brev-side state; used both before starting and after any
# remote step fails, since "the instance stopped underneath us" and "the script is
# broken" look identical from the laptop otherwise.
instance_state() {
  brev ls 2>/dev/null | awk -v n="$NAME" '$1==n {print $2; exit}'
}
explain_if_stopped() {
  local st; st="$(instance_state || true)"
  case "$st" in
    ""|RUNNING) return 1 ;;
    *)
      warn "instance '$NAME' is in state '$st' — it was stopped OUTSIDE this script."
      warn "That is a Brev-side event, not a failure of the setup script. Most likely:"
      warn "  * the org ran out of CREDITS   (check billing for the active org)"
      warn "  * an auto-stop / idle policy on the instance"
      warn "  * capacity reclaim by the provider"
      warn "Resume with:  brev start $NAME && ./launch-dsx-brev.sh $NAME --skip-create"
      warn "dsx-setup.sh is idempotent, so finished work is not redone — but"
      warn "ephemeral/instance-store disks are WIPED, so a pack there re-downloads."
      return 0 ;;
  esac
}

if [ "$SKIP_CREATE" -eq 1 ]; then
  log "--skip-create: using existing instance '$NAME'"
  STATE="$(instance_state || true)"
  info "current state: ${STATE:-<not found>}"
  case "$STATE" in
    RUNNING) ;;
    STOPPED|PAUSED|OFF)
      log "instance is stopped — starting it"
      brev start "$NAME" || die "could not start '$NAME'. If the org is out of credits, top it up first." ;;
    STOPPING)
      die "'$NAME' is still STOPPING. Wait for STOPPED, then re-run — this script will start it." ;;
    "") die "no instance named '$NAME' in the active org (see 'brev ls')." ;;
  esac
else
  log "creating Brev instance '$NAME'"
  info "brev create $NAME ${CREATE_ARGS[*]}"
  # `brev create` blocks until the instance is ready unless -d/--detached is passed,
  # so there is no need to poll `brev ls` (whose output format changes when piped).
  brev create "$NAME" "${CREATE_ARGS[@]}" || die "brev create failed — most often no capacity
  for these types right now: $INSTANCE_TYPES

  See what IS available:   ./launch-dsx-brev.sh --list-types
  Then retry with another: ./launch-dsx-brev.sh $NAME -t 8xlarge
  Or try them all:         ./launch-dsx-brev.sh $NAME -t any
  Dry-run (free):          brev create $NAME ${CREATE_ARGS[*]} --dry-run"
fi

# Readiness = "can I run a command on it", which is what we actually need. This is
# more reliable than parsing `brev ls`, whose columns differ between tty and pipe.
log "waiting for '$NAME' to accept commands"
REACHABLE=0
for i in $(seq 1 40); do
  if brev exec "$NAME" "true" >/dev/null 2>&1; then REACHABLE=1; info "reachable."; break; fi
  if [ $(( i % 4 )) -eq 0 ]; then info "still waiting... ($(( i * 15 ))s)"; fi
  sleep 15
done
[ "$REACHABLE" -eq 1 ] || die "'$NAME' never accepted a command. Check 'brev ls'; try 'brev shell $NAME'."

# ---------------------------------------------------------------------------
# ship scripts + secret
# ---------------------------------------------------------------------------
ENVFILE="$TMPDIR_LOCAL/dsx.env"
(
  umask 077
  {
    printf 'export NGC_API_KEY=%s\n' "$NGC_API_KEY"
    if [ -n "${NVIDIA_API_KEY:-}" ]; then
      printf 'export NVIDIA_API_KEY=%s\n' "$NVIDIA_API_KEY"
    fi
    # Forward dsx-setup.sh's tuning knobs, so e.g. putting the content pack on a
    # big instance-store NVMe works from the laptop side:
    #   DSX_DATA_DIR=/opt/dlami/nvme/dsx ./launch-dsx-brev.sh ...
    for v in DSX_DATA_DIR DSX_DOWNLOAD_DIR DSX_WORKDIR DSX_SKIP_BUILD; do
      eval "val=\${$v:-}"
      if [ -n "$val" ]; then printf 'export %s=%s\n' "$v" "$val"; fi
    done
  } > "$ENVFILE"
)
if [ -n "${DSX_DATA_DIR:-}" ]; then info "content pack will go to: $DSX_DATA_DIR"; fi

# Staged through /tmp rather than instance:~/… — the remote `~` in a copy target is
# not reliably expanded, and /tmp is guaranteed to exist whoever the container user is.
log "copying scripts + credentials to '$NAME'"
brev copy "$HERE/dsx-setup.sh" "${NAME}:/tmp/dsx-setup.sh" || die "brev copy failed."
brev copy "$HERE/dsx-run.sh"   "${NAME}:/tmp/dsx-run.sh"   || die "brev copy failed."
brev copy "$ENVFILE"           "${NAME}:/tmp/dsx.env"      || die "brev copy failed."

# ---------------------------------------------------------------------------
# provision  (via `brev exec <name> @localfile`, which sidesteps quoting entirely)
# ---------------------------------------------------------------------------
# Provisioning runs INSIDE tmux on the instance, not in the foreground of this SSH
# session. Learned the hard way: a 45-minute provision died when the instance was
# stopped mid-run, and an SSH blip or a sleeping laptop would do the same. tmux
# keeps it alive; we only follow the log, and following is resumable.
cat > "$TMPDIR_LOCAL/provision.sh" <<'WRAP'
#!/usr/bin/env bash
set -uo pipefail
install -m 0755 /tmp/dsx-setup.sh "$HOME/dsx-setup.sh"
install -m 0755 /tmp/dsx-run.sh   "$HOME/dsx-run.sh"
chmod 600 /tmp/dsx.env
LOG="$HOME/dsx-setup.log"
if tmux has-session -t dsx-provision 2>/dev/null; then
  echo "__DSX_PROVISION_ALREADY_RUNNING__"; exit 0
fi
: > "$LOG"
tmux new-session -d -s dsx-provision \
  "set -a; . /tmp/dsx.env; set +a; bash \"$HOME/dsx-setup.sh\" >>\"$LOG\" 2>&1; \
   echo \"__DSX_EXIT__:\$?\" >>\"$LOG\"; \
   shred -u /tmp/dsx.env 2>/dev/null || rm -f /tmp/dsx.env; \
   rm -f /tmp/dsx-setup.sh /tmp/dsx-run.sh"
echo "__DSX_PROVISION_STARTED__"
WRAP

# ---------------------------------------------------------------------------
# the one step no CLI can do for you
# ---------------------------------------------------------------------------
# Asked of the instance itself, through the same metadata service dsx-run.sh uses
# to build the ICE candidate — so the address printed here is the one Kit will
# advertise, which is also the one the dashboard rules have to admit.
instance_public_ip() {
  cat > "$TMPDIR_LOCAL/pubip.sh" <<'IPS'
#!/usr/bin/env bash
IP=""
TOK="$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token \
       -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
if [ -n "$TOK" ]; then
  IP="$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $TOK" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
fi
[ -n "$IP" ] || IP="$(curl -fsS -m 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
[ -n "$IP" ] || IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
printf '__DSX_IP__:%s\n' "$IP"
IPS
  brev exec "$NAME" "@$TMPDIR_LOCAL/pubip.sh" 2>/dev/null | tr -d '\r' \
    | sed -n 's/^__DSX_IP__:\(\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\)$/\1/p' | head -n1
}

# Printed the moment provisioning starts, NOT at the end. Opening the firewall is
# the only step in this pipeline a human has to do in a browser, it takes two
# minutes, and provisioning hands you 30-45 in which to do it. Left to the end it
# gets discovered the expensive way: a build that worked and a viewport that stays
# black, with Kit logging "Got stop event while waiting for client connection".
ports_banner() {
  local ip host
  ip="$(instance_public_ip || true)"
  host="${ip:-<instance public IP>}"
  cat <<EOF

############################################################
#  ACTION REQUIRED NOW — open the firewall while this builds
############################################################

  Brev dashboard -> instance '$NAME' -> TCP/UDP Ports, and add:

      $WEB_PORT    web UI      TCP
      $SIGNAL_PORT   signaling   TCP
      $MEDIA_PORT   media       TCP *and* UDP   <-- UDP carries the video

  Instance public IP : $host
  Booth URL will be  : http://$host:$WEB_PORT/?server=$host&signalingPort=$SIGNAL_PORT

  Provisioning needs none of these open, so do it any time in the next 30-45
  minutes. The launch step at the end is what needs them.

  Why by hand: no brev CLI command edits firewall rules (--flex-ports only
  SELECTS instance types whose rules CAN be changed). 'brev port-forward' does
  exist, but it tunnels TCP only — it cannot carry $MEDIA_PORT/UDP, so it is not
  a substitute for opening the port.

  CLI-path only: a Brev Launchable declares these ports in its own definition,
  so the Launchable pass replaces this step rather than inheriting it.
############################################################

EOF
}

log "provisioning (deps + ~33 GB content pack + build — 30-45 min on a cold instance)"
info "runs under tmux on the instance; an SSH drop will not kill it"
PROV_OUT="$TMPDIR_LOCAL/provision.out"
brev exec "$NAME" "@$TMPDIR_LOCAL/provision.sh" 2>&1 | tee "$PROV_OUT" || true
if ! grep -qE '__DSX_PROVISION_(STARTED|ALREADY_RUNNING)__' "$PROV_OUT"; then
  explain_if_stopped || true
  die "could not start provisioning on '$NAME'. Inspect:  brev shell $NAME"
fi

# Provisioning is now running under tmux on the instance; this is the window.
ports_banner

# Follow the log until the sentinel. On an SSH drop we retry the FOLLOW, not the work.
PROV_RC=""
for attempt in 1 2 3 4 5; do
  if [ "$attempt" -gt 1 ]; then info "reconnecting to the provisioning log (attempt $attempt)..."; fi
  brev exec "$NAME" 'tail -n +1 -f "$HOME/dsx-setup.log" | sed -u "/__DSX_EXIT__:/q"' 2>&1 \
    | tr -d '\r' | tee "$TMPDIR_LOCAL/follow.$attempt" || true
  # `|| true` is load-bearing: under `set -o pipefail` a grep that finds nothing
  # (i.e. provisioning still in flight) would fail the pipeline, fail the
  # assignment, and silently kill this script via `set -e`.
  PROV_RC="$(grep -hoE '__DSX_EXIT__:[0-9]+' "$TMPDIR_LOCAL"/follow.* 2>/dev/null | tail -n1 | cut -d: -f2 || true)"
  if [ -n "$PROV_RC" ]; then break; fi
  if explain_if_stopped; then break; fi
  sleep 10
done

if [ -z "$PROV_RC" ]; then
  die "lost contact with '$NAME' before provisioning finished — it may still be running.
  Check:   brev exec $NAME 'tail -20 \$HOME/dsx-setup.log'
  Resume:  ./launch-dsx-brev.sh $NAME --skip-create"
fi
if [ "$PROV_RC" -ne 0 ]; then
  explain_if_stopped || true
  die "provisioning failed on '$NAME' (exit $PROV_RC).
  dsx-setup.sh is idempotent — fix the cause, then re-run with --skip-create.
  Log:  brev exec $NAME 'tail -50 \$HOME/dsx-setup.log'"
fi
log "provisioning complete"

if [ "$SETUP_ONLY" -eq 1 ]; then
  log "--setup-only: provisioned but not started. Start it with:"
  info "brev exec $NAME \"bash ~/dsx-run.sh start\""
  exit 0
fi

# ---------------------------------------------------------------------------
# launch
# ---------------------------------------------------------------------------
log "launching the demo"
warn "LAST CALL on the firewall — $WEB_PORT/TCP, $SIGNAL_PORT/TCP and $MEDIA_PORT/TCP+UDP must be"
warn "exposed for '$NAME' in the Brev dashboard (the banner printed when provisioning"
warn "started has the details). No brev CLI command opens it. Without $MEDIA_PORT/UDP the"
warn "page loads, the viewport stays black, and Kit logs 'Got stop event while"
warn "waiting for client connection'."

RUN_ARGS=""
if [ "${#RUN_FLAGS[@]}" -gt 0 ]; then RUN_ARGS=" ${RUN_FLAGS[*]}"; fi
if ! brev exec "$NAME" "bash \$HOME/dsx-run.sh start$RUN_ARGS"; then
  explain_if_stopped || true
  die "launch failed. Inspect:
    brev exec $NAME 'bash \$HOME/dsx-run.sh status'
    brev exec $NAME 'bash \$HOME/dsx-run.sh logs kit'   (or: brev shell $NAME; tmux attach -t dsx-kit)
  The kit/web tmux sessions survive an SSH drop, so if the connection merely
  dropped, resume watching with:  brev exec $NAME 'bash \$HOME/dsx-run.sh wait'"
fi

cat <<EOF

============================================================
'$NAME' is up. The booth URL was printed above.

  Status / drift check :  brev exec $NAME "bash \$HOME/dsx-run.sh status"
  Restart web  (L2)    :  brev exec $NAME "bash \$HOME/dsx-run.sh web"
  Restart kit  (L3)    :  brev exec $NAME "bash \$HOME/dsx-run.sh kit"
  Watch the log        :  brev shell $NAME  ->  tmux attach -t dsx-kit
  Save credits         :  brev stop $NAME

⚠️  A Brev stop/start assigns a NEW public IP. After restarting the instance run
    the 'kit' command above — the old IP is baked into Kit's advertised ICE
    candidate and media will silently never connect. 'status' flags this.
============================================================
EOF
