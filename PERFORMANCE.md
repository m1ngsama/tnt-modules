# TNT Module Performance

This is the executable contract for
[Issue #7](https://github.com/m1ngsama/tnt-modules/issues/7). It measures real
external module processes; TNT core scheduling is a separate system boundary.

The target is eight enabled modules sharing a 1-vCPU, no-swap host with TNT at
1,000 source events per minute. The host may have 128 MiB RAM, but that is not
an allowance for the module set.

## Budgets

| Metric | Ideal | Regression redline |
| --- | ---: | ---: |
| Single-module startup p95 | 50 ms | 150 ms |
| Event p95 / p99 | 20 / 50 ms | 50 / 100 ms |
| Single-module idle RSS | 4 MiB | 8 MiB |
| Eight-slot total idle RSS | 24 MiB | 32 MiB |
| Idle CPU | ~0% | 0.2% per module |
| Output per event | 8 KiB | 32 KiB |
| 1/4/8-slot load | 1,000 events/min | any drop or response over 100 ms |

The memory redlines are deliberately below the original triage estimates. Five
shell modules reused across eight slots measured about 16 MiB total and roughly
2 MiB per slot on the reviewed Apple M4 run. A 32 MiB aggregate redline leaves
100% headroom without making a fivefold regression look acceptable.

TNT's transport independently limits a JSONL payload to 4,094 bytes and an
event to eight response records, so its effective maximum is 32,760 bytes
including newlines.

## Commands

The benchmark uses only Python 3.10+ standard-library modules and local POSIX
tools. It needs no credentials or network access.

```sh
make perf           # startup/event information
make perf-load      # 1/4/8-slot fixed-rate load
make perf-resources # eight-slot idle RSS and CPU
make perf-check     # enforce selected profiles
```

One complete enforced run is:

```sh
make perf-check PERF_ARGS="--load --idle-resources --idle-seconds 10"
```

Add `--json-output /tmp/module-performance.json` only when a report will be
reviewed. `scripts/check_modules.sh --performance [MODULE_DIR ...]` first
validates every selected manifest/handshake, then invokes the same full profile
once. The checker does not maintain a second implementation.

## Cost policy

- Push and pull-request CI runs correctness and compatibility only.
- Performance runs only through the manual Linux workflow or a maintainer's
  local command; there is no schedule and no duplicate macOS hosted run.
- Successful manual runs upload nothing by default. A failure or explicit
  retention request keeps one compact JSON artifact for three days.
- Production TNT is not a continuous benchmark target.

## Measurement contract

Each bundled module declares a real command workload in its manifest. A
repository workload must produce a valid `message.create` before `event.ok`, so
a fast no-op cannot masquerade as business-command performance.

- Startup uses five independent launches by default and ends after a valid
  `handshake.ok`.
- Event latency uses a persistent process, at least five untimed warmups and 20
  timed events. It ends only after the complete sequence reaches `event.ok`.
- JSONL, UTF-8, identity, framing, action expectation, record count and output
  size remain correctness conditions.
- Fixed-rate load broadcasts one source event to 1, 4 and 8 slots. Each slot
  has one in-flight and one pending event; further work is counted as dropped
  rather than accumulated. Zero drops and complete fan-out are required.
- Idle measurement starts eight slots, includes helper processes in each
  process group, samples RSS/CPU/process count, rejects unsolicited output and
  fails if a leader exits.

The JSON schema records commit/dirty state, OS, Python, CPU, configuration,
budgets, transport limits, sample summaries, assignments, throughput, drops,
deadline misses, resources, failures and overall pass state. Compare only
equivalent hosts and workloads.

## Reviewed baseline

On 2026-08-13, clean commit
`ddba30b1c53d36b18b853f79cc8ddf6c6ef2c94d` on Apple M4 / Darwin 24.6 /
Python 3.14.6 passed the complete profile:

- per-slot idle RSS: about 1,984–2,080 KiB;
- eight-slot aggregate RSS: about 16 MiB;
- sampled idle CPU: 0.0%;
- all 100/400/800 load deliveries completed at 1,000 source events/minute with
  no drops;
- eight-slot source fan-out p95/p99 stayed below 31/41 ms.

These are environment-specific measurements, not permanent promises.

## Boundary

This repository proves module-process behavior. TNT core owns supervision,
timeouts, module-to-module isolation and end-to-end SSH integration. A pass
here must not be presented as proof of core scheduler isolation; TNT's own
module runtime and integration tests cover that boundary.
