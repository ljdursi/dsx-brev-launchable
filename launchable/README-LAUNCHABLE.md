# DSX Brev Launchable — configuration

Everything the Brev dashboard needs, plus why each setting is what it is. The
setup script is `dsx-launchable-setup.sh`; it is self-contained and clones the
public blueprint itself, so it works pasted into the dashboard or fetched from a
repo.

> ✅ **Status: DEPLOYED AND WORKING (2026-09-02).** One click to a streaming
> demo in **~18 minutes** — dependencies, a 32.69 GB content pack in 2m 6s, the
> build, and `RTX ready`. Verified: livestream **9.1.0/9.1.0/9.2.0**, tmux
> surviving the setup script exiting, and streaming to a browser.

## 0. How the secret actually reaches the script (learned the hard way)

The first deploy failed in 7 seconds with
`NGC_API_KEY launch parameter is required`. It is a **two-step** binding and the
second step is easy to miss:

1. **On the Launchable:** define a **Text** launch parameter named exactly
   `NGC_API_KEY`. *"The parameter name controls the environment variable name;
   the secret name does not need to match it."*
2. **At deploy time:** find that parameter under **"Setup values"**, choose
   **"Use a secret"**, and select the secret and version.

Miss step 2 and the parameter arrives empty, which looks exactly like never
having defined it.

**Execution model**, useful when debugging a failed deploy:

- Brev runs the setup script as a **systemd oneshot unit** (`User=ubuntu`, *not*
  root), logging to `/home/ubuntu/.lifecycle-script-*.log`.
- `TimeoutStartSec=0` and Brev polls with an 86400 s budget, so **a long setup
  script is fine** — ours blocks for up to 40 minutes.
- `KillMode=process` means only the main process is reaped when the unit exits,
  so **tmux sessions survive** the setup script finishing. Verified.
- Launch parameters **do not persist**: *"After setup finishes, the value is not
  automatically available in a later SSH session."* That is why the script keeps
  `~/.ngc/config` — otherwise a re-download after a stop/start would be
  impossible without a re-deploy.

## 1. Hardware

| Setting | Value | Why |
|---|---|---|
| GPU | **RTX PRO 6000 Blackwell** (AWS `g7e.*`) | DSX needs RT cores. Confirmed: `g7e.4xlarge` is a real RTX PRO 6000 Blackwell Server Edition. |
| Size | **`g7e.4xlarge`** (~$4.80/hr) | 128 GB RAM, best RAM-per-dollar for one stream. More GPUs do **not** help — one Kit stream renders on ONE GPU. |
| Firewall | **configurable ports required** | Only the AWS `g7e.*` family qualifies. The cheaper `massedcompute_RTXPro6000` ($2.63/hr) cannot open 47998/UDP, so it can never stream. |
| Disk | **250 GB+** | ~33 GB archive + ~33 GB extracted + build + shader cache. |
| **Region** | **near Montreal** (`us-east-1` / `us-east-2` / `ca-central-1`) | ⚠️ **The main reason to use a Launchable rather than the CLI.** `brev create` has no region control at all; identical invocations landed in Tokyo and Ohio on consecutive days. Tokyo→Montreal is ~150–200 ms vs Ohio's ~30 ms — the difference between responsive and broken. |

## 2. Mode and setup script

**VM Mode**, with `dsx-launchable-setup.sh` as the setup script. Brev runs it
automatically, as root, after the instance starts.

Expect **~25–40 minutes** on first deploy: dependencies, a 33 GB download and
extraction, then a first build inside `run_streaming.sh` (~12 min). The script
blocks until the renderer reports ready and prints the URL.

## 3. Launch parameters

| Parameter | Required | Notes |
|---|---|---|
| `NGC_API_KEY` | **yes** | **Define with NO DEFAULT** and back it with an **organization secret** (one already exists in the target org). NVIDIA's own guidance: do not store reusable credentials as parameter defaults. ⚠️ The parameter must be named **exactly** `NGC_API_KEY` — Brev passes parameters in as env vars of the same name, and the script fails fast if it is absent. The script writes it to `~/.ngc/config` (mode 0600) and **keeps it**, so a stop/start that wipes an instance-store content pack can re-download without a re-deploy. That is a deliberate call: it is a read-only key on a VM that is stopped when idle and revoked after the conference. `DSX_SHRED_NGC_CONFIG=1` removes it after the download if you prefer. **The risk being managed is a key in a searchable public repo** — hence the org secret, and hence no credential in any version-controlled file. |
| `NVIDIA_API_KEY` | no | AI-agent extension only. The viewer, camera and configurator all work without it. |

## 4. Ports

| Port | Protocol | Purpose |
|---|---|---|
| 8081 | TCP | web UI |
| 49100 | TCP | signalling |
| **47998** | **TCP *and* UDP** | media |

> ⚠️ **Re-check the port list after any edit.** On 2026-09-02, adding `8012` to
> an existing Launchable **silently dropped the other three**, and the deploy
> came up with everything blocked. The symptom is a browser timeout ("took too
> long to respond") rather than "connection refused" — timeout means the
> firewall dropped it; refused means it arrived and nothing was listening. Verify
> with `./scripts/launch-dsx-brev.sh <name> --check-ports` before trusting it.

**47998 must include UDP.** Without it the page loads, the globe renders — that
is drawn client-side, so it proves nothing — and the viewport stays black while
Kit logs `Got stop event while waiting for client connection`.

> 🚩 **Restrict the rules to the deployer's IP, not "all IPs", if the booth
> allows it.** `primaryStream` serves **one interactive viewer**; a second
> browser on the same URL can kick the first (`NVST_R_BUSY`). With open rules,
> anyone holding the URL can take the demo down mid-conversation.

## 5. Access

- **View access: "Only my organization"** — restricts who can view/deploy to
  members of your Brev org, and ties the credit pool to the demo.
- **Secure Links** put NVIDIA-account login in front of the HTTP service. Worth
  evaluating: it would also mitigate the one-viewer problem by gating who can
  reach the page at all. Untested by us.
- Turn **Jupyter off** if the mode allows. `brev create` installs JupyterLab by
  default bound to `0.0.0.0:8888` with an **empty token and password** — an
  unauthenticated code-execution surface on a conference machine.

## 6. What the script encodes that the blueprint README omits

Each of these cost real debugging time:

1. **The GL/X library bundle** — Kit will not start on a headless cloud image
   without it (`libXt.so.6: cannot open shared object`). Not in the README.
   `libxt6` is installed separately because 24.04 renamed it `libxt6t64`.
2. **NGC CLI needs an org** — the documented download path fails with
   `Missing org - If Authenticated, org is also required`.
3. **The content pack has an extra directory level** — the scene is at
   `<extract>/DSX_BP_/DSX_BP/Assembly/`, not `<extract>/DSX_BP/Assembly/`. The
   script finds it rather than hardcoding.
4. **Do NOT pre-build with `./repo.sh build`** — it resolves livestream
   **9.0.0**, which cannot stream, because `primaryStream.publicIp` is silently
   ignored on it. Letting `run_streaming.sh` build on first launch resolves
   **9.1.0 / 9.2.0**, which works. This was the single hardest bug of the
   project.
5. **`primaryStream.publicIp` is required** — Kit is ICE-Lite and otherwise
   advertises only private candidates.
6. **The ready line is `RTX ready`** — lowercase, and written to **stdout only**,
   never to `kit_*.log`.
7. **There is no `streaming.html`** — the URL is `/?server=…&signalingPort=…`.
   Vite's SPA fallback serves the wrong path happily, which hides the mistake.

## 7. Relationship to the scripts in `../scripts/`

`scripts/` is the **backup path** and the source material this was derived from:
`launch-dsx-brev.sh` (laptop-side create/provision/launch), `dsx-setup.sh`
(provision), `dsx-run.sh` (launch, restart tiers, `check-ports`,
`diagnose`). They remain the fallback if a Launchable deploy misbehaves at the
booth, and `dsx-run.sh` is still the right tool for restarting a running demo.

Full history, gotchas and evidence: `background/ai-factory-demo-setup-runbook.md`.

## 8. Planned for v2 — the AI agent

v1 deliberately ships without the AI-agent extension: the 3D viewer, camera
controls, configurator and CFD/thermal sims all work without it, and it adds
moving parts. Enabling it needs **three** things, not just the API key — two of
which we have observed directly on every run so far.

1. **`NVIDIA_API_KEY` launch parameter.** Optional, no default; get a key from
   [build.nvidia.com](https://build.nvidia.com/). The setup script already
   handles it if present.

2. **Port `8012/TCP` must also be declared.** The agent exposes its HTTP API
   there (`DSX_AGENT_PORT`). Without it the web client logs
   `GET http://<ip>:8012/api/agent/preferences/local-user net::ERR_CONNECTION_TIMED_OUT`
   and `[ConfiguratorPanel] Failed to load GPU preference` — observed on every
   deploy to date, and harmless while the agent is disabled.

3. **A `typing_extensions` fix.** All four `omni.ai.*` extensions currently fail
   to import with
   `TypeError: _TypedDictMeta.__new__() got an unexpected keyword argument 'extra_items'`,
   all on the same line of one vendored dependency — so it is one broken dep,
   not four problems. The bundled `typing_extensions` predates PEP 728's
   `extra_items`. From the blueprint root:
   ```bash
   python3 -m pip install --upgrade --target \
     _build/linux-x86_64/release/exts/omni.ai.langchain.core/pip_core_prebundle \
     "typing_extensions>=4.13"
   ```
   (Add `--break-system-packages` on 24.04 if pip objects — harmless with
   `--target`. If a *different* import error then appears, pin
   `typing_extensions==4.13.2`.) Reversible: a clean rebuild restores the
   original.

**These errors are non-fatal.** Kit reaches `RTX ready` and the demo works with
them present, which is why v1 leaves them alone. Anything claiming the agent is
enabled should be verified against the extension load errors in the Kit log, not
assumed from the key being set.
