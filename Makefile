.PHONY: test check

test:
	@tests/test_check_modules.sh
	@tests/test_modules_behavior.sh

check: test
