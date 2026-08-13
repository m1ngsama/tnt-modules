#!/usr/bin/env python3
"""Benchmark TNT module startup and steady-state JSONL event latency.

The benchmark intentionally uses only the Python standard library so the same
command can run in local development and on the repository's macOS/Linux CI
runners without installing dependencies.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import errno
import json
import math
import os
import pathlib
import platform
import selectors
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Sequence


PROTOCOL = "tnt.module.v1"
DEFAULT_SAMPLES = 20
DEFAULT_STARTUP_SAMPLES = 5
DEFAULT_WARMUPS = 5
DEFAULT_STARTUP_TIMEOUT_SECONDS = 2.0
DEFAULT_EVENT_TIMEOUT_SECONDS = 2.0
DEFAULT_IDLE_INSTANCES = 8
DEFAULT_IDLE_SETTLE_SECONDS = 0.5
DEFAULT_IDLE_SECONDS = 10.0
DEFAULT_RESOURCE_SAMPLE_INTERVAL_SECONDS = 0.25
PROCESS_STOP_GRACE_SECONDS = 0.25
PROCESS_KILL_WAIT_SECONDS = 1.0
PROCESS_GROUP_POLL_SECONDS = 0.01

STARTUP_P95_BUDGET_MS = 150.0
EVENT_P95_BUDGET_MS = 50.0
EVENT_P99_BUDGET_MS = 100.0
EVENT_OUTPUT_BUDGET_BYTES = 32_768
MODULE_IDLE_RSS_BUDGET_KIB = 16 * 1024
EIGHT_MODULE_IDLE_RSS_BUDGET_KIB = 80 * 1024
MODULE_IDLE_CPU_BUDGET_PERCENT = 0.2

# TNT core reads responses into a 4096-byte C buffer. Newline and NUL framing
# leave 4094 bytes for one JSON payload, and core accepts at most eight response
# records for one event.
MAX_JSONL_PAYLOAD_BYTES = 4_094
MAX_EVENT_RECORDS = 8
MAX_EVENT_OUTPUT_BYTES = MAX_EVENT_RECORDS * (MAX_JSONL_PAYLOAD_BYTES + 1)


class BenchmarkError(RuntimeError):
    """Raised when a module violates the benchmark transport or protocol."""


class BenchmarkInterrupted(BaseException):
    """Request orderly process-group cleanup after an external signal."""

    def __init__(self, signum: int) -> None:
        self.signum = signum
        super().__init__(signum)


@contextlib.contextmanager
def temporary_interrupt_signal_handlers() -> Any:
    """Turn process-control signals into an exception while work is active.

    Raising from Python's main-thread signal handler lets active context
    managers close every module process group.  After the first signal,
    subsequent signals are recorded but do not interrupt that cleanup.
    """

    interrupt_signals = tuple(
        signum
        for signal_name in ("SIGHUP", "SIGINT", "SIGTERM")
        if (signum := getattr(signal, signal_name, None)) is not None
    )
    previous_handlers: dict[int, Any] = {}
    caught_signal: int | None = None
    raised_signal = False
    active = True

    def handle_interrupt(signum: int, _frame: Any) -> None:
        nonlocal caught_signal, raised_signal
        if caught_signal is None:
            caught_signal = signum
        if active and not raised_signal:
            raised_signal = True
            raise BenchmarkInterrupted(signum)

    try:
        for signum in interrupt_signals:
            previous_handlers[signum] = signal.signal(signum, handle_interrupt)
        yield
    finally:
        # Do not let a second signal abort restoration or an in-progress
        # RunningModule.close(). If the first signal arrives during this tiny
        # restoration window, raise it after every original handler is back.
        active = False
        for signum, previous_handler in previous_handlers.items():
            signal.signal(signum, previous_handler)
        if caught_signal is not None and not raised_signal:
            raise BenchmarkInterrupted(caught_signal)


@dataclass(frozen=True)
class ModuleSpec:
    name: str
    version: str
    directory: pathlib.Path
    entrypoint: pathlib.Path
    workload_plain_text: str
    expect_message_create: bool


@dataclass(frozen=True)
class Measurement:
    latency_ms: float
    output_bytes: int


@dataclass(frozen=True)
class ProcessResourceSample:
    pid: int
    process_group_id: int
    rss_kib: int
    cpu_seconds: float
    state: str


@dataclass
class IdleResourceSlot:
    slot: int
    spec: ModuleSpec
    running: RunningModule
    process_group_id: int
    leader_pid: int
    rss_samples_kib: list[int] = field(default_factory=list)
    process_count_samples: list[int] = field(default_factory=list)
    cpu_baseline_seconds: dict[int, float] = field(default_factory=dict)
    cpu_latest_seconds: dict[int, float] = field(default_factory=dict)


def positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def idle_instance_count(value: str) -> int:
    parsed = positive_int(value)
    if parsed > 8:
        raise argparse.ArgumentTypeError("must be at most 8")
    return parsed


def warmup_count(value: str) -> int:
    parsed = positive_int(value)
    if parsed < 5:
        raise argparse.ArgumentTypeError("must be at least 5")
    return parsed


def positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def nonnegative_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def strict_json_object(raw: bytes, context: str) -> dict[str, Any]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise BenchmarkError(f"{context}: response was not UTF-8: {exc}") from exc

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON constant {value}")

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate object key {key!r}")
            value[key] = item
        return value

    try:
        value = json.loads(
            text,
            parse_constant=reject_constant,
            object_pairs_hook=reject_duplicate_keys,
        )
    except (json.JSONDecodeError, ValueError) as exc:
        raise BenchmarkError(f"{context}: response was not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise BenchmarkError(f"{context}: response must be a JSON object")
    return value


def validate_plain_text(
    plain_text: str,
    context: str,
    *,
    reject_controls: bool,
) -> None:
    try:
        size = len(plain_text.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise BenchmarkError(f"{context}: plain_text was not valid Unicode") from exc
    if size < 1 or size > 1_023:
        raise BenchmarkError(
            f"{context}: plain_text must be 1..1023 UTF-8 bytes, got {size}"
        )
    if reject_controls and any(
        ord(character) < 0x20 or ord(character) == 0x7F
        for character in plain_text
    ):
        raise BenchmarkError(f"{context}: plain_text contained a control character")


class RunningModule:
    """A module process with deadline-bound, unbuffered JSONL reads.

    This object owns process reaping; normal callers must let close() perform
    the first poll or wait so the private process-group ID cannot be reused
    before descendant cleanup begins.
    """

    def __init__(self, spec: ModuleSpec) -> None:
        self.spec = spec
        self.process: subprocess.Popen[bytes] | None = None
        self.process_group_id: int | None = None
        self.selector: selectors.BaseSelector | None = None
        self.buffer = bytearray()

    def __enter__(self) -> "RunningModule":
        try:
            self.process = subprocess.Popen(
                [str(self.spec.entrypoint)],
                cwd=str(self.spec.directory),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
                start_new_session=True,
            )
            assert self.process.stdout is not None
            # start_new_session makes the module the leader of a private process
            # group, so helpers it forks can be cleaned up with the same stable ID.
            self.process_group_id = self.process.pid
            self.selector = selectors.DefaultSelector()
            self.selector.register(self.process.stdout, selectors.EVENT_READ)
            return self
        except OSError as exc:
            self.close()
            raise BenchmarkError(
                f"{self.spec.name}: could not start {self.spec.entrypoint}: {exc}"
            ) from exc
        except BaseException:
            # A process-control signal can arrive after Popen succeeds but
            # before a surrounding with statement registers __exit__.
            self.close()
            raise

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.close()

    def close(self) -> None:
        process = self.process
        process_group_id = self.process_group_id
        if self.selector is not None:
            self.selector.close()
            self.selector = None
        if process is None:
            return

        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass

        # Signal the group before polling or waiting for its leader. Reaping an
        # already-exited leader can make its numeric PID reusable once the group
        # is empty. If descendants remain, POSIX keeps their process-group ID in
        # use; close() runs immediately while this RunningModule still owns the
        # Popen instance, keeping the remaining no-descendant reuse window as
        # narrow as possible.
        if process_group_id is not None:
            self._signal_process_group(process_group_id, signal.SIGTERM)

        grace_deadline = time.monotonic() + PROCESS_STOP_GRACE_SECONDS
        try:
            process.wait(timeout=PROCESS_STOP_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass

        # A leader can exit promptly while a helper ignores SIGTERM. Wait on
        # the group itself for the rest of the grace period, then force any
        # remaining descendants down. ESRCH means the owned group is gone;
        # EPERM is tolerated so cleanup cannot mask the benchmark result.
        if process_group_id is not None:
            while (
                self._process_group_exists(process_group_id)
                and time.monotonic() < grace_deadline
            ):
                time.sleep(
                    min(
                        PROCESS_GROUP_POLL_SECONDS,
                        max(0.0, grace_deadline - time.monotonic()),
                    )
                )

            if self._process_group_exists(process_group_id):
                self._signal_process_group(process_group_id, signal.SIGKILL)

            try:
                process.wait(timeout=PROCESS_KILL_WAIT_SECONDS)
            except subprocess.TimeoutExpired:
                # This should be unreachable after SIGKILL, but do not let
                # cleanup hang a benchmark runner indefinitely.
                pass
        if process.stdout is not None:
            try:
                process.stdout.close()
            except OSError:
                pass
        self.process = None
        self.process_group_id = None

    @staticmethod
    def _signal_process_group(process_group_id: int, signum: int) -> bool:
        try:
            os.killpg(process_group_id, signum)
            return True
        except OSError as exc:
            if exc.errno in {errno.ESRCH, errno.EPERM}:
                return False
            raise

    @staticmethod
    def _process_group_exists(process_group_id: int) -> bool:
        try:
            os.killpg(process_group_id, 0)
            return True
        except OSError as exc:
            if exc.errno == errno.ESRCH:
                return False
            if exc.errno == errno.EPERM:
                return True
            raise

    def assert_idle_stdout(self, context: str) -> None:
        """Reject output or EOF produced when no request is outstanding."""
        process = self.process
        selector = self.selector
        if process is None or process.stdout is None or selector is None:
            raise BenchmarkError(f"{context}: module process is not running")
        if self.buffer:
            raise BenchmarkError(f"{context}: module emitted unsolicited idle output")
        if not selector.select(0):
            return
        try:
            chunk = os.read(process.stdout.fileno(), 65_536)
        except OSError as exc:
            raise BenchmarkError(f"{context}: failed reading module stdout: {exc}") from exc
        if chunk:
            self.buffer.extend(chunk)
            raise BenchmarkError(f"{context}: module emitted unsolicited idle output")
        raise BenchmarkError(f"{context}: module closed stdout while idle")

    def write_json(self, value: dict[str, Any], context: str) -> None:
        process = self.process
        if process is None or process.stdin is None:
            raise BenchmarkError(f"{context}: module process is not running")
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        encoded = payload.encode("utf-8")
        if len(encoded) > MAX_JSONL_PAYLOAD_BYTES:
            raise BenchmarkError(
                f"{context}: request JSONL payload exceeded "
                f"{MAX_JSONL_PAYLOAD_BYTES} bytes"
            )
        try:
            process.stdin.write(encoded + b"\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            # Avoid reaping the process-group leader before close() has had a
            # chance to terminate any helpers that inherited its group.
            status = process.returncode
            suffix = f" (exit status {status})" if status is not None else ""
            raise BenchmarkError(f"{context}: module closed stdin{suffix}") from exc

    def read_line(self, deadline: float, context: str) -> bytes:
        process = self.process
        selector = self.selector
        if process is None or process.stdout is None or selector is None:
            raise BenchmarkError(f"{context}: module process is not running")

        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line = bytes(self.buffer[:newline])
                del self.buffer[: newline + 1]
                if not line:
                    raise BenchmarkError(f"{context}: module emitted an empty JSONL record")
                if len(line) > MAX_JSONL_PAYLOAD_BYTES:
                    raise BenchmarkError(
                        f"{context}: JSONL payload exceeded {MAX_JSONL_PAYLOAD_BYTES} bytes"
                    )
                return line

            if len(self.buffer) > MAX_JSONL_PAYLOAD_BYTES:
                raise BenchmarkError(
                    f"{context}: JSONL payload exceeded {MAX_JSONL_PAYLOAD_BYTES} bytes"
                )

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchmarkError(f"{context}: timed out waiting for a JSONL response")
            if not selector.select(remaining):
                raise BenchmarkError(f"{context}: timed out waiting for a JSONL response")

            try:
                chunk = os.read(process.stdout.fileno(), 65_536)
            except OSError as exc:
                raise BenchmarkError(f"{context}: failed reading module stdout: {exc}") from exc
            if not chunk:
                # See write_json(): close() owns process reaping and group
                # cleanup, so error reporting must not poll first.
                status = process.returncode
                suffix = f" with status {status}" if status is not None else ""
                if self.buffer:
                    raise BenchmarkError(
                        f"{context}: module exited{suffix} with an unterminated JSONL record"
                    )
                raise BenchmarkError(f"{context}: module exited{suffix} before responding")
            self.buffer.extend(chunk)


class LinuxProcResourceSampler:
    """Sample complete module process groups from Linux procfs."""

    backend_name = "linux-procfs"

    def __init__(self, proc_root: pathlib.Path = pathlib.Path("/proc")) -> None:
        if not proc_root.is_dir():
            raise BenchmarkError("idle resource sampling requires mounted Linux procfs")
        try:
            self.clock_ticks = int(os.sysconf("SC_CLK_TCK"))
        except (OSError, ValueError) as exc:
            raise BenchmarkError("could not determine Linux process clock ticks") from exc
        if self.clock_ticks <= 0:
            raise BenchmarkError("Linux process clock ticks must be positive")
        self.proc_root = proc_root

    def snapshot(
        self, process_group_ids: set[int]
    ) -> dict[int, list[ProcessResourceSample]]:
        groups = {process_group_id: [] for process_group_id in process_group_ids}
        try:
            process_directories = list(self.proc_root.iterdir())
        except OSError as exc:
            raise BenchmarkError(f"could not scan Linux procfs: {exc}") from exc

        for process_directory in process_directories:
            if not process_directory.name.isdigit():
                continue
            try:
                raw_stat = (process_directory / "stat").read_text(
                    encoding="utf-8", errors="replace"
                )
                command_end = raw_stat.rfind(")")
                if command_end < 0:
                    continue
                pid = int(raw_stat[: raw_stat.find(" ")])
                fields = raw_stat[command_end + 2 :].split()
                # fields starts at stat field 3 (state): pgrp is field 5,
                # while utime/stime are fields 14 and 15.
                state = fields[0]
                process_group_id = int(fields[2])
                if process_group_id not in groups:
                    continue
                cpu_seconds = (int(fields[11]) + int(fields[12])) / self.clock_ticks
                rss_kib = self._rss_kib(process_directory / "status")
            except (OSError, ValueError, IndexError):
                # Processes can disappear between the directory, stat, and
                # status reads. The next interval accounts for survivors.
                continue
            groups[process_group_id].append(
                ProcessResourceSample(
                    pid=pid,
                    process_group_id=process_group_id,
                    rss_kib=rss_kib,
                    cpu_seconds=cpu_seconds,
                    state=state,
                )
            )
        return groups

    @staticmethod
    def _rss_kib(status_path: pathlib.Path) -> int:
        for line in status_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("VmRSS:"):
                fields = line.split()
                return int(fields[1])
        return 0


def parse_ps_cpu_seconds(value: str) -> float:
    """Parse portable ps TIME values such as 00:01.23 or 1-02:03:04."""
    days = 0
    clock = value
    if "-" in clock:
        days_text, clock = clock.split("-", 1)
        days = int(days_text)
    components = clock.split(":")
    if len(components) == 2:
        hours = 0
        minutes_text, seconds_text = components
    elif len(components) == 3:
        hours_text, minutes_text, seconds_text = components
        hours = int(hours_text)
    else:
        raise ValueError(f"unrecognized ps TIME value: {value}")
    return (
        days * 86_400
        + hours * 3_600
        + int(minutes_text) * 60
        + float(seconds_text)
    )


class DarwinPsResourceSampler:
    """Sample complete module process groups with Darwin's system ps."""

    backend_name = "darwin-ps"

    def snapshot(
        self, process_group_ids: set[int]
    ) -> dict[int, list[ProcessResourceSample]]:
        try:
            completed = subprocess.run(
                ["ps", "-axo", "pid=,pgid=,rss=,time=,state="],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=2.0,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BenchmarkError(f"could not sample processes with ps: {exc}") from exc
        if completed.returncode != 0:
            detail = completed.stderr.strip()
            suffix = f": {detail}" if detail else ""
            raise BenchmarkError(
                f"could not sample processes with ps (status {completed.returncode}){suffix}"
            )

        groups = {process_group_id: [] for process_group_id in process_group_ids}
        for line in completed.stdout.splitlines():
            fields = line.split()
            if len(fields) != 5:
                continue
            try:
                pid = int(fields[0])
                process_group_id = int(fields[1])
                if process_group_id not in groups:
                    continue
                rss_kib = int(fields[2])
                cpu_seconds = parse_ps_cpu_seconds(fields[3])
            except ValueError:
                continue
            groups[process_group_id].append(
                ProcessResourceSample(
                    pid=pid,
                    process_group_id=process_group_id,
                    rss_kib=rss_kib,
                    cpu_seconds=cpu_seconds,
                    state=fields[4],
                )
            )
        return groups


def select_resource_sampler(
    platform_name: str | None = None,
) -> LinuxProcResourceSampler | DarwinPsResourceSampler:
    selected = sys.platform if platform_name is None else platform_name
    if selected.startswith("linux"):
        return LinuxProcResourceSampler()
    if selected == "darwin":
        return DarwinPsResourceSampler()
    raise BenchmarkError(
        f"idle resource sampling is not supported on platform {selected!r}"
    )


def load_module(directory: pathlib.Path, *, require_benchmark: bool = False) -> ModuleSpec:
    directory = directory.expanduser().resolve()
    manifest_path = directory / "tnt-module.json"
    if not directory.is_dir():
        raise BenchmarkError(f"module directory does not exist: {directory}")
    try:
        raw_manifest = manifest_path.read_bytes()
    except OSError as exc:
        raise BenchmarkError(f"could not read {manifest_path}: {exc}") from exc
    manifest = strict_json_object(raw_manifest, str(manifest_path))
    if manifest.get("protocol") != PROTOCOL:
        raise BenchmarkError(f"unsupported protocol in {manifest_path}")

    name = manifest.get("name")
    version = manifest.get("version")
    entrypoint_text = manifest.get("entrypoint")
    if not isinstance(name, str) or not name:
        raise BenchmarkError(f"missing module name in {manifest_path}")
    if not isinstance(version, str) or not version:
        raise BenchmarkError(f"missing module version in {manifest_path}")
    if not isinstance(entrypoint_text, str) or not entrypoint_text:
        raise BenchmarkError(f"missing entrypoint in {manifest_path}")

    benchmark = manifest.get("benchmark")
    if benchmark is None and require_benchmark:
        raise BenchmarkError(f"missing benchmark object in {manifest_path}")
    if benchmark is None:
        workload_plain_text = "tnt module benchmark warm event"
        expect_message_create = False
    else:
        if not isinstance(benchmark, dict):
            raise BenchmarkError(f"benchmark must be an object in {manifest_path}")
        workload_plain_text = benchmark.get("plain_text")
        expect_message_create_declared = "expect_message_create" in benchmark
        expect_message_create = benchmark.get("expect_message_create", False)
        if not isinstance(workload_plain_text, str) or not workload_plain_text:
            raise BenchmarkError(
                f"benchmark.plain_text must be a non-empty string in {manifest_path}"
            )
        if not isinstance(expect_message_create, bool):
            raise BenchmarkError(
                f"benchmark.expect_message_create must be a boolean in {manifest_path}"
            )
        if require_benchmark and (
            not expect_message_create_declared or not expect_message_create
        ):
            raise BenchmarkError(
                "benchmark.expect_message_create must be explicitly true in "
                f"{manifest_path}"
            )
    validate_plain_text(
        workload_plain_text,
        f"{manifest_path}: benchmark.plain_text",
        reject_controls=False,
    )

    entrypoint_relative = pathlib.Path(entrypoint_text)
    if entrypoint_relative.is_absolute() or ".." in entrypoint_relative.parts:
        raise BenchmarkError(f"entrypoint must stay inside its module directory: {manifest_path}")
    entrypoint = (directory / entrypoint_relative).resolve()
    try:
        entrypoint.relative_to(directory)
    except ValueError as exc:
        raise BenchmarkError(f"entrypoint escapes its module directory: {manifest_path}") from exc
    if not entrypoint.is_file():
        raise BenchmarkError(f"entrypoint does not exist: {entrypoint}")
    if not os.access(entrypoint, os.X_OK):
        raise BenchmarkError(f"entrypoint is not executable: {entrypoint}")

    return ModuleSpec(
        name=name,
        version=version,
        directory=directory,
        entrypoint=entrypoint,
        workload_plain_text=workload_plain_text,
        expect_message_create=expect_message_create,
    )


def discover_modules(root: pathlib.Path, requested: Sequence[str]) -> list[ModuleSpec]:
    if requested:
        directories = [pathlib.Path(item) for item in requested]
    else:
        modules_dir = root / "modules"
        directories = sorted(
            path.parent
            for path in modules_dir.glob("*/tnt-module.json")
            if path.is_file()
        )
    if not directories:
        raise BenchmarkError("no module directories found")

    modules = [
        load_module(directory, require_benchmark=not requested)
        for directory in directories
    ]
    seen: set[str] = set()
    for module in modules:
        if module.name in seen:
            raise BenchmarkError(f"duplicate module name: {module.name}")
        seen.add(module.name)
    return modules


def handshake_request() -> dict[str, Any]:
    return {
        "type": "handshake",
        "protocol": PROTOCOL,
        "server": {"name": "tnt-benchmark", "version": "1.1.0"},
    }


def event_request(spec: ModuleSpec, sequence: int) -> dict[str, Any]:
    return {
        "type": "message.created",
        "message": {
            "id": f"benchmark-{sequence}",
            "timestamp": "1970-01-01T00:00:00Z",
            "sender": "benchmark",
            "kind": "text",
            "plain_text": spec.workload_plain_text,
            "metadata": {"benchmark": True},
        },
    }


def perform_handshake(
    running: RunningModule,
    spec: ModuleSpec,
    timeout_seconds: float,
) -> Measurement:
    context = f"{spec.name} handshake"
    started = time.perf_counter()
    deadline = time.monotonic() + timeout_seconds
    running.write_json(handshake_request(), context)
    raw = running.read_line(deadline, context)
    response = strict_json_object(raw, context)
    elapsed_ms = (time.perf_counter() - started) * 1000.0

    if response.get("type") != "handshake.ok" or response.get("protocol") != PROTOCOL:
        raise BenchmarkError(f"{context}: expected handshake.ok for {PROTOCOL}")
    module = response.get("module")
    if not isinstance(module, dict) or module.get("name") != spec.name:
        raise BenchmarkError(f"{context}: handshake module name did not match manifest")
    if module.get("version") != spec.version:
        raise BenchmarkError(f"{context}: handshake module version did not match manifest")
    return Measurement(latency_ms=elapsed_ms, output_bytes=len(raw) + 1)


def perform_event(
    running: RunningModule,
    spec: ModuleSpec,
    sequence: int,
    timeout_seconds: float,
) -> Measurement:
    context = f"{spec.name} event {sequence}"
    started = time.perf_counter()
    deadline = time.monotonic() + timeout_seconds
    running.write_json(event_request(spec, sequence), context)

    output_bytes = 0
    message_create_seen = False
    for record_number in range(1, MAX_EVENT_RECORDS + 1):
        raw = running.read_line(deadline, context)
        output_bytes += len(raw) + 1
        response = strict_json_object(raw, f"{context} record {record_number}")
        response_type = response.get("type")
        if response_type == "event.ok":
            if spec.expect_message_create and not message_create_seen:
                raise BenchmarkError(
                    f"{context}: workload expected message.create before event.ok"
                )
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            return Measurement(latency_ms=elapsed_ms, output_bytes=output_bytes)
        if response_type == "message.create":
            plain_text = response.get("plain_text")
            if not isinstance(plain_text, str) or not plain_text:
                raise BenchmarkError(
                    f"{context} record {record_number}: message.create requires plain_text"
                )
            validate_plain_text(
                plain_text,
                f"{context} record {record_number}",
                reject_controls=True,
            )
            message_create_seen = True
            continue
        raise BenchmarkError(
            f"{context} record {record_number}: unexpected response type {response_type!r}"
        )

    raise BenchmarkError(
        f"{context}: event.ok not received within {MAX_EVENT_RECORDS} records"
    )


def benchmark_startup(
    spec: ModuleSpec,
    samples: int,
    timeout_seconds: float,
) -> list[Measurement]:
    results: list[Measurement] = []
    for _ in range(samples):
        started = time.perf_counter()
        deadline = time.monotonic() + timeout_seconds
        with RunningModule(spec) as running:
            # Include process creation in startup latency, not just handshake I/O.
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchmarkError(f"{spec.name} handshake: startup timed out")
            measurement = perform_handshake(running, spec, remaining)
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            results.append(
                Measurement(
                    latency_ms=elapsed_ms,
                    output_bytes=measurement.output_bytes,
                )
            )
    return results


def benchmark_events(
    spec: ModuleSpec,
    warmups: int,
    samples: int,
    startup_timeout_seconds: float,
    event_timeout_seconds: float,
) -> list[Measurement]:
    with RunningModule(spec) as running:
        perform_handshake(running, spec, startup_timeout_seconds)
        sequence = 1
        for _ in range(warmups):
            perform_event(running, spec, sequence, event_timeout_seconds)
            sequence += 1

        results: list[Measurement] = []
        for _ in range(samples):
            results.append(
                perform_event(running, spec, sequence, event_timeout_seconds)
            )
            sequence += 1
        return results


def capture_idle_resource_sample(
    sampler: LinuxProcResourceSampler | DarwinPsResourceSampler,
    slots: Sequence[IdleResourceSlot],
    *,
    baseline: bool,
) -> tuple[list[int], int]:
    for slot in slots:
        slot.running.assert_idle_stdout(
            f"idle resource slot {slot.slot} ({slot.spec.name})"
        )

    groups = sampler.snapshot({slot.process_group_id for slot in slots})
    rss_by_slot: list[int] = []
    aggregate_process_count = 0
    for slot in slots:
        processes = groups.get(slot.process_group_id, [])
        leader = next(
            (process for process in processes if process.pid == slot.leader_pid),
            None,
        )
        if leader is None or leader.state.upper().startswith("Z"):
            raise BenchmarkError(
                f"idle resource slot {slot.slot} ({slot.spec.name}): "
                "module leader exited while idle"
            )

        rss_kib = sum(process.rss_kib for process in processes)
        process_count = len(processes)
        slot.rss_samples_kib.append(rss_kib)
        slot.process_count_samples.append(process_count)
        rss_by_slot.append(rss_kib)
        aggregate_process_count += process_count

        for process in processes:
            if baseline:
                slot.cpu_baseline_seconds[process.pid] = process.cpu_seconds
            elif process.pid not in slot.cpu_baseline_seconds:
                # Count the full lifetime of a helper first observed after the
                # baseline. This slightly overcounts rather than hiding work.
                slot.cpu_baseline_seconds[process.pid] = 0.0
            previous = slot.cpu_latest_seconds.get(process.pid, 0.0)
            slot.cpu_latest_seconds[process.pid] = max(
                previous, process.cpu_seconds
            )
    return rss_by_slot, aggregate_process_count


def resource_value_summary(values: Sequence[int]) -> dict[str, int | float]:
    if not values:
        raise ValueError("resource summary requires at least one sample")
    return {
        "samples": len(values),
        "min": min(values),
        "max": max(values),
        "mean": statistics.fmean(values),
    }


def benchmark_idle_resources(
    modules: Sequence[ModuleSpec],
    *,
    instances: int,
    settle_seconds: float,
    duration_seconds: float,
    sample_interval_seconds: float,
    startup_timeout_seconds: float,
) -> dict[str, Any]:
    if not modules:
        raise BenchmarkError("idle resource benchmark requires at least one module")

    sampler = select_resource_sampler()
    assignments = [modules[index % len(modules)] for index in range(instances)]
    slots: list[IdleResourceSlot] = []
    aggregate_rss_samples_kib: list[int] = []
    aggregate_process_count_samples: list[int] = []

    with contextlib.ExitStack() as stack:
        for index, spec in enumerate(assignments, start=1):
            running = stack.enter_context(RunningModule(spec))
            perform_handshake(running, spec, startup_timeout_seconds)
            if running.process is None or running.process_group_id is None:
                raise BenchmarkError(
                    f"idle resource slot {index} ({spec.name}): module did not start"
                )
            slots.append(
                IdleResourceSlot(
                    slot=index,
                    spec=spec,
                    running=running,
                    process_group_id=running.process_group_id,
                    leader_pid=running.process.pid,
                )
            )

        settle_deadline = time.monotonic() + settle_seconds
        while time.monotonic() < settle_deadline:
            remaining = settle_deadline - time.monotonic()
            time.sleep(min(sample_interval_seconds, max(0.0, remaining)))
            capture_idle_resource_sample(sampler, slots, baseline=False)
            # Settling samples validate health but are intentionally excluded
            # from the measured interval and resource summaries.
            for slot in slots:
                slot.rss_samples_kib.clear()
                slot.process_count_samples.clear()
                slot.cpu_baseline_seconds.clear()
                slot.cpu_latest_seconds.clear()

        rss_by_slot, aggregate_process_count = capture_idle_resource_sample(
            sampler, slots, baseline=True
        )
        aggregate_rss_samples_kib.append(sum(rss_by_slot))
        aggregate_process_count_samples.append(aggregate_process_count)

        started = time.monotonic()
        deadline = started + duration_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(sample_interval_seconds, remaining))
            rss_by_slot, aggregate_process_count = capture_idle_resource_sample(
                sampler, slots, baseline=False
            )
            aggregate_rss_samples_kib.append(sum(rss_by_slot))
            aggregate_process_count_samples.append(aggregate_process_count)
        elapsed_seconds = time.monotonic() - started

    slot_reports: list[dict[str, Any]] = []
    for slot in slots:
        cpu_seconds = sum(
            max(
                0.0,
                slot.cpu_latest_seconds.get(pid, baseline) - baseline,
            )
            for pid, baseline in slot.cpu_baseline_seconds.items()
        )
        one_core_percent = (
            cpu_seconds * 100.0 / elapsed_seconds if elapsed_seconds > 0 else 0.0
        )
        rss_summary = resource_value_summary(slot.rss_samples_kib)
        failures: list[str] = []
        if rss_summary["max"] > MODULE_IDLE_RSS_BUDGET_KIB:
            failures.append(
                f"idle RSS {rss_summary['max']} KiB > "
                f"{MODULE_IDLE_RSS_BUDGET_KIB} KiB"
            )
        if one_core_percent > MODULE_IDLE_CPU_BUDGET_PERCENT:
            failures.append(
                f"idle CPU {one_core_percent:.3f}% > "
                f"{MODULE_IDLE_CPU_BUDGET_PERCENT:.3f}% of one core"
            )
        slot_reports.append(
            {
                "slot": slot.slot,
                "module": slot.spec.name,
                "version": slot.spec.version,
                "rss_kib": rss_summary,
                "cpu_seconds": cpu_seconds,
                "one_core_percent": one_core_percent,
                "process_count_peak": max(slot.process_count_samples),
                "pass": not failures,
                "failures": failures,
            }
        )

    aggregate_rss = resource_value_summary(aggregate_rss_samples_kib)
    aggregate_cpu_seconds = sum(slot["cpu_seconds"] for slot in slot_reports)
    aggregate_failures: list[str] = []
    aggregate_budget_applicable = instances == 8
    if (
        aggregate_budget_applicable
        and aggregate_rss["max"] > EIGHT_MODULE_IDLE_RSS_BUDGET_KIB
    ):
        aggregate_failures.append(
            f"eight-module idle RSS {aggregate_rss['max']} KiB > "
            f"{EIGHT_MODULE_IDLE_RSS_BUDGET_KIB} KiB"
        )

    assignments_report: list[dict[str, Any]] = []
    seen_assignments: set[str] = set()
    for index, spec in enumerate(assignments, start=1):
        assignments_report.append(
            {
                "slot": index,
                "module": spec.name,
                "version": spec.version,
                "reused": spec.name in seen_assignments,
            }
        )
        seen_assignments.add(spec.name)

    passed = all(slot["pass"] for slot in slot_reports) and not aggregate_failures
    return {
        "status": "measured",
        "backend": sampler.backend_name,
        "assignments": assignments_report,
        "duration_seconds": elapsed_seconds,
        "sample_count": len(aggregate_rss_samples_kib),
        "slots": slot_reports,
        "aggregate": {
            "rss_kib": aggregate_rss,
            "cpu_seconds": aggregate_cpu_seconds,
            "one_core_percent": (
                aggregate_cpu_seconds * 100.0 / elapsed_seconds
                if elapsed_seconds > 0
                else 0.0
            ),
            "process_count_peak": max(aggregate_process_count_samples),
            "eight_module_rss_budget_applicable": aggregate_budget_applicable,
            "pass": not aggregate_failures,
            "failures": aggregate_failures,
        },
        "pass": passed,
        "failures": [
            failure
            for slot in slot_reports
            for failure in (
                f"slot {slot['slot']} ({slot['module']}): {message}"
                for message in slot["failures"]
            )
        ]
        + aggregate_failures,
    }


def nearest_rank(values: Sequence[float], percentile: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    index = max(0, math.ceil((percentile / 100.0) * len(ordered)) - 1)
    return ordered[index]


def measurement_summary(measurements: Sequence[Measurement]) -> dict[str, Any]:
    latencies = [item.latency_ms for item in measurements]
    output = [item.output_bytes for item in measurements]
    return {
        "samples": len(measurements),
        "p50_ms": nearest_rank(latencies, 50.0),
        "p95_ms": nearest_rank(latencies, 95.0),
        "p99_ms": nearest_rank(latencies, 99.0),
        "output_bytes": {
            "total": sum(output),
            "min": min(output),
            "max": max(output),
            "mean": statistics.fmean(output),
        },
    }


def module_report(
    spec: ModuleSpec,
    startup: Sequence[Measurement],
    events: Sequence[Measurement],
) -> dict[str, Any]:
    startup_summary = measurement_summary(startup)
    event_summary = measurement_summary(events)
    failures: list[str] = []
    if startup_summary["p95_ms"] > STARTUP_P95_BUDGET_MS:
        failures.append(
            f"startup p95 {startup_summary['p95_ms']:.3f} ms > "
            f"{STARTUP_P95_BUDGET_MS:.3f} ms"
        )
    if event_summary["p95_ms"] > EVENT_P95_BUDGET_MS:
        failures.append(
            f"event p95 {event_summary['p95_ms']:.3f} ms > "
            f"{EVENT_P95_BUDGET_MS:.3f} ms"
        )
    if event_summary["p99_ms"] > EVENT_P99_BUDGET_MS:
        failures.append(
            f"event p99 {event_summary['p99_ms']:.3f} ms > "
            f"{EVENT_P99_BUDGET_MS:.3f} ms"
        )
    if event_summary["output_bytes"]["max"] > EVENT_OUTPUT_BUDGET_BYTES:
        failures.append(
            f"event output {event_summary['output_bytes']['max']} bytes > "
            f"{EVENT_OUTPUT_BUDGET_BYTES} bytes"
        )
    return {
        "name": spec.name,
        "version": spec.version,
        "directory": str(spec.directory),
        "workload": {
            "plain_text": spec.workload_plain_text,
            "expect_message_create": spec.expect_message_create,
        },
        "startup": startup_summary,
        "event": event_summary,
        "pass": not failures,
        "failures": failures,
    }


def run_command(command: Sequence[str], cwd: pathlib.Path) -> str | None:
    try:
        completed = subprocess.run(
            command,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2.0,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


def cpu_name() -> str:
    if sys.platform == "darwin":
        value = run_command(["sysctl", "-n", "machdep.cpu.brand_string"], pathlib.Path("/"))
        if not value:
            value = run_command(["sysctl", "-n", "hw.model"], pathlib.Path("/"))
        if value:
            return value

    try:
        with pathlib.Path("/proc/cpuinfo").open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                key, separator, value = line.partition(":")
                if separator and key.strip() in {"model name", "Hardware", "Processor"}:
                    value = value.strip()
                    if value:
                        return value
    except OSError:
        pass
    processor = platform.processor().strip()
    if processor:
        return processor
    return platform.machine() or "unknown"


def metadata(root: pathlib.Path) -> dict[str, Any]:
    commit = run_command(["git", "rev-parse", "--verify", "HEAD"], root) or "unknown"
    dirty_output = run_command(["git", "status", "--porcelain"], root)
    return {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "commit": commit,
        "git_dirty": bool(dirty_output),
        "os": {
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.version(),
            "machine": platform.machine(),
        },
        "python": {
            "implementation": platform.python_implementation(),
            "version": platform.python_version(),
        },
        "cpu": {
            "name": cpu_name(),
            "logical_count": os.cpu_count(),
        },
    }


def budgets() -> dict[str, Any]:
    return {
        "startup_p95_ms": STARTUP_P95_BUDGET_MS,
        "event_p95_ms": EVENT_P95_BUDGET_MS,
        "event_p99_ms": EVENT_P99_BUDGET_MS,
        "event_output_bytes": EVENT_OUTPUT_BUDGET_BYTES,
        "module_idle_rss_kib": MODULE_IDLE_RSS_BUDGET_KIB,
        "eight_module_idle_rss_kib": EIGHT_MODULE_IDLE_RSS_BUDGET_KIB,
        "module_idle_cpu_percent": MODULE_IDLE_CPU_BUDGET_PERCENT,
    }


def transport_limits() -> dict[str, int]:
    """Return TNT's stricter, independently enforced JSONL transport limits."""
    return {
        "jsonl_payload_bytes": MAX_JSONL_PAYLOAD_BYTES,
        "event_response_records": MAX_EVENT_RECORDS,
        "event_output_bytes_including_newlines": MAX_EVENT_OUTPUT_BYTES,
    }


def write_json_report(path: pathlib.Path, report: dict[str, Any]) -> None:
    try:
        path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise BenchmarkError(f"could not write JSON report {path}: {exc}") from exc


def print_human_report(report: dict[str, Any], enforce: bool) -> None:
    meta = report["metadata"]
    config = report["configuration"]
    print("TNT module benchmark")
    print(f"commit: {meta['commit']} (dirty={str(meta['git_dirty']).lower()})")
    print(
        "host: "
        f"{meta['os']['system']} {meta['os']['release']} {meta['os']['machine']}; "
        f"Python {meta['python']['version']}; {meta['cpu']['name']}"
    )
    print(
        "samples: "
        f"startup={config['startup_samples']}, warmups={config['warmups']}, "
        f"event={config['samples']}"
    )
    print(
        "budgets: startup p95 <= 150 ms; event p95 <= 50 ms; "
        "event p99 <= 100 ms; event output <= 32768 bytes"
    )
    print(
        "transport hard limits: JSONL payload <= 4094 bytes; "
        "event records <= 8; event output <= 32760 bytes including newlines"
    )
    if config["idle_resources"]["enabled"]:
        print(
            "idle budgets: module RSS <= 16384 KiB; exact 8-slot RSS <= "
            "81920 KiB; module CPU <= 0.2% of one core"
        )
    print()
    print(
        f"{'module':<20} {'startup p50/p95/p99 ms':<29} "
        f"{'startup bytes avg/max':<23} {'event p50/p95/p99 ms':<27} "
        f"{'event bytes avg/max':<21} result"
    )
    for module in report["modules"]:
        startup = module["startup"]
        event = module["event"]
        startup_output = startup["output_bytes"]
        event_output = event["output_bytes"]
        startup_text = (
            f"{startup['p50_ms']:.3f}/{startup['p95_ms']:.3f}/"
            f"{startup['p99_ms']:.3f}"
        )
        event_text = (
            f"{event['p50_ms']:.3f}/{event['p95_ms']:.3f}/{event['p99_ms']:.3f}"
        )
        startup_output_text = f"{startup_output['mean']:.1f}/{startup_output['max']}"
        event_output_text = f"{event_output['mean']:.1f}/{event_output['max']}"
        result = "PASS" if module["pass"] else "FAIL"
        print(
            f"{module['name']:<20} {startup_text:<29} "
            f"{startup_output_text:<23} {event_text:<27} "
            f"{event_output_text:<21} {result}"
        )
        for failure in module["failures"]:
            print(f"  - {failure}")
    idle_resources = report["idle_resources"]
    if idle_resources["status"] == "measured":
        print()
        print(
            "idle resources: "
            f"{len(idle_resources['slots'])} slots via "
            f"{idle_resources['backend']}; "
            f"{idle_resources['duration_seconds']:.3f} s, "
            f"{idle_resources['sample_count']} samples"
        )
        print(
            f"{'slot/module':<27} {'RSS KiB mean/max':<20} "
            f"{'CPU sec/one-core %':<23} {'processes max':<14} result"
        )
        for slot in idle_resources["slots"]:
            rss = slot["rss_kib"]
            label = f"{slot['slot']}:{slot['module']}"
            print(
                f"{label:<27} {rss['mean']:.1f}/{rss['max']:<12} "
                f"{slot['cpu_seconds']:.6f}/{slot['one_core_percent']:<12.3f} "
                f"{slot['process_count_peak']:<14} "
                f"{'PASS' if slot['pass'] else 'FAIL'}"
            )
        aggregate = idle_resources["aggregate"]
        aggregate_rss = aggregate["rss_kib"]
        print(
            "aggregate: RSS mean/max "
            f"{aggregate_rss['mean']:.1f}/{aggregate_rss['max']} KiB; "
            f"CPU {aggregate['one_core_percent']:.3f}% of one core; "
            f"processes max {aggregate['process_count_peak']}; "
            f"{'PASS' if aggregate['pass'] else 'FAIL'}"
        )
        for failure in idle_resources["failures"]:
            print(f"  - {failure}")
    elif idle_resources["status"] == "error":
        print()
        print(f"idle resources: ERROR: {idle_resources['error']}")
    print()
    qualifier = "enforced" if enforce else "informational; use --check to enforce"
    print(f"overall: {'PASS' if report['pass'] else 'FAIL'} ({qualifier})")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark TNT module handshake and warm-event latency."
    )
    parser.add_argument(
        "--samples",
        type=positive_int,
        default=DEFAULT_SAMPLES,
        help=f"timed warm-event samples per module (default: {DEFAULT_SAMPLES})",
    )
    parser.add_argument(
        "--startup-samples",
        type=positive_int,
        default=DEFAULT_STARTUP_SAMPLES,
        help=f"cold startup samples per module (default: {DEFAULT_STARTUP_SAMPLES})",
    )
    parser.add_argument(
        "--warmups",
        type=warmup_count,
        default=DEFAULT_WARMUPS,
        help=f"untimed events before sampling, minimum 5 (default: {DEFAULT_WARMUPS})",
    )
    parser.add_argument(
        "--module-dir",
        action="append",
        default=[],
        metavar="PATH",
        help="benchmark this module directory instead of auto-discovery; repeatable",
    )
    parser.add_argument(
        "--startup-timeout",
        type=positive_float,
        default=DEFAULT_STARTUP_TIMEOUT_SECONDS,
        metavar="SECONDS",
        help="hard timeout for each handshake (default: 2.0)",
    )
    parser.add_argument(
        "--event-timeout",
        type=positive_float,
        default=DEFAULT_EVENT_TIMEOUT_SECONDS,
        metavar="SECONDS",
        help="hard timeout for each complete event response (default: 2.0)",
    )
    parser.add_argument(
        "--idle-resources",
        action="store_true",
        help="measure co-resident module idle RSS, CPU, and process count",
    )
    parser.add_argument(
        "--idle-instances",
        type=idle_instance_count,
        default=DEFAULT_IDLE_INSTANCES,
        metavar="COUNT",
        help="co-resident module slots, 1..8 (default: 8)",
    )
    parser.add_argument(
        "--idle-settle",
        type=nonnegative_float,
        default=DEFAULT_IDLE_SETTLE_SECONDS,
        metavar="SECONDS",
        help="quiet settling period before resource sampling (default: 0.5)",
    )
    parser.add_argument(
        "--idle-seconds",
        type=positive_float,
        default=DEFAULT_IDLE_SECONDS,
        metavar="SECONDS",
        help="idle resource measurement duration (default: 10.0)",
    )
    parser.add_argument(
        "--resource-sample-interval",
        type=positive_float,
        default=DEFAULT_RESOURCE_SAMPLE_INTERVAL_SECONDS,
        metavar="SECONDS",
        help="idle process sampling interval (default: 0.25)",
    )
    parser.add_argument(
        "--json-output",
        type=pathlib.Path,
        metavar="PATH",
        help="also write the structured benchmark report to PATH",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="return non-zero when a module exceeds a performance/output budget",
    )
    return parser.parse_args(argv)


def run_configured_benchmark(
    args: argparse.Namespace,
    root: pathlib.Path,
    report: dict[str, Any],
    module_results: list[dict[str, Any]],
) -> int:
    """Run the configured work; callers own process-control signal policy."""

    try:
        modules = discover_modules(root, args.module_dir)
        for spec in modules:
            startup = benchmark_startup(
                spec,
                samples=args.startup_samples,
                timeout_seconds=args.startup_timeout,
            )
            events = benchmark_events(
                spec,
                warmups=args.warmups,
                samples=args.samples,
                startup_timeout_seconds=args.startup_timeout,
                event_timeout_seconds=args.event_timeout,
            )
            module_results.append(module_report(spec, startup, events))

        if args.idle_resources:
            try:
                report["idle_resources"] = benchmark_idle_resources(
                    modules,
                    instances=args.idle_instances,
                    settle_seconds=args.idle_settle,
                    duration_seconds=args.idle_seconds,
                    sample_interval_seconds=args.resource_sample_interval,
                    startup_timeout_seconds=args.startup_timeout,
                )
            except BenchmarkError as exc:
                report["idle_resources"] = {
                    "status": "error",
                    "error": str(exc),
                    "pass": False,
                }
                raise

        report["pass"] = all(module["pass"] for module in module_results) and (
            not args.idle_resources or report["idle_resources"]["pass"]
        )
        if args.json_output is not None:
            write_json_report(args.json_output, report)
        print_human_report(report, args.check)
        if args.check and not report["pass"]:
            return 1
        return 0
    except BenchmarkError as exc:
        report["error"] = str(exc)
        report["pass"] = False
        if args.json_output is not None:
            try:
                write_json_report(args.json_output, report)
            except BenchmarkError as report_exc:
                print(f"benchmark-modules: {exc}", file=sys.stderr)
                print(f"benchmark-modules: {report_exc}", file=sys.stderr)
                return 2
        print(f"benchmark-modules: {exc}", file=sys.stderr)
        return 2


def run(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    root = pathlib.Path(__file__).resolve().parents[1]
    module_results: list[dict[str, Any]] = []
    report: dict[str, Any] = {
        "schema_version": 1,
        "metadata": metadata(root),
        "configuration": {
            "samples": args.samples,
            "startup_samples": args.startup_samples,
            "warmups": args.warmups,
            "startup_timeout_seconds": args.startup_timeout,
            "event_timeout_seconds": args.event_timeout,
            "idle_resources": {
                "enabled": args.idle_resources,
                "instances": args.idle_instances,
                "settle_seconds": args.idle_settle,
                "duration_seconds": args.idle_seconds,
                "sample_interval_seconds": args.resource_sample_interval,
            },
        },
        "budgets": budgets(),
        "transport_limits": transport_limits(),
        "modules": module_results,
        "idle_resources": {
            "status": "not_requested",
            "pass": None,
        },
        "error": None,
        "pass": False,
    }

    try:
        with temporary_interrupt_signal_handlers():
            return run_configured_benchmark(
                args,
                root,
                report,
                module_results,
            )
    except BenchmarkInterrupted as exc:
        try:
            signal_name = signal.Signals(exc.signum).name
        except ValueError:
            signal_name = f"signal {exc.signum}"
        message = f"interrupted by {signal_name}"
        report["error"] = message
        report["pass"] = False
        if (
            args.idle_resources
            and report["idle_resources"].get("status") == "not_requested"
        ):
            report["idle_resources"] = {
                "status": "error",
                "error": message,
                "pass": False,
            }

        print(f"benchmark-modules: {message}", file=sys.stderr)
        if args.json_output is not None:
            try:
                write_json_report(args.json_output, report)
            except BenchmarkError as report_exc:
                # Signal exit status takes precedence over report I/O failure.
                print(f"benchmark-modules: {report_exc}", file=sys.stderr)
        return 128 + exc.signum


def main() -> None:
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
