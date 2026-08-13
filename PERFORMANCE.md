# TNT Module Performance

This document records the performance charter implemented for
[Issue #7](https://github.com/m1ngsama/tnt-modules/issues/7). The repository
benchmark enforces startup and event latency, stdout volume, idle resources,
and bounded 1/4/8-slot load. TNT core scheduling remains a separate system
boundary, described explicitly below.

## Target environment

The long-term target is a host where TNT and its modules share:

- 1 vCPU
- 128 MiB RAM
- 8 enabled modules
- 1,000 events per minute

Modules should remain idle when there is no work. Queues, retries, output, and
concurrency must stay bounded, and optimization must not weaken correctness,
security, privacy, accessibility, or maintainability.

## Budgets

The ideal targets describe where the project wants normal operation to remain.
The regression redlines are the maximum tolerated values; crossing one needs a
measurement, an explanation, and a recovery plan. Rows marked "enforced" are
checked by the corresponding profile; the CI invocation enables both the quick
latency/output profile and the optional load and idle-resource profiles.

| Metric | Ideal target | Regression redline | Current automation |
| --- | ---: | ---: | --- |
| Single-module startup p95 | ≤ 50 ms | > 150 ms | Enforced |
| Single-event response p95 / p99 | ≤ 20 / 50 ms | > 50 / 100 ms | Enforced |
| Single-module idle RSS | ≤ 8 MiB | > 16 MiB | CI resource gate |
| Eight-module total idle RSS | ≤ 48 MiB | > 80 MiB | CI: 8 slots |
| CPU with no events | ~0% | > 0.2% per module | CI resource gate |
| Stdout per event | ≤ 8 KiB | > 32 KiB | Enforced |
| 1/4/8 load | 1,000 events/min | Drops or >100 ms | CI gate |
| Fault isolation | ≤ 3 invalid | Core impact | Driver tests; core-owned |

The automated limits are therefore startup p95 ≤ 150 ms, event p95 ≤ 50 ms,
event p99 ≤ 100 ms, maximum event stdout ≤ 32,768 bytes, per-slot peak idle RSS
≤ 16,384 KiB, exact-eight-slot peak idle RSS ≤ 81,920 KiB, and per-slot idle
CPU ≤ 0.2% of one core. Resource limits are applied when `--idle-resources` is
enabled. The `--load` profile additionally requires zero drops, complete
fan-out, p95/p99 within the 50/100-ms event limits, and zero source responses
past 100 ms. CI enables both optional profiles. The ideal values are not
relaxed merely because automation gates the redlines.

The 32,768-byte stdout value is the policy redline recorded in Issue #7. TNT's
transport is slightly stricter: each of at most eight response records has a
4,094-byte JSON payload plus its newline, so the largest transport-valid event
is 8 × 4,095 = 32,760 bytes. The transport checks therefore contain the policy
budget before a 32,768-byte event could be observed; reports expose both values
instead of presenting the policy value as an independently reachable limit.

## Running the benchmark

The benchmark uses the Python 3.10+ standard library and starts the modules as
real external processes. No production credentials or network access are
needed.

Run an informational report:

```sh
make perf
```

The default remains the quick startup/event profile. Run the informational
load or eight-slot idle resource profiles separately:

```sh
make perf-load
make perf-resources
```

Enforce the current redlines and return non-zero on a regression:

```sh
make perf-check
```

The repository checker also exposes an opt-in complete profile:

```sh
scripts/check_modules.sh --performance [MODULE_DIR ...]
```

Its default behavior remains the quick manifest/handshake validation. With
`--performance`, it finishes those checks for every selected directory first,
then invokes `scripts/benchmark_modules.py` exactly once with `--check`,
`--idle-resources`, `--load`, and each checked directory as an explicit
`--module-dir`. This keeps every budget and measurement rule in the shared
benchmark. It also works after static checks delegated through `--checker` or
`TNT_MODULE_CHECKER`; `TNT_MODULES_PYTHON` selects Python, while
`TNT_MODULES_BENCHMARK` can substitute the benchmark harness for testing.

`make perf-check` alone keeps the same quick latency/output gate. Include load
and idle resources when a local run should match CI's enforced scope:

```sh
make perf-check PERF_ARGS="--load --idle-resources --idle-seconds 10"
```

Write the same enforced run as a structured JSON report:

```sh
make perf-check PERF_ARGS="--load --idle-resources \
  --json-output module-performance.json"
```

Arguments can be passed through `PERF_ARGS`. For example:

```sh
make perf PERF_ARGS="--startup-samples 20 --warmups 10 --samples 100"
```

Idle resource topology and sampling are also configurable:

```sh
make perf-resources PERF_ARGS="--idle-instances 8 --idle-settle 0.5 \
  --idle-seconds 10 --resource-sample-interval 0.25"
```

The fixed-rate profile is configurable independently:

```sh
make perf-load PERF_ARGS="--load-topologies 1,4,8 \
  --load-events-per-minute 1000 --load-seconds 6"
```

Run `python3 scripts/benchmark_modules.py --help` for the full interface. Use
repeatable `--module-dir PATH` arguments to select explicit module directories.
Without them, the benchmark discovers the reusable modules under `modules/`.
Every auto-discovered repository module must provide a non-empty benchmark
workload and explicitly set `expect_message_create` to `true`. An explicitly
selected external module may omit `benchmark` or omit/set that flag to `false`;
in that case the harness permits a generic or explicitly configured no-op event
and does not require `message.create`. Add the strict metadata when the intent
is to measure a real action path.

## Workloads and measurement method

Each bundled module declares a real command workload in its `benchmark`
manifest object:

```json
"benchmark": {
  "plain_text": "/flip",
  "expect_message_create": true
}
```

For auto-discovered repository modules, a missing flag or a value of `false` is
a configuration error. The benchmark requires a valid `message.create` before
the terminating `event.ok`, preventing a fast no-op from masquerading as the
command handler.

The current command corpus is:

| Module | Timed event text |
| --- | --- |
| `8ball-module` | `/8ball will this benchmark pass?` |
| `choose-module` | `/choose alpha \| beta \| gamma` |
| `flip-module` | `/flip` |
| `quote-module` | `/quote` |
| `roll-module` | `/roll 2d6` |

Measurements use `time.perf_counter()` and nearest-rank percentiles:

1. Startup is measured with five independent process launches by default. A
   sample starts before process creation and ends after a valid `handshake.ok`.
   This is a cold process start, but the benchmark does not flush the OS page
   cache.
2. Event latency uses one persistent process per module. After its handshake,
   the harness sends at least five untimed warmup events, then 20 timed events
   by default.
3. Each timed event begins before the JSONL request write and ends only after
   the complete response sequence reaches `event.ok`. The report records p50,
   p95, and p99 latency.
4. Stdout bytes include every response record and its newline. Startup and
   event summaries record total, minimum, maximum, and mean bytes; the event
   redline is applied to the maximum sampled event.
5. The harness also validates UTF-8 JSON objects, the handshake identity,
   `message.create` plain text, `event.ok` framing, TNT's 4,094-byte JSONL
   payload limit, and the eight-response-per-event limit.

Startup and event summaries deliberately separate shell/process launch plus
handshake time from persistent-process command handling time. This is the
requested startup/business-command split; it does not pretend to microprofile
individual awk/parser functions inside one command.

The optional fixed-rate load profile fans one source stream out concurrently
to 1, 4, and 8 module slots. It offers 1,000 source events per minute for six
seconds per topology by default, after five action-path warmups per slot. The
fixed corpus contains one real command for each distinct module assigned to the
topology. Every source arrival selects the next corpus command and broadcasts
that exact JSONL event to every slot: its target module must create a message,
while the other bundled modules must return only `event.ok`. This models TNT's
single-event broadcast semantics instead of the impossible case where one
source event becomes a different slash command for every module.

Each process has at most one in-flight event and one pending event in its driver
queue. A further arrival while that bounded slot is full is counted as dropped
instead of accumulating memory. The single waiting position absorbs one
within-budget 60–100-ms jitter at the 60-ms arrival interval, while sustained
overload still fails through drops or the 100-ms source deadline. The report
includes assignments, the exact per-topology corpus, offered/completed source
events, deliveries and action events, drops, throughput, queue depth, deadline
misses, and per-slot plus fan-out p50/p95/p99 latency. Repository modules are
reused round-robin when a topology has more slots than distinct selected
modules. Regression fixtures also verify that a persistently slow slot exhausts
only its own bounded queue while a healthy peer completes the full offered
stream.

The optional idle resource profile starts the requested number of module slots
at the same time, handshakes each one, lets them settle, and then samples every
process in each module's private process group. Eight slots are used by default.
When fewer distinct modules are selected, the sorted module list is reused in
round-robin order; report assignments explicitly mark each reused slot instead
of presenting it as a distinct module.

Linux reads process group, RSS, state, and user/system CPU time from `/proc`;
macOS uses the system `ps` fields for the same values. A slot's RSS is the sum
of all processes in its group, so helper processes are included. This
conservative sum can count shared resident pages once per process. Reports keep
the interval minimum, mean, and peak RSS, cumulative CPU seconds, CPU as a
percentage of one core over the measured wall-clock interval, and peak process
count. The 80-MiB aggregate gate applies only when exactly eight slots were
measured; the per-slot RSS and CPU gates apply to every measured topology.

Sampling also rejects unsolicited stdout and an exited module leader while
idle. A helper that is created and exits wholly between two samples can evade
RSS/process-count observation, and CPU time at the end of such a short-lived
process can be undercounted. Helpers that deliberately leave the module's
process group are outside this profile. These limits are why the default CI
window is ten seconds rather than the short windows used by regression tests.
Every bundled entrypoint blocks on stdin while idle rather than polling or
running a timer; the CPU gate makes that property regression-visible.

The JSON report has `schema_version` 1. It records the generation time, commit,
dirty-worktree state, OS, Python runtime, CPU identity and logical CPU count;
the sample, timeout, load, and idle-resource configuration; enforced `budgets`;
the independent `transport_limits`; each module's version, directory, workload,
latency and stdout summaries; `idle_resources`; `load`; failures; an `error`
value; and overall pass status. Optional profile status is `not_requested`,
`measured`, or `error`. A load result also records available workloads, each
topology's exact source corpus, and offered/completed action-event counts. A
measured result contains its backend/topology, assignments, duration, per-slot
summaries, aggregate summaries, failures, and pass status. On a normal run,
`error` is `null`. If a benchmark, protocol, or resource backend error
interrupts the run, the requested JSON report still retains completed results,
records the error, sets the requested profile and overall pass to false, and
returns status 2 rather than silently passing an unavailable metric.

In schema v1, `transport_limits` records a 4,094-byte JSONL payload, eight event
response records, and 32,760 event-output bytes including newlines. These are
hard framing limits, distinct from the 32,768-byte policy value in `budgets`.
Compare results from equivalent hosts and runner images—timings from different
hardware are not directly interchangeable.

## Local reference baseline

The following default-configuration run was recorded on 2026-08-13 from the
in-progress working tree on an Apple M4, Darwin 24.6, and Python 3.14.6. It is a
local reference, not a cross-machine guarantee or a substitute for the CI JSON
artifacts.

| Module | Startup p95 (ms) | Event p95 (ms) | Event p99 (ms) |
| --- | ---: | ---: | ---: |
| `8ball-module` | 9.408 | 12.101 | 12.255 |
| `choose-module` | 7.687 | 11.743 | 12.281 |
| `flip-module` | 9.193 | 13.649 | 14.633 |
| `quote-module` | 8.839 | 10.888 | 12.338 |
| `roll-module` | 8.196 | 11.893 | 12.074 |

All five modules stayed below both the currently enforced redlines and the
20-ms ideal event p95 target on this reference host.

The same run offered 100 source events at each of the 1-, 4-, and 8-slot
topologies. It completed all 1,300 deliveries without a drop or deadline miss
at 1,000 source events/minute. Source fan-out p95/p99 was 26.488/30.842 ms,
29.253/34.924 ms, and 30.681/40.908 ms respectively.

A subsequent default ten-second resource run on the same host started eight
slots (the five modules followed by reused `8ball`, `choose`, and `flip` slots).
Every slot had one process, per-slot peak RSS ranged from 2,000 to 2,080 KiB,
aggregate peak RSS was 16,224 KiB, and sampled idle CPU was 0.0% for every slot.
This is a local reference; the retained macOS and Linux CI reports remain the
cross-platform evidence for each run.

## CI reports

GitHub Actions continues to run `make perf-check` directly after the test suite
instead of routing its artifact-producing run through checker `--performance`.
It runs on both
`ubuntu-24.04` and `macos-latest`. Each job writes `module-performance.json`
while enabling the 1/4/8-slot fixed-rate load and the eight-slot, ten-second
idle resource profile, and uploads it even when the budget step fails:

- `module-performance-ubuntu-24.04`
- `module-performance-macos-latest`

These artifacts are the current per-run baselines for regression comparison.
The hosted runners record their environment in the report, but they do not
emulate the 1-vCPU, 128-MiB target host.

## Current scope and known gaps

The repository-owned measurements and regression gates are automated.
Remaining system-level limits are explicit rather than silently treated as
passes. The current harness:

- does not measure scheduler wakeups independently from accumulated CPU time;
- does not exercise TNT core supervision or prove module-to-module fault
  isolation from slow, crashed, flooding, or invalid-output modules, although
  its regression corpus covers each failure at the module/driver boundary;
- does not microprofile parser overhead separately from command business logic;
- does not exhaustively cover every command variant or input size; and
- exposes resource and latency enforcement from `scripts/check_modules.sh`
  only as the explicit `--performance` profile; the checker delegates to the
  shared benchmark rather than implementing a second measurement or budget
  path.

In particular, a pass in this repository must not be reported as proof of TNT
core module-to-module fault isolation. The adjacent TNT 1.2 runtime currently
visits modules serially, can wait up to 100 ms for each module, and does not add
a silent timeout to the invalid-response disable count. A silent module can
therefore delay healthy modules later in that loop. Correcting and proving that
behavior requires a separate TNT core scheduling/supervision change and its own
integration tests; this resource slice does not change that conclusion.

Future TNT core work may change scheduling and add core fault-isolation tests.
That work must not replace these protocol/behavior/load tests or trade module
correctness for benchmark numbers.
