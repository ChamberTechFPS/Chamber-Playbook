# Benchmarking Chamber Playbook

How to measure whether a tweak actually does anything. Written after an
investigation that spent three sessions chasing a ~4.5% "regression" that turned
out to be a game update landing two days after the baseline was recorded.

The rules below exist because each one was learned the expensive way.

---

## Rule 1 — Pin versions on every row

A benchmark row is only comparable to another row with the **same three
versions**. Record all of them, every time:

| Field | How to get it |
| --- | --- |
| Windows build + UBR | `winver`, or `[System.Environment]::OSVersion.Version` |
| GPU driver version | NVIDIA Control Panel → System Information, or GPU-Z |
| Game build / season | In-game version string or launcher |

If any of the three differ between two rows, **the rows are not comparable**.
Delete the stale row; do not reason about the delta.

A seasonal game patch can move GPU-side throughput by 4-5% on its own. That is
larger than nearly every effect this playbook is capable of producing.

## Rule 2 — Keep a restorable stock image

Reinstalling Windows to re-baseline takes hours, which is why baselines go stale
and get reused past their expiry date.

Keep two disk images (Macrium Reflect, Clonezilla, or a spare NVMe):

- **stock** — clean Windows, drivers installed, no playbook
- **playbook** — the frozen build under test

Restoring an image takes minutes, which makes same-day A/B on identical versions
the default rather than a luxury. This single practice would have prevented the
entire investigation this document came from.

## Rule 3 — Test where the CPU is the limiter

The playbook changes scheduling, services, and background load. **None of that
can help when the GPU is the bottleneck.** That is physics, not a defect.

- **Primary test: 1080p, low settings.** CPU-bound, and also where the target
  audience actually plays.
- **4K is for regression checking only** — confirming the playbook does *not*
  make things worse. Do not look for gains there.

Measured example: at 4K the CPU had ~170 FPS of unused headroom (474 CPU FPS
against 293 actual). A 6% CPU improvement was completely invisible, because none
of it could be spent.

## Rule 4 — Three runs, discard the first, compare lows

- **3 runs minimum** per configuration.
- **Discard the first run** — shader caches and asset streaming need warming.
- **1% and 0.1% lows are the metric.** Averages hid every real signal in the
  CoD investigation; the lows showed all of them.
- **Reboot between configuration changes.**
- Alternate stock/playbook within one session so ambient temperature and
  background state drift affect both.

Deltas under ~2% on a single run are noise. Do not act on them.

## Rule 5 — Batch tests you expect to fail

One-variable-at-a-time is right when you expect a hit. When working through a
list of low-probability suspects, **revert them all at once**:

- All negative → the whole surface is eliminated in one run.
- Positive → bisect within the batch, 2 more runs worst case.

Four suspects tested individually is four reboots and four benchmark runs to
learn nothing. Batched, it is one.

## Rule 6 — Know what a registry flip cannot undo

Reverting registry values on an installed playbook only tests part of it.
Phases 3 (services), 5 (privacy), 6 (debloat), 7 (security), and 8 (UI) **cannot
be reverted this way** — disabled services and removed AppX packages stay gone.

To cover those, bisect *forward* from a clean install using the phase structure:
stock → phases 1-2 → 1-5 → 1-10, measuring at each step. Three rounds narrows a
regression to a phase.

---

## Standard suite

| Benchmark | Settings | Role |
| --- | --- | --- |
| **3DMark Steel Nomad** | default | **Control.** Pure GPU, no CPU path — expect 0% |
| **3DMark CPU Profile** | 1-thread + max-thread | Cleanest CPU measurement available; no renderer involved |
| **CS2** | 1080p low, competitive | Strongest signal — heavily CPU-bound |
| **Fortnite** | 1080p low, Performance mode | Secondary CPU-bound case |
| **CoD** | 1080p low | Reports CPU FPS and GPU FPS separately, which is useful for attribution |

Notes:

- Use the standard CS2 workshop FPS benchmark map so runs are identical.
- Fortnite has no built-in benchmark — use replay playback of one fixed replay
  with a scripted camera path, and never mix Performance mode with DX12.
- **Steel Nomad is a canary, not a target.** Nothing in the playbook should touch
  pure GPU throughput. If it shows any delta, stop benchmarking and find out why
  before trusting any other number.

## Decide before you run

Write down what each outcome means *before* collecting data, so a 1% result does
not get rationalized into a win afterward.

| Result | Conclusion |
| --- | --- |
| Steel Nomad ≈ 0% | Expected — GPU state is clean, results trustworthy |
| Steel Nomad > 1-2% delta | **Stop.** Environmental problem, not a playbook effect |
| CPU Profile up | Real CPU-side win |
| CS2 1% lows up | The core claim, in the title most likely to show it |
| CS2 flat or down | The playbook is not helping where it should — cut aggressively |

## The standard for shipping a tweak

**Any tweak that cannot demonstrate a measurable win gets cut, or made opt-in
with an honest description.**

Popularity in other playbooks is not evidence. `useplatformtick` and
`disabledynamictick` shipped in Chamber for four releases because every popular
playbook had them; both were removed in v1.2.2 as known regressions on modern
hardware. Copying the consensus imports the consensus's bugs.

Chamber has infrastructure no other playbook has — `verification-manifest.json`
is generated from the playbook source, so verification can never drift from what
the playbook actually does. Extending that into "every tweak carries evidence" is
a stronger position than having the largest tweak count.

## Honest expectations

On current high-end hardware with a clean Windows install and current drivers,
realistic headroom from OS-level tweaks is roughly **0-3%, almost entirely in 1%
lows**. The defensible pitch is debloat, privacy, consistent setup, time saved —
and *provably not slower than stock*, with real gains where the CPU is the
limiter.

Marketing on FPS gains means chasing noise, which means shipping harmful tweaks
to justify the claim.

One more caveat: a single test machine is n=1. A tweak that helps a 4-core laptop
can hurt an X3D. Prefer gating by hardware over applying blindly.
