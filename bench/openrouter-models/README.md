# OpenRouter worker models — comparison, cost model, baseline

Which model each `worker:*` route should run, on evidence that can be re-taken. The local
(`worker:local`) models are measured separately in [`../local-models/`](../local-models/).

| file | what |
|---|---|
| [`baseline.py`](baseline.py) | per-model landed rate and billed cost from the dispatch records; `--endpoints <model>` prices that model's token mix on every provider |
| [`replay/`](replay/) | the replay scripts (`replay-launch.sh`, one `grade-<issue>.sh` per replayed ticket) |
| [`results/`](results/) | one JSONL per replayed ticket, one row per arm |

## Cost model

A run's bill is

    uncached_input x p_in  +  cache_reads x p_cache  +  output x p_out

Per-provider prices differ by 10x, and the provider is chosen by OpenRouter unless a route pins
one (`PROVIDER_ORDER` in `velo_sdk_patches.py` / `velo-openai-agents-runner.py`).

**The cache-read price is what matters.** Agent loops re-send the whole conversation every turn:
across the 370 recorded `deepseek/deepseek-v4.1-flash` runs (2026-09-18 to 2026-10-25, from
`baseline.py`) **96% of input tokens were cache reads** (5,020M cached vs 198M uncached; 28.9M output).
The list "input price" is therefore the wrong number to compare models or providers on.

Baseline, `deepseek/deepseek-v4.1-flash`, 370 runs: **79% landed** (292), billed **$0.257/run,
$0.232/landed run**; $27.18 of $94.99 (29%) went on runs that did not land. Median 125 turns, 28 min.
Re-take with `baseline.py --since 2026-09-18 --model deepseek`.

Provider spread, same token mix priced on each provider (**modelled, not measured** — token counts
differ between models and providers, and a provider switch can change the cache hit rate):
Baidu $22, DeepInfra $48, median $107, against $94 billed unpinned
(`baseline.py --endpoints deepseek/deepseek-v4.1-flash`). `v4.1-flash` is pinned Baidu, DeepInfra
(ordered, with fallbacks). **Not yet verified**: compare cached share and cost/run over the next
~50 runs.

`cost.usd` in a record is null unless OpenRouter billed it (see `.agents/README.md` section 6).

## Replay method

A model is judged on a ticket that already landed, against the answer that merged.

1. **Base** = the parent of the merged PR's merge commit (`git log --format=%p -1 <merge>`). A
   detached worktree there, one per arm. Replays call the runner directly because `velo-dispatch`
   always cuts from current `origin/master`.
2. **Brief** = the issue text and the standard rules, not the fix. Where the issue makes claims,
   the brief asks the model to prove which are reachable (see #2737).
3. **Same runner, caps and prompt for every arm**: `velo-openrouter-agent`, 250 turns, $1,
   `velo-impl.md`, the `/check-code` skill. No provider pin (default routing), so cost is what
   OpenRouter charged by default.
4. **Grade with the reference tests from the merged PR**, overlaid on the arm's tree (`replay/grade-*.sh`)
   — independent of the arm's own tests. First run the grader on the pristine base: it must FAIL
   (#2593: reference test red; #2737: 4 of 5 red, the fifth is a control that must keep passing).
5. Record outcome, turns, wall, billed USD, tokens, retries in `results/`.

Limits: one run per arm, two tickets. Costs are one sample, so a 3x gap can be noise.

## Results

### #2593 — shipped phase-4 example SQL refused at plan time (base `14286ddf4`, reference PR #2661)

| arm | reference test | turns | wall | billed |
|---|---|---|---|---|
| `deepseek/deepseek-v4.1-flash` | pass | 201 | 42.5 min | $0.068 |
| `deepseek/deepseek-v4.1-flash-1017` | pass | 101 | 22.5 min | $0.198 |
| `poolside/laguna-s-2.1:free` | pass | 195 | 39.6 min | $0 |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | pass | 140 | 40.8 min | $0 |
| `nvidia/nemotron-3.5-lightning:free` | **fail** (4 statements still refuse; reported success) | 206 | 43 min | $0 |
| `xiaomi/mimo-v2.6-flash` | **fail** (no example SQL changed; hit the $1 cap) | 216 | 51 min | $1.00 |
| `thinkingmachines/inkling:free` | not runnable (403: agentic-harness apps only) | 0 | — | $0 |

### #2737 — INSERT...WINDOW clock / SQL ALLOWED LATENESS wrapper (base `610003f33`, reference PR #2738)

| arm | reference tests (5) | turns | wall | billed |
|---|---|---|---|---|
| `deepseek/deepseek-v4.1-flash` | **5 / 5** | 246 | 35.6 min | $0.074 |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | incomplete (1 / 5 = the unfixed base) | 111 | 31.9 min | $0 |
| `poolside/laguna-s-2.1:free` | incomplete (1 / 5 = the unfixed base) | 173 | 32.2 min | $0 |

Both free arms were stopped by OpenRouter's free daily cap (below), not by a wrong answer; neither
reached the fix. Resume them after the cap resets to complete this table.

## Free tier

- **A provider hiccup used to end a run.** A 504 "Upstream idle timeout" arrives as a 200 with an
  error payload and no choices; a 429 "temporarily rate-limited upstream" is a plain 429. The
  runner now retries the single model call (`call_with_transient_retry`, `velo_runner_lib.py`):
  capped exponential backoff, honours `Retry-After`. Laguna absorbed 14 retries and finished #2593.
- **There is a daily cap: 1000 free-model requests per day per account**
  (`free-models-per-day-high-balance`, resets 00:00 UTC). A run makes roughly 100-250 requests, so
  the free tier is **about 5-8 runs a day, not unlimited**. A run that hits it dies with a 429 that
  no retry can cure.
- **Prompts may be logged by free providers.** The repo is private. Use free routes for scoped,
  low-risk work only.
- Some `:free` models refuse non-listed clients (403): `thinkingmachines/inkling:free`.
- A free model can report success while failing (`nemotron-3.5-lightning:free` on #2593). Grade by
  the reference tests, not by the final report.

## Current routing (as of 2026-10-25)

- `worker:deepseek` = `deepseek/deepseek-v4.1-flash`, pinned Baidu then DeepInfra. Cheapest model
  that passed both replays; `-1017` passed #2593 in half the turns at about 3x the cost and was not
  run on #2737; `mimo-v2.6-flash` failed.
- `worker:free` = `nvidia/nemotron-3-ultra-550b-a55b:free` (`VELO_FREE_MODEL` swaps it), escalating
  to `worker:deepseek`. Suitable for scoped low-risk tickets within the daily cap.
- `VELO_MODEL_OVERRIDE` runs any OpenRouter route on another model for one dispatch (A/B trials).

## Open

- Resume the two free #2737 arms after the cap resets and fill in the table.
- `worker:free` should fail fast and escalate when the daily cap is hit instead of retrying.
- Verify the Baidu/DeepInfra pin on real dispatches (cached share, cost/run).
- More tickets; one or two is not a baseline for a model's success rate.
