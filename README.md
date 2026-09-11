# Running the NVIDIA Omniverse DSX Blueprint on Brev

Deployment tooling for the [Omniverse DSX Blueprint for AI Factory Digital
Twins](https://github.com/NVIDIA-Omniverse-blueprints/omniverse-dsx-blueprint-for-ai-factories)
on [Brev](https://brev.nvidia.com) GPU instances — a **Brev Launchable** for
one-click deploys, plus **CLI scripts** as a scripted/backup path.

Everything here was derived from getting the blueprint streaming to a remote
browser and writing down each thing that wasn't obvious. Most of the value is in
the comments; they are deliberately verbose about *why*.

> This is unofficial community tooling, not an NVIDIA product. The blueprint
> itself is NVIDIA's and is licensed separately.

## Two ways in

| | |
|---|---|
| **`launchable/`** | Brev Launchable — a self-contained setup script plus the dashboard settings. One-click, and the only path with **region control**. |
| **`scripts/`** | CLI path — `launch-dsx-brev.sh` (laptop) creates/provisions/launches, `dsx-setup.sh` provisions, `dsx-run.sh` runs/restarts/diagnoses. |

Start with `launchable/README-LAUNCHABLE.md`.

## Quick start (CLI path)

```bash
export NGC_API_KEY='...'                      # never hardcoded; shipped 0600, shredded remotely
export NVIDIA_API_KEY='...'                   # enables the AI agent; optional
./scripts/launch-dsx-brev.sh --check          # probe the CLI, spend nothing
./scripts/launch-dsx-brev.sh my-dsx           # create + provision + launch
./scripts/launch-dsx-brev.sh my-dsx --check-ports   # verify the firewall end to end
```

⚠️ **Set your own Brev org.** `scripts/launch-dsx-brev.sh` pins `DEFAULT_ORG` to
the original author's; change it, or pass `--org NAME` / `DSX_BREV_ORG`.

## The things that cost the most time

Each of these is a real failure we hit, and each is silent or misleading:

1. **The blueprint README omits the GL/X libraries.** Kit will not start on a
   headless cloud image — `libXt.so.6: cannot open shared object`. On Ubuntu
   24.04 `libxt6` is `libxt6t64`, so install it separately or one missing name
   takes the whole bundle down.
2. **`ngc registry resource download-version` needs an org**, or fails with
   `Missing org - If Authenticated, org is also required`. Not documented.
3. **The content pack has an extra directory level** — the scene is at
   `<extract>/DSX_BP_/DSX_BP/Assembly/DSX_Main_BP.usda`. Find it; don't hardcode.
4. **Do not pre-build with `./repo.sh build`.** It resolves livestream
   `9.0.0`, which *cannot stream*: `primaryStream.publicIp` is silently ignored,
   so Kit advertises only private ICE candidates and the browser hangs at
   `checking`. Letting `run_streaming.sh` build on first launch resolves
   `9.1.0/9.2.0`, which works. **Always check which versions loaded.**
5. **`primaryStream.publicIp` is required** — Kit is ICE-Lite and otherwise
   offers only `127.0.0.1 / 172.31.x.x / 172.17.0.1`. A Brev stop/start
   reassigns the public IP, and a stale value fails *silently*: black viewport,
   no error.
6. **The ready line is `RTX ready`** — lowercase `r`, and written to **stdout
   only**, never to `kit_*.log`. A case-sensitive grep for `RTX Ready` finds
   nothing on a perfectly healthy run. `app ready` (~25 s) is *not* readiness.
7. **There is no `streaming.html`.** The URL is
   `http://<ip>:8081/?server=<ip>&signalingPort=49100`. Vite's SPA fallback
   serves the wrong path happily, hiding the mistake.
8. **One viewer at a time.** `primaryStream` serves a single interactive client;
   a second browser can kick the first (`NVST_R_BUSY`). Use the tested “all IPs”
   rules and avoid opening a second browser against the same instance.
9. **The Brev CLI cannot choose a region** — no flag, and no region in its data
   model. The dashboard can. Identical invocations landed in Tokyo and Ohio on
   consecutive days, which is the difference between a responsive demo and a
   broken-feeling one.
10. **A Brev stop/start does not rerun the Launchable setup script.** The
    Launchable installs `/home/ubuntu/dsx-run.sh`, which redetects the changed
    public IP and restarts DSX. Copy the exact `brev exec ...` command printed at
    the end of the setup log and run it after resuming the VM.


## Ports

| Port | Protocol | Purpose |
|---|---|---|
| 8081 | TCP | web UI |
| 49100 | TCP | signalling |
| **47998** | **TCP *and* UDP** | media — **UDP is what carries video** |
| 8012 | TCP | AI-agent HTTP API |

The CLI cannot open these; use the Brev dashboard (a Launchable declares them).
Verify rather than assume:

```bash
./scripts/launch-dsx-brev.sh my-dsx --check-ports
```

TCP "connection refused" means **open** (the packet arrived, nothing was bound);
a **timeout** means blocked. UDP is confirmed by capturing on the instance while
probing from outside.

## Notes

- Comments referencing "the runbook" point at the author's internal operating
  notes, which are not published. The scripts are self-contained without them.
- Requires an RTX Pro 6000 Blackwell (RT cores) and a Brev instance type with a
  **configurable firewall** — on AWS, the `g7e.*` family. Cheaper RTX Pro 6000
  options cannot open `47998/UDP` and therefore cannot stream at any price.
