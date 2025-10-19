.PHONY: lint format test dockertest test-debug dockertest-debug

format:
	@swiftformat --swiftversion 6.0 --indent 2 ./

lint:
	@git ls-files --exclude-standard | grep -E '\.swift$$' | swiftlint --fix --autocorrect

test:
	swift test -c release --no-parallel $(filter-out $@,$(MAKECMDGOALS))

test-debug:
	swift test -c debug --no-parallel $(filter-out $@,$(MAKECMDGOALS))

dockertest:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test -c release --no-parallel $(filter-out $@,$(MAKECMDGOALS))

dockertest-debug:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test -c debug --no-parallel $(filter-out $@,$(MAKECMDGOALS))
