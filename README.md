# omp-subscription-usage

Opt-in 5-hour and weekly subscription quota pacing for **oh-my-pi** subagents.

The policy shapes each provider's short (5h) and weekly (7d) quota windows into
hard and soft caps, prefers accounts with headroom, allows soft-cap fallback,
and caps background concurrency without touching interactive chat. It pins the
admitted durable credential for the request and releases the slot exactly once
at that request's terminal boundary.

Target: **oh-my-pi `v19.2.1`** (`can1357/oh-my-pi`, commit `b55cd1b`).

## Why this is a source overlay, not `omp plugin install`

OMP extension plugins can edit a provider payload, register tools/commands, and
observe lifecycle events. They cannot choose the live credential, reserve a
quota slot atomically, or bracket the provider dispatch. Reservation happens in
the native auth resolver and the release in the pi-ai attempt loop, so this
feature ships as a patch against the OMP source tree. `omp plugin install ...`
would install an extension that cannot enforce the policy; this repository does
not fake that.

The installed `omp` binary is never modified. The launcher runs a patched
source checkout with Bun.

## Install

Requirements: `git`, network access, and a Bun-capable host. The installer
fetches Bun if it is missing.

One command:

```bash
curl -fsSL https://raw.githubusercontent.com/DoctorBlackZ33/omp-subscription-usage/v0.2.2/install.sh | bash
```

The installer:

1. Looks for the OMP directory at `~/.omp` (or `PI_CONFIG_DIR` / `XDG_DATA_HOME`
   when set), prints it, and lets you choose a custom path.
2. Lists every profile it finds (`default` plus `~/.omp/profiles/*/agent`) and
   asks which profiles should receive the policy. Pick `all`, `none`, numbers
   (`1,3`, `1-3`), or names (`codex,work`).
3. Clones `can1357/oh-my-pi` at tag `v19.2.1` into
   `~/.local/share/omp-subscription-usage/oh-my-pi` (or reuses it), applies the
   patch, installs workspace deps and prebuilt native bindings.
4. Writes `~/.local/bin/omp-subscription-usage`, copies the example YAML into
   the selected profiles, and offers a shell function so `omp` launches the
   patched runtime (optional; the stock binary is untouched).

Non-interactive / scripted:

```bash
curl -fsSL https://raw.githubusercontent.com/DoctorBlackZ33/omp-subscription-usage/v0.2.2/install.sh \
  | bash -s -- --yes --omp-dir "$HOME/.omp" --profiles all
```

Local clone (same script, artifacts read from the checkout):

```bash
git clone https://github.com/DoctorBlackZ33/omp-subscription-usage.git
cd omp-subscription-usage
./install.sh
```

Options:

| Flag | Effect |
| --- | --- |
| `--omp-dir PATH` | OMP state root (default `~/.omp`) |
| `--checkout PATH` | Patch an existing `v19.2.1` source checkout |
| `--profiles LIST` | `all`, `none`, indexes/ranges (`1,3`), or names (`codex`) |
| `--yes` | Non-interactive; all profiles, keep existing YAML |
| `--force` | Replace existing policy files (timestamped backup) |
| `--no-config` | Install the runtime only; write no profile YAML |
| `--alias` | Add the `omp` shell function to `.bashrc`/`.zshrc` |
| `--no-deps` | Skip `bun install` |
| `--bun PATH` | Bun executable to use |

Environment: `OMP_DIR`, `OMP_SUBSCRIPTION_USAGE_HOME`, `BIN_DIR`, `OMP_TAG`,
`OMP_SUB_REF`, `BUN`.

## Add it to OMP

The policy is opt-in per profile. The installer normally does this for you; to
do it manually:

```bash
# Default profile
cp ~/.local/share/omp-subscription-usage/subscription-usage.example.yml \
   ~/.omp/agent/subscription-usage.yml

# Named profile
cp ~/.local/share/omp-subscription-usage/subscription-usage.example.yml \
   ~/.omp/profiles/codex/agent/subscription-usage.yml
```

Launch the patched runtime:

```bash
omp-subscription-usage
# or
omp-subscription-usage --profile codex
```

Inside the session:

```text
/subscription-usage
```

The command prints the resolved config path, live per-credential meters,
admission state, running/waiting counts, and `Restart OMP after editing`.
Delete the YAML (or leave `providers: {}`) to disable enforcement.

If you accepted `--alias` (or the interactive prompt), new shells can simply run
`omp`; it is a shell function pointing at the launcher, not a replacement of the
installed binary. To undo, remove the `>>> omp-subscription-usage >>>` block from
your shell rc file.

### Isolated test profile

```bash
SMOKE="$HOME/.omp-subscription-usage-smoke"
mkdir -p "$SMOKE/profiles/smoke/agent"
cp ~/.local/share/omp-subscription-usage/subscription-usage.example.yml \
   "$SMOKE/profiles/smoke/agent/subscription-usage.yml"
# OMP resolves PI_CONFIG_DIR relative to $HOME.
PI_CONFIG_DIR=.omp-subscription-usage-smoke OMP_SKIP_SETUP=1 \
  omp-subscription-usage --profile smoke --offline
```

## Configure

File: `<profile-agent-dir>/subscription-usage.yml`

```yaml
version: 1
providers:
  openai-codex:
    maxInFlight: 4
    maxWait: 5m
    windows:
      5h:
        mode: linear          # linear | step | smooth
        points:               # [time remaining, hard % used, soft % used]
          - [5h, 20, 10]
          - [1h, 80, 65]
          - [0h, 95, 85]
      7d:
        mode: smooth
        points:
          - [7d, 20, 15]
          - [3d, 55, 45]
          - [1d, 90, 75]
          - [0h, 97, 90]
    accounts: {}
```

| Key | Rule |
| --- | --- |
| `version` | exactly `1` |
| `providers` | missing/empty disables enforcement; unlisted providers keep native behavior |
| `maxInFlight` | positive safe integer; background-only ceiling |
| `maxWait` | `^(0\|[1-9][0-9]*)(m\|h\|d)$`; default `5m`; max `7d`; `0m` refuses after one bounded native resolution |
| `windows.5h` / `windows.7d` | both required |
| `mode` | `linear`, `step`, or `smooth` |
| `points` | ≥2 points, `[duration, hard, soft?]`; strictly descending unique durations; first exactly `5h`/`7d`; last `0h`; hard/soft nondecreasing and `0..100`; soft present on all points or none; soft ≤ hard |
| `accounts` | optional `"credential:<row-id>"` → partial `windows` override; a whole window is replaced, the other is inherited |

Percentages are **percent of the whole window already consumed**. The x-axis is
time remaining until the provider-reported reset. At knots the point's exact
value applies; between knots `linear` interpolates, `step` holds the earlier
point, and `smooth` uses `t²(3−2t)`.

Examples from the test suite: weekly linear `[7d,20],[1d,90],[0h,97]` yields
`20` at 7d, `55` at 4d, `90` at 1d; `step` yields `20` at 4d; `smooth` yields
`30.9375` at 5d12h.

### Admission semantics

- Candidates need one valid meter of each policy duration with a future reset.
- Observations are per-credential **raw probes**, fresh for 375 s. Merged
  response-header telemetry never extends policy freshness.
- Headroom is `min(hard - used%)` across every applicable meter; soft status is
  `used% < soft` on every meter (equality is soft fallback).
- Each quota pool contributes `ceil(maxInFlight × headroom/100)` slots, once,
  using its smallest row capacity. The provider ceiling is
  `min(maxInFlight, sum(pool slots))`. A request needs both the provider and its
  pool below their ceilings.
- Selection: under-soft first, then higher hard headroom, higher actual
  remaining quota, then native candidate order. Soft-cap candidates dispatch
  only when no under-soft candidate has a free slot.
- Hard caps, exhausted meters, cooldowns and stale/unsupported observations
  block or park the request. `maxWait` bounds the wait; the task deadline and
  abort signal always win.
- Explicit session pins are honored; local policy never routes a pinned account
  to a sibling.
- Only task-subagent inference (nested and worker-homed) is governed.
  Interactive chat, side turns and static provider concurrency limits are
  unchanged.

## Verify

From the patched checkout:

```bash
export PATH="$HOME/.local/share/omp-subscription-usage/.bun/bin:$PATH"  # if fetched
cd ~/.local/share/omp-subscription-usage/oh-my-pi
bun test packages/ai/test/provider-attempt-admission.test.ts \
  packages/ai/test/subscription-usage-auth.test.ts \
  packages/ai/test/auth-storage-session-restriction.test.ts \
  packages/ai/test/provider-inflight.test.ts \
  packages/coding-agent/test/subscription-usage.test.ts \
  packages/coding-agent/test/subscription-usage-controller.test.ts \
  packages/coding-agent/test/subscription-usage-wiring.test.ts \
  packages/coding-agent/test/issue-985-subagent-auth-fallback.test.ts
```

Typecheck:

```bash
(cd packages/ai && bun check --no-script -p tsconfig.json)
(cd packages/coding-agent && bun check --no-script -p tsconfig.json)
```

Status smoke in an RPC host (no model call):

```bash
printf '%s\n' '{"id":"1","type":"prompt","message":"/subscription-usage"}' |
  ANTHROPIC_API_KEY=dummy omp-subscription-usage --mode=rpc --no-tools \
  --model anthropic/claude-sonnet-4-5
```

## What the patch changes

- `packages/ai`: raw per-credential usage snapshots, native candidate listing,
  `preferredCredentialId` pinning, typed `SubscriptionUsagePolicyError`, and a
  `ProviderAttemptAdmission` lease released by the streaming attempt loop.
- `packages/coding-agent`: `subscription-usage.yml` parser/curves, admission
  controller (hard/soft caps, pool capacity, waiting, status), subagent
  resolver wiring, a worker thread service for shared counters, and
  `/subscription-usage`.

Deliberate boundary: the lease is reserved in the native key resolver immediately
before dispatch. Provider-specific static transport waits do not re-admit; a
genuine provider failure uses the unmodified native refresh/rotation path, and
the next attempt is not pinned to the failed row.

## Uninstall

```bash
rm ~/.local/bin/omp-subscription-usage
rm -rf ~/.local/share/omp-subscription-usage
rm ~/.omp/agent/subscription-usage.yml   # or the named-profile copy
```

## License

MIT. The patch is derivative of
[`can1357/oh-my-pi`](https://github.com/can1357/oh-my-pi); see `LICENSE` and
`NOTICE`.
