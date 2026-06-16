.PHONY: test check

test:
	@tests/test_check_modules.sh

check: test
