.PHONY: test check check-modules perf perf-load perf-resources perf-check

PYTHON ?= python3
PERF_ARGS ?=

test: check-modules
	@tests/test_check_modules.sh
	@tests/test_modules_behavior.sh
	@$(PYTHON) tests/test_benchmark_modules.py

check-modules:
	@scripts/sync_module_json.sh --check
	@scripts/check_modules.sh

perf:
	@$(PYTHON) scripts/benchmark_modules.py $(PERF_ARGS)

perf-load:
	@$(PYTHON) scripts/benchmark_modules.py --load $(PERF_ARGS)

perf-resources:
	@$(PYTHON) scripts/benchmark_modules.py --idle-resources $(PERF_ARGS)

perf-check:
	@$(PYTHON) scripts/benchmark_modules.py --check $(PERF_ARGS)

check: test
