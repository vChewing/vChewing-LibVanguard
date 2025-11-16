.PHONY: lint format test dockertest test-debug dockertest-debug

format:
	@swiftformat --swiftversion 6.0 --indent 2 ./

lint:
	@echo "Running SwiftLint on tracked Swift files..."
	@files="$$(git ls-files -- '*.swift' ':!Build/**' ':!Packages/Build/**' ':!Packages/**/.build/')"; \
	if [ -z "$$files" ]; then \
		echo "No Swift files tracked by git."; \
	else \
		printf '%s\n' "$$files" | tr '\n' '\0' | \
		xargs -0 swiftlint lint --fix --autocorrect --config .swiftlint.yml --; \
	fi

test:
	swift test -c release --no-parallel $(filter-out $@,$(MAKECMDGOALS))

test-debug:
	swift test -c debug --no-parallel $(filter-out $@,$(MAKECMDGOALS))

dockertest:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test -c release --no-parallel $(filter-out $@,$(MAKECMDGOALS))

dockertest-debug:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test -c debug --no-parallel $(filter-out $@,$(MAKECMDGOALS))
