.PHONY: lint format dockertest

format:
	@swiftformat --swiftversion 6.0 --indent 2 ./

lint:
	@git ls-files --exclude-standard | grep -E '\.swift$$' | swiftlint --fix --autocorrect

dockertest:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test
