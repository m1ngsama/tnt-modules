#!/usr/bin/env python3
"""Regression tests for scripts/benchmark_modules.py."""

from __future__ import annotations

import contextlib
import errno
import importlib.util
import io
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
BENCHMARK = ROOT / "scripts" / "benchmark_modules.py"

BENCHMARK_IMPORT_SPEC = importlib.util.spec_from_file_location(
    "tnt_benchmark_modules_under_test", BENCHMARK
)
assert BENCHMARK_IMPORT_SPEC is not None
assert BENCHMARK_IMPORT_SPEC.loader is not None
benchmark_module = importlib.util.module_from_spec(BENCHMARK_IMPORT_SPEC)
sys.modules[BENCHMARK_IMPORT_SPEC.name] = benchmark_module
BENCHMARK_IMPORT_SPEC.loader.exec_module(benchmark_module)


class BenchmarkModulesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="tnt-benchmark-test."
        )
        self.state_dir = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_module(
        self,
        name: str,
        event_delay: float = 0.0,
        *,
        terminate_event: bool = True,
        benchmark_expect_message_create: bool | None = True,
        workload_plain_text: str = "/benchmark action",
        respond_only_to_workload: bool = False,
        module_root: pathlib.Path | None = None,
    ) -> pathlib.Path:
        module_dir = (module_root or self.state_dir) / name
        module_dir.mkdir(parents=True)
        benchmark = {"plain_text": workload_plain_text}
        if benchmark_expect_message_create is not None:
            benchmark["expect_message_create"] = benchmark_expect_message_create
        manifest = {
            "protocol": "tnt.module.v1",
            "name": name,
            "version": "0.1.0",
            "entrypoint": "./module.py",
            "permissions": ["message:read", "message:create"],
            "events": ["message.created"],
            "benchmark": benchmark,
        }
        (module_dir / "tnt-module.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        entrypoint = module_dir / "module.py"
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import sys
                import time

                for line in sys.stdin:
                    request = json.loads(line)
                    if request.get("type") == "handshake":
                        response = {{
                            "type": "handshake.ok",
                            "protocol": "tnt.module.v1",
                            "module": {{"name": {name!r}, "version": "0.1.0"}},
                        }}
                        print(json.dumps(response, separators=(",", ":")), flush=True)
                    elif request.get("type") == "message.created":
                        time.sleep({event_delay!r})
                        if (
                            not {respond_only_to_workload!r}
                            or request.get("message", {{}}).get("plain_text")
                            == {workload_plain_text!r}
                        ):
                            print('{{"type":"message.create","plain_text":"benchmark reply"}}', flush=True)
                        if {terminate_event!r}:
                            print('{{"type":"event.ok"}}', flush=True)
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    def write_child_leaking_module(self, name: str) -> pathlib.Path:
        module_dir = self.write_module(name)
        entrypoint = module_dir / "module.py"
        child_program = textwrap.dedent(
            """\
            import pathlib
            import signal
            import sys
            import time

            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            pathlib.Path(sys.argv[1]).write_text("ready", encoding="ascii")
            while True:
                time.sleep(60)
            """
        )
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import pathlib
                import signal
                import subprocess
                import sys
                import time

                request = json.loads(sys.stdin.readline())
                if request.get("type") != "handshake":
                    raise SystemExit(2)

                child_program = {child_program!r}
                ready_path = pathlib.Path("child.ready").resolve()
                child = subprocess.Popen(
                    [sys.executable, "-c", child_program, str(ready_path)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                pathlib.Path("child.pid").write_text(str(child.pid), encoding="ascii")
                deadline = time.monotonic() + 2.0
                while not ready_path.exists():
                    if time.monotonic() >= deadline:
                        raise SystemExit(3)
                    time.sleep(0.005)

                response = {{
                    "type": "handshake.ok",
                    "protocol": "tnt.module.v1",
                    "module": {{"name": {name!r}, "version": "0.1.0"}},
                }}
                print(json.dumps(response, separators=(",", ":")), flush=True)
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    def write_shell_module(self, name: str) -> pathlib.Path:
        module_dir = self.write_module(name)
        manifest_path = module_dir / "tnt-module.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["entrypoint"] = "./module.sh"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        entrypoint = module_dir / "module.sh"
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                IFS= read -r request || exit 1
                printf '%s\\n' '{{"type":"handshake.ok","protocol":"tnt.module.v1","module":{{"name":"{name}","version":"0.1.0"}}}}'
                while IFS= read -r request; do
                    printf '%s\\n' '{{"type":"message.create","plain_text":"benchmark reply"}}'
                    printf '%s\\n' '{{"type":"event.ok"}}'
                done
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    def write_resource_child_module(self, name: str, mode: str) -> pathlib.Path:
        if mode == "rss":
            child_program = textwrap.dedent(
                """\
                import pathlib
                import signal
                import sys
                import time

                payload = bytearray(32 * 1024 * 1024)
                for offset in range(0, len(payload), 4096):
                    payload[offset] = 1
                pathlib.Path(sys.argv[1]).write_text("ready", encoding="ascii")
                while True:
                    time.sleep(60)
                """
            )
        elif mode == "cpu":
            child_program = textwrap.dedent(
                """\
                import pathlib
                import sys

                pathlib.Path(sys.argv[1]).write_text("ready", encoding="ascii")
                value = 0
                while True:
                    value = (value + 1) % 1000003
                """
            )
        else:
            raise ValueError(f"unknown resource child mode: {mode}")

        module_dir = self.write_module(name)
        entrypoint = module_dir / "module.py"
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import os
                import pathlib
                import subprocess
                import sys
                import time

                child = None
                child_program = {child_program!r}
                for line in sys.stdin:
                    request = json.loads(line)
                    if request.get("type") == "handshake":
                        response = {{
                            "type": "handshake.ok",
                            "protocol": "tnt.module.v1",
                            "module": {{"name": {name!r}, "version": "0.1.0"}},
                        }}
                        print(json.dumps(response, separators=(",", ":")), flush=True)
                        ready = pathlib.Path(f"child-ready-{{os.getpid()}}")
                        child = subprocess.Popen(
                            [sys.executable, "-c", child_program, str(ready)],
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                        )
                        deadline = time.monotonic() + 2.0
                        while not ready.exists():
                            if time.monotonic() >= deadline:
                                raise SystemExit(3)
                            time.sleep(0.005)
                    elif request.get("type") == "message.created":
                        print('{{"type":"message.create","plain_text":"benchmark reply"}}', flush=True)
                        print('{{"type":"event.ok"}}', flush=True)
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    def write_idle_fault_module(self, name: str, fault: str) -> pathlib.Path:
        if fault == "unsolicited":
            fault_program = textwrap.dedent(
                """\
                time.sleep(0.03)
                print('{"type":"event.ok"}', flush=True)
                while True:
                    time.sleep(60)
                """
            )
        elif fault == "leader-exit":
            fault_program = textwrap.dedent(
                """\
                subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
                raise SystemExit(0)
                """
            )
        else:
            raise ValueError(f"unknown idle fault: {fault}")

        module_dir = self.write_module(name)
        entrypoint = module_dir / "module.py"
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import subprocess
                import sys
                import time

                request = json.loads(sys.stdin.readline())
                response = {{
                    "type": "handshake.ok",
                    "protocol": "tnt.module.v1",
                    "module": {{"name": {name!r}, "version": "0.1.0"}},
                }}
                print(json.dumps(response, separators=(",", ":")), flush=True)
                {textwrap.indent(fault_program, '                ').lstrip()}
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    def write_event_fault_module(self, name: str, fault: str) -> pathlib.Path:
        if fault == "invalid":
            event_program = "print('not-json', flush=True)"
        elif fault == "crash":
            event_program = "raise SystemExit(9)"
        elif fault == "flood":
            event_program = textwrap.dedent(
                """\
                for index in range(8):
                    print(json.dumps({
                        "type": "message.create",
                        "plain_text": f"flood {index}",
                    }), flush=True)
                """
            )
        else:
            raise ValueError(f"unknown event fault: {fault}")

        module_dir = self.write_module(name)
        entrypoint = module_dir / "module.py"
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import sys

                for line in sys.stdin:
                    request = json.loads(line)
                    if request.get("type") == "handshake":
                        response = {{
                            "type": "handshake.ok",
                            "protocol": "tnt.module.v1",
                            "module": {{"name": {name!r}, "version": "0.1.0"}},
                        }}
                        print(json.dumps(response, separators=(",", ":")), flush=True)
                    elif request.get("type") == "message.created":
                        {textwrap.indent(event_program, '                        ').lstrip()}
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    def write_signal_cleanup_module(self, name: str) -> pathlib.Path:
        """Write a module with a SIGTERM-ignoring process-group child."""

        module_dir = self.write_module(name)
        entrypoint = module_dir / "module.py"
        child_program = textwrap.dedent(
            """\
            import pathlib
            import signal
            import sys
            import time

            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            pathlib.Path(sys.argv[1]).write_text("ready", encoding="ascii")
            while True:
                time.sleep(60)
            """
        )
        entrypoint.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import os
                import pathlib
                import subprocess
                import sys
                import time

                child_program = {child_program!r}
                ready_path = pathlib.Path(f"child-ready-{{os.getpid()}}")
                child = subprocess.Popen(
                    [sys.executable, "-c", child_program, str(ready_path)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                deadline = time.monotonic() + 2.0
                while not ready_path.exists():
                    if time.monotonic() >= deadline:
                        raise SystemExit(3)
                    time.sleep(0.005)
                with pathlib.Path("process-groups.txt").open(
                    "a", encoding="ascii"
                ) as process_groups:
                    process_groups.write(f"{{os.getpid()}} {{child.pid}}\\n")

                for line in sys.stdin:
                    request = json.loads(line)
                    if request.get("type") == "handshake":
                        response = {{
                            "type": "handshake.ok",
                            "protocol": "tnt.module.v1",
                            "module": {{
                                "name": {name!r},
                                "version": "0.1.0",
                            }},
                        }}
                        print(json.dumps(response, separators=(",", ":")), flush=True)
                    elif request.get("type") == "message.created":
                        print('{{"type":"message.create","plain_text":"benchmark reply"}}', flush=True)
                        print('{{"type":"event.ok"}}', flush=True)
                """
            ),
            encoding="utf-8",
        )
        entrypoint.chmod(0o755)
        return module_dir

    @staticmethod
    def process_exists(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    @staticmethod
    def process_group_exists(process_group_id: int) -> bool:
        try:
            os.killpg(process_group_id, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def run_benchmark(
        self,
        module_dir: pathlib.Path,
        report_path: pathlib.Path,
        *extra: str,
    ) -> subprocess.CompletedProcess[str]:
        return self.run_benchmarks([module_dir], report_path, *extra)

    def run_benchmarks(
        self,
        module_dirs: list[pathlib.Path],
        report_path: pathlib.Path,
        *extra: str,
    ) -> subprocess.CompletedProcess[str]:
        module_arguments: list[str] = []
        for module_dir in module_dirs:
            module_arguments.extend(["--module-dir", str(module_dir)])
        return subprocess.run(
            [
                sys.executable,
                str(BENCHMARK),
                *module_arguments,
                "--samples",
                "2",
                "--startup-samples",
                "2",
                "--startup-timeout",
                "5",
                "--warmups",
                "5",
                "--json-output",
                str(report_path),
                *extra,
            ],
            cwd=str(ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
        )

    def run_auto_discovery_benchmark(
        self,
        fixture_root: pathlib.Path,
        report_path: pathlib.Path,
    ) -> subprocess.CompletedProcess[str]:
        benchmark_copy = fixture_root / "scripts" / "benchmark_modules.py"
        benchmark_copy.parent.mkdir(parents=True)
        shutil.copy2(BENCHMARK, benchmark_copy)
        return subprocess.run(
            [
                sys.executable,
                str(benchmark_copy),
                "--samples",
                "1",
                "--startup-samples",
                "1",
                "--warmups",
                "5",
                "--json-output",
                str(report_path),
            ],
            cwd=str(fixture_root),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
        )

    def test_writes_structured_report_and_human_output(self) -> None:
        module_dir = self.write_module("fast-module")
        report_path = self.state_dir / "fast-report.json"

        completed = self.run_benchmark(module_dir, report_path)

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout={completed.stdout}\nstderr={completed.stderr}",
        )
        self.assertIn("TNT module benchmark", completed.stdout)
        self.assertIn("fast-module", completed.stdout)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["schema_version"], 1)
        self.assertIn("commit", report["metadata"])
        self.assertIn("os", report["metadata"])
        self.assertIn("python", report["metadata"])
        self.assertIn("cpu", report["metadata"])
        self.assertEqual(report["configuration"]["samples"], 2)
        self.assertEqual(report["configuration"]["startup_samples"], 2)
        self.assertEqual(report["configuration"]["warmups"], 5)
        self.assertFalse(report["configuration"]["idle_resources"]["enabled"])
        self.assertFalse(report["configuration"]["load"]["enabled"])
        self.assertEqual(report["configuration"]["load"]["topologies"], [1, 4, 8])
        self.assertEqual(
            report["configuration"]["load"]["events_per_minute"], 1_000.0
        )
        self.assertEqual(report["budgets"]["startup_p95_ms"], 150.0)
        self.assertEqual(report["budgets"]["event_output_bytes"], 32_768)
        self.assertEqual(report["budgets"]["module_idle_rss_kib"], 16_384)
        self.assertEqual(report["budgets"]["eight_module_idle_rss_kib"], 81_920)
        self.assertEqual(report["budgets"]["module_idle_cpu_percent"], 0.2)
        self.assertEqual(report["transport_limits"]["jsonl_payload_bytes"], 4_094)
        self.assertEqual(report["transport_limits"]["event_response_records"], 8)
        self.assertEqual(
            report["transport_limits"]["event_output_bytes_including_newlines"],
            32_760,
        )
        self.assertLess(
            report["transport_limits"]["event_output_bytes_including_newlines"],
            report["budgets"]["event_output_bytes"],
        )
        self.assertEqual(len(report["modules"]), 1)
        module = report["modules"][0]
        self.assertEqual(module["name"], "fast-module")
        self.assertEqual(module["workload"]["plain_text"], "/benchmark action")
        self.assertTrue(module["workload"]["expect_message_create"])
        self.assertEqual(module["startup"]["samples"], 2)
        self.assertEqual(module["event"]["samples"], 2)
        for measurement in (module["startup"], module["event"]):
            self.assertIsInstance(measurement["p50_ms"], (int, float))
            self.assertIsInstance(measurement["p95_ms"], (int, float))
            self.assertIsInstance(measurement["p99_ms"], (int, float))
            self.assertGreater(measurement["output_bytes"]["total"], 0)
            self.assertGreater(measurement["output_bytes"]["max"], 0)
        self.assertIsInstance(module["pass"], bool)
        self.assertIsInstance(report["pass"], bool)
        self.assertIsNone(report["error"])
        self.assertEqual(report["idle_resources"]["status"], "not_requested")
        self.assertEqual(report["load"]["status"], "not_requested")
        self.assertIn("transport hard limits", completed.stdout)

    def test_check_fails_for_slow_warm_events(self) -> None:
        module_dir = self.write_module("slow-module", event_delay=0.080)
        report_path = self.state_dir / "slow-report.json"

        completed = self.run_benchmark(module_dir, report_path, "--check")

        self.assertEqual(completed.returncode, 1, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertFalse(report["pass"])
        module = report["modules"][0]
        self.assertFalse(module["pass"])
        self.assertGreater(module["event"]["p95_ms"], 50.0)
        self.assertTrue(
            any(failure.startswith("event p95") for failure in module["failures"]),
            module["failures"],
        )
        self.assertIn("overall: FAIL (enforced)", completed.stdout)

    def test_fixed_rate_load_reports_one_and_four_slot_topologies(self) -> None:
        module_dir = self.write_module("load-module")
        report_path = self.state_dir / "load-report.json"

        completed = self.run_benchmark(
            module_dir,
            report_path,
            "--load",
            "--load-topologies",
            "1,4",
            "--load-events-per-minute",
            "300",
            "--load-seconds",
            "0.6",
        )

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout={completed.stdout}\nstderr={completed.stderr}",
        )
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertTrue(report["configuration"]["load"]["enabled"])
        self.assertEqual(report["configuration"]["load"]["topologies"], [1, 4])
        load = report["load"]
        self.assertEqual(load["status"], "measured")
        self.assertEqual(
            load["available_workloads"],
            [{"module": "load-module", "plain_text": "/benchmark action"}],
        )
        self.assertEqual(
            [topology["instances"] for topology in load["topologies"]],
            [1, 4],
        )
        for topology in load["topologies"]:
            self.assertEqual(topology["source_corpus"], load["available_workloads"])
            self.assertEqual(topology["offered_source_events"], 3)
            self.assertEqual(topology["completed_source_events"], 3)
            self.assertEqual(topology["dropped_source_events"], 0)
            self.assertEqual(topology["queue_capacity_per_slot"], 1)
            self.assertLessEqual(topology["queue_depth_max"], 1)
            self.assertEqual(
                topology["completed_deliveries"],
                topology["offered_deliveries"],
            )
            self.assertEqual(topology["dropped_deliveries"], 0)
            self.assertTrue(
                all(slot["offered_action_events"] == 3 for slot in topology["slots"])
            )
            self.assertAlmostEqual(
                topology["source_throughput_events_per_minute"],
                300.0,
            )
        self.assertEqual(
            [item["reused"] for item in load["topologies"][1]["assignments"]],
            [False, True, True, True],
        )
        self.assertIn("fixed-rate load: 300.000 source events/min", completed.stdout)

    def test_fixed_rate_load_detects_bounded_queue_overload(self) -> None:
        module_dir = self.write_module("overloaded-module", event_delay=0.080)
        module_spec = benchmark_module.load_module(module_dir)

        result = benchmark_module.benchmark_load(
            [module_spec],
            topologies=(1,),
            events_per_minute=1_000.0,
            duration_seconds=0.60,
            warmups=5,
            startup_timeout_seconds=5.0,
            event_timeout_seconds=2.0,
        )

        self.assertFalse(result["pass"])
        topology = result["topologies"][0]
        self.assertGreater(topology["dropped_source_events"], 0)
        self.assertGreater(topology["dropped_deliveries"], 0)
        self.assertLess(
            topology["completed_source_events"],
            topology["offered_source_events"],
        )
        self.assertTrue(
            any("completed" in failure for failure in topology["failures"]),
            topology["failures"],
        )

    def test_load_keeps_healthy_slot_running_when_peer_overloads(self) -> None:
        # Keep the semantic isolation test independent from hosted-runner
        # speed. The real-module CI profile separately enforces 1,000/min;
        # here a 300/min source and a deliberately 300-ms peer create a
        # deterministic bounded-queue overload while leaving ample room for
        # the healthy Python fixture.
        slow_dir = self.write_module(
            "slow-load-module",
            event_delay=0.300,
            workload_plain_text="/slow-load",
            respond_only_to_workload=True,
        )
        fast_dir = self.write_module(
            "fast-load-module",
            workload_plain_text="/fast-load",
            respond_only_to_workload=True,
        )
        modules = [
            benchmark_module.load_module(slow_dir),
            benchmark_module.load_module(fast_dir),
        ]

        result = benchmark_module.benchmark_load(
            modules,
            topologies=(2,),
            events_per_minute=300.0,
            duration_seconds=2.0,
            warmups=5,
            startup_timeout_seconds=5.0,
            event_timeout_seconds=2.0,
        )

        self.assertFalse(result["pass"])
        topology = result["topologies"][0]
        self.assertEqual(
            topology["source_corpus"],
            [
                {"module": "slow-load-module", "plain_text": "/slow-load"},
                {"module": "fast-load-module", "plain_text": "/fast-load"},
            ],
        )
        slow_slot, fast_slot = topology["slots"]
        self.assertGreater(slow_slot["dropped_events"], 0)
        self.assertEqual(fast_slot["offered_events"], 10)
        self.assertEqual(fast_slot["completed_events"], 10)
        self.assertEqual(fast_slot["dropped_events"], 0)
        self.assertEqual(fast_slot["offered_action_events"], 5)
        self.assertEqual(fast_slot["completed_action_events"], 5)

    def test_event_fault_corpus_rejects_invalid_crash_and_flood(self) -> None:
        cases = (
            ("invalid", "response was not valid JSON"),
            ("crash", "module exited"),
            ("flood", "event.ok not received within 8 records"),
        )
        for fault, expected_error in cases:
            with self.subTest(fault=fault):
                module_dir = self.write_event_fault_module(
                    f"{fault}-event-module", fault
                )
                report_path = self.state_dir / f"{fault}-event-report.json"

                completed = self.run_benchmark(
                    module_dir,
                    report_path,
                    "--event-timeout",
                    "0.1",
                )

                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn(expected_error, completed.stderr)
                report = json.loads(report_path.read_text(encoding="utf-8"))
                self.assertFalse(report["pass"])
                self.assertIn(expected_error, report["error"])

    def test_message_create_without_event_ok_times_out(self) -> None:
        module_dir = self.write_module("unterminated-module", terminate_event=False)
        report_path = self.state_dir / "unterminated-report.json"

        completed = self.run_benchmark(
            module_dir,
            report_path,
            "--event-timeout",
            "0.05",
        )

        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("timed out waiting for a JSONL response", completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["schema_version"], 1)
        self.assertIn("generated_at_utc", report["metadata"])
        self.assertEqual(report["configuration"]["event_timeout_seconds"], 0.05)
        self.assertEqual(report["budgets"]["event_output_bytes"], 32_768)
        self.assertEqual(report["modules"], [])
        self.assertIn("timed out waiting for a JSONL response", report["error"])
        self.assertFalse(report["pass"])

    def test_error_report_keeps_completed_module_results(self) -> None:
        fast_module = self.write_module("first-fast-module")
        unterminated_module = self.write_module(
            "second-unterminated-module",
            terminate_event=False,
        )
        report_path = self.state_dir / "partial-report.json"

        completed = self.run_benchmarks(
            [fast_module, unterminated_module],
            report_path,
            "--event-timeout",
            "0.05",
        )

        self.assertEqual(completed.returncode, 2, completed.stdout)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(
            [module["name"] for module in report["modules"]],
            ["first-fast-module"],
        )
        self.assertEqual(report["modules"][0]["startup"]["samples"], 2)
        self.assertEqual(report["modules"][0]["event"]["samples"], 2)
        self.assertIn("second-unterminated-module", report["error"])
        self.assertFalse(report["pass"])

    def test_auto_discovery_requires_explicit_message_create_expectation(self) -> None:
        for label, expectation in (("missing", None), ("false", False)):
            with self.subTest(expect_message_create=label):
                fixture_root = self.state_dir / f"auto-{label}"
                self.write_module(
                    f"auto-{label}-module",
                    benchmark_expect_message_create=expectation,
                    module_root=fixture_root / "modules",
                )
                report_path = self.state_dir / f"auto-{label}-report.json"

                completed = self.run_auto_discovery_benchmark(
                    fixture_root,
                    report_path,
                )

                self.assertEqual(completed.returncode, 2, completed.stdout)
                report = json.loads(report_path.read_text(encoding="utf-8"))
                self.assertEqual(report["schema_version"], 1)
                self.assertEqual(report["modules"], [])
                self.assertIn(
                    "benchmark.expect_message_create must be explicitly true",
                    report["error"],
                )
                self.assertFalse(report["pass"])

    def test_explicit_module_directory_allows_optional_expectation(self) -> None:
        for label, expectation in (("missing", None), ("false", False)):
            with self.subTest(expect_message_create=label):
                module_dir = self.write_module(
                    f"explicit-{label}-module",
                    benchmark_expect_message_create=expectation,
                )
                report_path = self.state_dir / f"explicit-{label}-report.json"

                completed = self.run_benchmark(module_dir, report_path)

                self.assertEqual(completed.returncode, 0, completed.stderr)
                report = json.loads(report_path.read_text(encoding="utf-8"))
                self.assertFalse(
                    report["modules"][0]["workload"]["expect_message_create"]
                )

    def test_close_kills_child_when_module_leader_already_exited(self) -> None:
        module_dir = self.write_child_leaking_module("child-leaking-module")
        module_spec = benchmark_module.load_module(module_dir)
        running = benchmark_module.RunningModule(module_spec)
        child_pid: int | None = None

        try:
            running.__enter__()
            benchmark_module.perform_handshake(running, module_spec, 2.0)
            assert running.process is not None
            running.process.wait(timeout=2.0)
            child_pid = int(
                (module_dir / "child.pid").read_text(encoding="ascii")
            )
            self.assertTrue(self.process_exists(child_pid))

            running.close()

            deadline = time.monotonic() + 2.0
            while self.process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(
                self.process_exists(child_pid),
                f"module child {child_pid} survived process-group cleanup",
            )
        finally:
            running.close()
            if child_pid is not None and self.process_exists(child_pid):
                try:
                    os.kill(child_pid, 9)
                except ProcessLookupError:
                    pass

    def test_interrupt_signal_handlers_raise_once_and_restore(self) -> None:
        managed_signals = tuple(
            signum
            for signal_name in ("SIGHUP", "SIGINT", "SIGTERM")
            if (signum := getattr(signal, signal_name, None)) is not None
        )
        original_handlers = {
            signum: signal.getsignal(signum) for signum in managed_signals
        }
        installed_handler = None

        with self.assertRaises(benchmark_module.BenchmarkInterrupted) as interrupted:
            with benchmark_module.temporary_interrupt_signal_handlers():
                installed_handler = signal.getsignal(signal.SIGINT)
                self.assertTrue(callable(installed_handler))
                installed_handler(signal.SIGINT, None)

        self.assertEqual(interrupted.exception.signum, signal.SIGINT)
        self.assertIsNotNone(installed_handler)
        # A second signal must not abort process-group cleanup or handler
        # restoration after the first interruption has begun unwinding.
        self.assertIsNone(installed_handler(signal.SIGTERM, None))
        for signum, original_handler in original_handlers.items():
            self.assertEqual(signal.getsignal(signum), original_handler)

        with self.assertRaisesRegex(RuntimeError, "body failure"):
            with benchmark_module.temporary_interrupt_signal_handlers():
                raise RuntimeError("body failure")
        for signum, original_handler in original_handlers.items():
            self.assertEqual(signal.getsignal(signum), original_handler)

    def test_sigterm_during_idle_resources_cleans_process_group(self) -> None:
        module_dir = self.write_signal_cleanup_module("signal-cleanup-module")
        report_path = self.state_dir / "signal-cleanup-report.json"
        process_groups_path = module_dir / "process-groups.txt"
        process = subprocess.Popen(
            [
                sys.executable,
                str(BENCHMARK),
                "--module-dir",
                str(module_dir),
                "--samples",
                "1",
                "--startup-samples",
                "1",
                "--warmups",
                "5",
                "--idle-resources",
                "--idle-instances",
                "1",
                "--idle-settle",
                "0",
                "--idle-seconds",
                "30",
                "--resource-sample-interval",
                "0.05",
                "--json-output",
                str(report_path),
            ],
            cwd=str(ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        idle_process_group: int | None = None

        try:
            launch_deadline = time.monotonic() + 8.0
            launches: list[list[int]] = []
            while time.monotonic() < launch_deadline:
                if process_groups_path.exists():
                    launches = [
                        [int(value) for value in line.split()]
                        for line in process_groups_path.read_text(
                            encoding="ascii"
                        ).splitlines()
                        if line.strip()
                    ]
                if len(launches) >= 3:
                    break
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(
                        "benchmark exited before idle fixture started: "
                        f"status={process.returncode}, stdout={stdout!r}, "
                        f"stderr={stderr!r}"
                    )
                time.sleep(0.01)
            self.assertGreaterEqual(len(launches), 3)
            idle_process_group, idle_child = launches[-1]
            self.assertTrue(self.process_group_exists(idle_process_group))
            self.assertTrue(self.process_exists(idle_child))

            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=6.0)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
            self.assertEqual(stdout, "")
            self.assertIn("interrupted by SIGTERM", stderr)

            cleanup_deadline = time.monotonic() + 3.0
            while (
                self.process_group_exists(idle_process_group)
                and time.monotonic() < cleanup_deadline
            ):
                time.sleep(0.01)
            self.assertFalse(
                self.process_group_exists(idle_process_group),
                f"module process group {idle_process_group} survived SIGTERM cleanup",
            )

            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertFalse(report["pass"])
            self.assertEqual(report["error"], "interrupted by SIGTERM")
            self.assertEqual(report["idle_resources"]["status"], "error")
            self.assertFalse(report["idle_resources"]["pass"])
            self.assertEqual(
                report["idle_resources"]["error"], "interrupted by SIGTERM"
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if process_groups_path.exists():
                for line in process_groups_path.read_text(
                    encoding="ascii"
                ).splitlines():
                    values = line.split()
                    if not values:
                        continue
                    process_group = int(values[0])
                    if self.process_group_exists(process_group):
                        try:
                            os.killpg(process_group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_sigterm_during_load_cleans_process_group(self) -> None:
        module_dir = self.write_signal_cleanup_module("load-signal-cleanup-module")
        report_path = self.state_dir / "load-signal-cleanup-report.json"
        process_groups_path = module_dir / "process-groups.txt"
        process = subprocess.Popen(
            [
                sys.executable,
                str(BENCHMARK),
                "--module-dir",
                str(module_dir),
                "--samples",
                "1",
                "--startup-samples",
                "1",
                "--warmups",
                "5",
                "--load",
                "--load-topologies",
                "1",
                "--load-seconds",
                "30",
                "--json-output",
                str(report_path),
            ],
            cwd=str(ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        load_process_group: int | None = None

        try:
            launch_deadline = time.monotonic() + 8.0
            launches: list[list[int]] = []
            while time.monotonic() < launch_deadline:
                if process_groups_path.exists():
                    launches = [
                        [int(value) for value in line.split()]
                        for line in process_groups_path.read_text(
                            encoding="ascii"
                        ).splitlines()
                        if line.strip()
                    ]
                if len(launches) >= 3:
                    break
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(
                        "benchmark exited before load fixture started: "
                        f"status={process.returncode}, stdout={stdout!r}, "
                        f"stderr={stderr!r}"
                    )
                time.sleep(0.01)
            self.assertGreaterEqual(len(launches), 3)
            load_process_group, load_child = launches[-1]
            self.assertTrue(self.process_group_exists(load_process_group))
            self.assertTrue(self.process_exists(load_child))

            # Let handshake, warmups, and the first scheduled load events begin.
            time.sleep(0.25)
            self.assertIsNone(process.poll())
            process.send_signal(signal.SIGTERM)
            _stdout, stderr = process.communicate(timeout=6.0)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
            self.assertIn("interrupted by SIGTERM", stderr)

            cleanup_deadline = time.monotonic() + 3.0
            while (
                self.process_group_exists(load_process_group)
                and time.monotonic() < cleanup_deadline
            ):
                time.sleep(0.01)
            self.assertFalse(
                self.process_group_exists(load_process_group),
                f"module process group {load_process_group} survived SIGTERM cleanup",
            )

            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertFalse(report["pass"])
            self.assertEqual(report["error"], "interrupted by SIGTERM")
            self.assertEqual(report["load"]["status"], "error")
            self.assertFalse(report["load"]["pass"])
            self.assertEqual(report["load"]["error"], "interrupted by SIGTERM")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if process_groups_path.exists():
                for line in process_groups_path.read_text(
                    encoding="ascii"
                ).splitlines():
                    values = line.split()
                    if not values:
                        continue
                    process_group = int(values[0])
                    if self.process_group_exists(process_group):
                        try:
                            os.killpg(process_group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_process_group_cleanup_tolerates_esrch_and_eperm(self) -> None:
        cases = (
            (OSError(errno.ESRCH, "missing group"), False),
            (OSError(errno.EPERM, "inaccessible group"), True),
        )
        for error, exists in cases:
            with self.subTest(errno=error.errno):
                with mock.patch.object(os, "killpg", side_effect=error):
                    self.assertFalse(
                        benchmark_module.RunningModule._signal_process_group(
                            12345, 15
                        )
                    )
                    self.assertEqual(
                        benchmark_module.RunningModule._process_group_exists(12345),
                        exists,
                    )

    def test_idle_resources_reports_eight_quiet_rotating_slots(self) -> None:
        module_dir = self.write_shell_module("quiet-module")
        report_path = self.state_dir / "quiet-resources.json"

        completed = self.run_benchmark(
            module_dir,
            report_path,
            "--idle-resources",
            "--idle-instances",
            "8",
            "--idle-settle",
            "0.02",
            "--idle-seconds",
            "0.2",
            "--resource-sample-interval",
            "0.05",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        resources = report["idle_resources"]
        self.assertEqual(resources["status"], "measured")
        self.assertIn(resources["backend"], {"linux-procfs", "darwin-ps"})
        self.assertEqual(len(resources["assignments"]), 8)
        self.assertFalse(resources["assignments"][0]["reused"])
        self.assertTrue(
            all(item["reused"] for item in resources["assignments"][1:])
        )
        self.assertEqual(len(resources["slots"]), 8)
        self.assertTrue(all(slot["pass"] for slot in resources["slots"]))
        self.assertTrue(
            all(slot["process_count_peak"] >= 1 for slot in resources["slots"])
        )
        self.assertTrue(
            resources["aggregate"]["eight_module_rss_budget_applicable"]
        )
        self.assertTrue(resources["pass"])
        self.assertIn("idle resources: 8 slots", completed.stdout)

    def test_idle_resource_gate_counts_large_child_rss(self) -> None:
        module_dir = self.write_resource_child_module("large-child-module", "rss")
        report_path = self.state_dir / "large-child-resources.json"

        completed = self.run_benchmark(
            module_dir,
            report_path,
            "--idle-resources",
            "--idle-instances",
            "1",
            "--idle-settle",
            "0.02",
            "--idle-seconds",
            "0.2",
            "--resource-sample-interval",
            "0.05",
            "--check",
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        resources = json.loads(report_path.read_text(encoding="utf-8"))[
            "idle_resources"
        ]
        slot = resources["slots"][0]
        self.assertGreater(slot["rss_kib"]["max"], 16_384)
        self.assertGreaterEqual(slot["process_count_peak"], 2)
        self.assertFalse(slot["pass"])
        self.assertTrue(any("idle RSS" in item for item in slot["failures"]))
        self.assertFalse(resources["pass"])

    def test_idle_resource_gate_counts_busy_child_cpu(self) -> None:
        module_dir = self.write_resource_child_module("busy-child-module", "cpu")
        report_path = self.state_dir / "busy-child-resources.json"

        completed = self.run_benchmark(
            module_dir,
            report_path,
            "--idle-resources",
            "--idle-instances",
            "1",
            "--idle-settle",
            "0.02",
            "--idle-seconds",
            "0.3",
            "--resource-sample-interval",
            "0.05",
            "--check",
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        resources = json.loads(report_path.read_text(encoding="utf-8"))[
            "idle_resources"
        ]
        slot = resources["slots"][0]
        self.assertGreater(slot["one_core_percent"], 0.2)
        self.assertGreaterEqual(slot["process_count_peak"], 2)
        self.assertFalse(slot["pass"])
        self.assertTrue(any("idle CPU" in item for item in slot["failures"]))

    def test_idle_resource_backend_failure_is_not_a_silent_pass(self) -> None:
        module_dir = self.write_shell_module("backend-error-module")
        report_path = self.state_dir / "backend-error.json"
        stdout = io.StringIO()
        stderr = io.StringIO()

        with mock.patch.object(
            benchmark_module,
            "select_resource_sampler",
            side_effect=benchmark_module.BenchmarkError("backend unavailable"),
        ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = benchmark_module.run(
                [
                    "--module-dir",
                    str(module_dir),
                    "--samples",
                    "1",
                    "--startup-samples",
                    "1",
                    "--warmups",
                    "5",
                    "--idle-resources",
                    "--idle-instances",
                    "1",
                    "--idle-seconds",
                    "0.1",
                    "--resource-sample-interval",
                    "0.05",
                    "--json-output",
                    str(report_path),
                    "--check",
                ]
            )

        self.assertEqual(result, 2)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertFalse(report["pass"])
        self.assertEqual(report["idle_resources"]["status"], "error")
        self.assertIn("backend unavailable", report["idle_resources"]["error"])
        self.assertIn("backend unavailable", report["error"])
        self.assertIn("backend unavailable", stderr.getvalue())

    def test_idle_resource_sampling_rejects_output_and_leader_exit(self) -> None:
        cases = (
            ("unsolicited", "unsolicited idle output"),
            ("leader-exit", "module leader exited while idle"),
        )
        for fault, expected_error in cases:
            with self.subTest(fault=fault):
                module_dir = self.write_idle_fault_module(
                    f"{fault}-module", fault
                )
                module_spec = benchmark_module.load_module(module_dir)
                with self.assertRaisesRegex(
                    benchmark_module.BenchmarkError, expected_error
                ):
                    benchmark_module.benchmark_idle_resources(
                        [module_spec],
                        instances=1,
                        settle_seconds=0.1,
                        duration_seconds=0.1,
                        sample_interval_seconds=0.02,
                        startup_timeout_seconds=2.0,
                    )

    def test_resource_backend_parsers_and_unsupported_platform(self) -> None:
        self.assertAlmostEqual(benchmark_module.parse_ps_cpu_seconds("1:02.50"), 62.5)
        self.assertAlmostEqual(
            benchmark_module.parse_ps_cpu_seconds("1-02:03:04.25"),
            93_784.25,
        )

        proc_root = self.state_dir / "proc"
        process_dir = proc_root / "123"
        process_dir.mkdir(parents=True)
        stat_fields = [
            "S",
            "1",
            "42",
            "42",
            "0",
            "0",
            "0",
            "0",
            "0",
            "0",
            "0",
            "100",
            "50",
        ]
        (process_dir / "stat").write_text(
            f"123 (worker name) {' '.join(stat_fields)}\n", encoding="utf-8"
        )
        (process_dir / "status").write_text("VmRSS:\t2048 kB\n", encoding="utf-8")
        sampler = benchmark_module.LinuxProcResourceSampler(proc_root)
        samples = sampler.snapshot({42})[42]
        self.assertEqual(len(samples), 1)
        self.assertEqual(samples[0].pid, 123)
        self.assertEqual(samples[0].rss_kib, 2048)
        self.assertAlmostEqual(
            samples[0].cpu_seconds, 150 / sampler.clock_ticks
        )

        with self.assertRaisesRegex(
            benchmark_module.BenchmarkError, "not supported"
        ):
            benchmark_module.select_resource_sampler("unsupported-os")

    def test_idle_resource_cli_rejects_invalid_windows_and_counts(self) -> None:
        invalid_arguments = (
            ("--idle-instances", "0"),
            ("--idle-instances", "9"),
            ("--idle-settle", "-0.1"),
            ("--idle-seconds", "0"),
            ("--resource-sample-interval", "0"),
            ("--load-topologies", "0,4"),
            ("--load-topologies", "1,1"),
            ("--load-events-per-minute", "0"),
            ("--load-seconds", "0"),
        )
        for option, value in invalid_arguments:
            with self.subTest(option=option, value=value):
                completed = subprocess.run(
                    [sys.executable, str(BENCHMARK), option, value],
                    cwd=str(ROOT),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(completed.returncode, 2)
                self.assertIn("error:", completed.stderr)


if __name__ == "__main__":
    unittest.main()
