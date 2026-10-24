# worker:local model benchmarks

Speed and memory of the servers `velo-local use` can pick, on one fixed prompt,
so a candidate model or runtime is judged on numbers that can be re-taken and
compared. Raw lines in [`results/`](results/), one file per model per day.

## How to run one

```bash
# no worker:local run in progress (velo-status); stop the other servers first —
# two large models do not fit in 128 GB at once
velo-llm-bench http://127.0.0.1:8092/v1 beamster/Qwen3.8-Flash-Next-Sushi-4bpw sushi-4bpw \
  --extra '{"top_k":20}' --note "<runtime version, flags, resident GB>" \
  >> .agents/bench/local-models/results/$(date -u +%F)-sushi-4bpw.jsonl
```

Per run: a short prompt (one sentence), then the long prompt. Run 0 is cold; later
runs differ only in the last line, so they measure a **warm turn** — the cost an
agent pays on every turn of one conversation. Report the **median** of runs ≥ 1
for warm numbers and run 0 for cold.

Resident memory is not measured by the script: read it from the server's own log
or `ps -o rss` while the long prompt runs, and put it in `--note`.

## What makes it repeatable

- **The prompt is pinned to a commit** (`--prompt-commit`, default `59938664e`):
  every `.rs` file under `src/velostream/sql/execution` in path order until
  160,000 chars, read through `git show`, never from a working tree. 39,273
  tokens in the Qwen3.8 tokenizer; `velo-llm-bench --prompt-only x x x | shasum
  -a 256` is `5fd2bbf3…91f2f`. The first version read the live checkout: master
  moved between two benches, the prompt went from 53,135 to 39,273 tokens, and
  results looked comparable that were not. **Only compare lines with the same
  `prompt_commit` and `machine`.** Moving the pin means re-taking every baseline.
- **Same sampling everywhere**: temperature 1.0, top-p 0.95 (the worker's own
  values), `--extra '{"top_k":20}'`, max 1,024 output tokens.
- **A fixed seed (0) is sent, but is not honoured by every server.** Sushi 1.2.1
  ignores it (two seeded requests, different text). With speculative decoding
  the decode rate depends on what is generated, so expect a few tok/s of spread
  between runs; that is why there are three and the median is reported.
- Every line records `date`, `machine`, `prompt_commit` and `seed`.

## Results — Apple M4 Max 128 GB

### Pinned prompt `59938664e` (39,273 tokens)

| | cold read | read speed | write @39K | write, short | warm turn | resident |
|---|---|---|---|---|---|---|
| **Sushi 1.2.1, EXL3 4bpw** (worker:local) | 53.2 s | 739 tok/s | 67–72 tok/s | 73–75 tok/s | 0.6 s | 59–64 GB |
| oMLX 0.7.1.dev1, oQ6e-mtp 6-bit | 51.4 s | 765 tok/s | 46–47 tok/s | 50–52 tok/s | 3.5 s | 97 GB |

### Older prompt (live checkout at `e281bc4b9`, 53,135 tokens; not comparable with the above)

| | cold read | read speed | write @53K | write, short | warm turn | resident |
|---|---|---|---|---|---|---|
| Sushi 1.2.1, EXL3 4bpw | 72.4 s | 734 tok/s | 64–69 tok/s | 71 tok/s | 0.65 s | 64 GB |
| llama-server (unsloth fork), UD-Q3_K_XL GGUF | 117.4 s | 453 tok/s | 35 tok/s | 49–51 tok/s | 5.2 s | 84 GB |

llama-server has not been re-run on the pinned prompt.

## Verdicts

- **Sushi 4bpw is worker:local** (2026-10-10, on trial). Fastest measured, least memory.
- **oMLX 6-bit: not adopted** (2026-10-11). The write-speed gap to Sushi is the
  bits (6 against 4 per weight), not the runtime — this compared quantisations,
  not runtimes. The blocker is memory: 97 GB resident leaves ~2% of RAM free, so
  no room for a worker's cargo builds or a long context, and oMLX's default
  memory guard (`balanced`) refused the 39K prompt outright (98.33 GB needed,
  98.13 GB allowed); it ran only with `--memory-guard aggressive`. Answer quality
  was not tested.
- **oMLX 4-bit: not measured.** By the publisher's ratios below it would write at
  roughly 52–70 tok/s here, against Sushi's 67–72. Not pursued.

## Against public numbers

- omlx.ai community, M4 Max 128 GB, oQ6e-mtp at 64K: 808 tok/s read, 47 tok/s
  write. Ours at 39K: 765 / 46–47 — **matches**.
- The pack's publisher (`results/publisher-omlx-oq4e-oq6e-oq8e-m3ultra.json`,
  shipped in the model repo as `bench-compare.json`) measured on an **M3 Ultra**
  (819 GB/s, against this M4 Max's 546), thinking off, temperature 0:

  | write tok/s | short code | 4K | 8K | 16K |
  |---|---|---|---|---|
  | oq4e | 64.4 | 56.5 | 56.3 | 52.9 |
  | oq6e | 56.1 | 44.9 | 44.8 | 48.3 |
  | oq8e | 42.1 | 41.9 | 43.7 | 47.5 |

  4-bit is only 1.1–1.25× 6-bit there. That ratio is from a different machine
  and may not hold on the M4 Max, which has less bandwidth.
