.PHONY: test check release-check check-modules core-check core-integration \
	perf perf-load perf-resources perf-check man-check install install-man \
	install-modules uninstall uninstall-man uninstall-modules

PYTHON ?= python3
PERF_ARGS ?=
TNT_ROOT ?= ../TNT
PREFIX ?= /usr/local
MANDIR ?= $(PREFIX)/share/man
LIBEXECDIR ?= $(PREFIX)/libexec
MODULEDIR ?= $(LIBEXECDIR)/tnt/modules
INSTALL ?= install
MANPAGE = tnt-modules.7
MODULES = 8ball-module choose-module flip-module quote-module roll-module

test: check-modules
	@tests/test_check_modules.sh
	@tests/test_modules_behavior.sh
	@$(PYTHON) tests/test_benchmark_modules.py

release-check:
	@scripts/release_check.sh

man-check:
	@set -e; \
	markdown=$$(find . -type f -name '*.md' -not -path './.git/*' -print); \
	[ -z "$$markdown" ] || { printf '%s\n' "$$markdown" >&2; exit 1; }; \
	awk 'length($$0) > 80 { print FNR ":" length($$0); bad = 1 } \
		END { exit bad }' $(MANPAGE); \
	! grep -n -E '^\.(TS|TE|nf|fi)([[:space:]]|$$)' $(MANPAGE); \
	! grep -n -E '([[:alnum:]_./-]+\.md|docs/)' $(MANPAGE); \
	if command -v mandoc >/dev/null 2>&1; then \
		mandoc -Tlint $(MANPAGE); \
		test -n "$$(mandoc -Tascii $(MANPAGE))"; \
	elif command -v groff >/dev/null 2>&1; then \
		groff -man -z -ww $(MANPAGE); \
		test -n "$$(groff -man -Tascii $(MANPAGE))"; \
	else \
		echo "man-check: mandoc or groff is required" >&2; \
		exit 1; \
	fi

install: install-modules install-man

install-modules:
	@set -e; \
	for module in $(MODULES); do \
		dir="$(DESTDIR)$(MODULEDIR)/$$module"; \
		$(INSTALL) -d "$$dir"; \
		$(INSTALL) -m 0644 "modules/$$module/module_json.awk" "$$dir/"; \
		$(INSTALL) -m 0644 "modules/$$module/$$module.awk" "$$dir/"; \
		$(INSTALL) -m 0644 "modules/$$module/tnt-module.json" "$$dir/"; \
		$(INSTALL) -m 0755 "modules/$$module/$$module.sh" "$$dir/"; \
	done

install-man: $(MANPAGE)
	$(INSTALL) -d "$(DESTDIR)$(MANDIR)/man7"
	$(INSTALL) -m 0644 $(MANPAGE) \
		"$(DESTDIR)$(MANDIR)/man7/$(MANPAGE)"

uninstall: uninstall-modules uninstall-man

uninstall-modules:
	@set -e; \
	for module in $(MODULES); do \
		dir="$(DESTDIR)$(MODULEDIR)/$$module"; \
		$(RM) "$$dir/module_json.awk" "$$dir/$$module.awk"; \
		$(RM) "$$dir/tnt-module.json"; \
		$(RM) "$$dir/$$module.sh"; \
		rmdir "$$dir" 2>/dev/null || true; \
	done; \
	rmdir "$(DESTDIR)$(MODULEDIR)" 2>/dev/null || true

uninstall-man:
	$(RM) "$(DESTDIR)$(MANDIR)/man7/$(MANPAGE)"

check-modules:
	@scripts/sync_module_json.sh --check
	@scripts/check_modules.sh

core-check:
	@scripts/sync_module_json.sh --check
	@scripts/check_modules.sh --checker "$(TNT_ROOT)/scripts/module_check.sh"

core-integration:
	@TNT_ROOT="$(TNT_ROOT)" tests/test_tnt_runtime.sh

perf:
	@$(PYTHON) scripts/benchmark_modules.py $(PERF_ARGS)

perf-load:
	@$(PYTHON) scripts/benchmark_modules.py --load $(PERF_ARGS)

perf-resources:
	@$(PYTHON) scripts/benchmark_modules.py --idle-resources $(PERF_ARGS)

perf-check:
	@$(PYTHON) scripts/benchmark_modules.py --check $(PERF_ARGS)

check: test
