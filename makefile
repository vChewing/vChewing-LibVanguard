# Pin LC_ALL so CJK collation stays identical regardless of the machine's locale settings.
.PHONY: lint format lintFormat lintFormatUncommitted spmClean test dockertest test-debug dockertest-debug

# 清建置快取。本倉為倉根套件（聚合體），其巢狀子套件另置於 `Deps/` 之下——
# 僅在「直接對子套件建置」時才會生成獨立 .build，故須一併清掃，否則殘留物件
# 會在下一次建置造成 `Undefined symbols` 之假失敗。
spmClean:
	swift package clean
	@for nestedDep in ./Deps/*; do \
		if [ -f "$$nestedDep/Package.swift" ]; then \
			echo "processing nested dep $$nestedDep"; \
			swift package clean --package-path "$$nestedDep" || true; \
		fi; \
	done;

format:
	@export LC_ALL=C; swiftformat --swiftversion 6.0 --indent 2 ./

lint:
	@export LC_ALL=C; \
	echo "Running SwiftLint on tracked Swift files..."; \
	files="$$(git ls-files -- '*.swift' ':!Build/**' ':!Packages/Build/**' ':!Packages/**/.build/')"; \
	if [ -z "$$files" ]; then \
		echo "No Swift files tracked by git."; \
	else \
		printf '%s\n' "$$files" | tr '\n' '\0' | \
		xargs -0 swiftlint lint --fix --autocorrect --config .swiftlint.yml --; \
	fi

lintFormat: lint format

lintFormatUncommitted:
	@export LC_ALL=C; \
	echo "Running SwiftFormat & SwiftLint on uncommitted tracked Swift files..."; \
	files="$$(git diff --name-only HEAD -- '*.swift' ':!Build/**' ':!Packages/Build/**' ':!Packages/**/.build/' | while IFS= read -r f; do [ -f "$$f" ] && printf '%s\n' "$$f"; done)"; \
	if [ -z "$$files" ]; then \
		echo "No uncommitted Swift files tracked by git."; \
	else \
		printf '%s\n' "$$files" | tr '\n' '\0' | xargs -0 swiftlint lint --fix --autocorrect --config .swiftlint.yml --; \
		printf '%s\n' "$$files" | tr '\n' '\0' | xargs -0 swiftformat --swiftversion 6.0 --indent 2; \
	fi

test:
	swift test -c release --no-parallel $(filter-out $@,$(MAKECMDGOALS))

test-debug:
	swift test -c debug --no-parallel $(filter-out $@,$(MAKECMDGOALS))

dockertest:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test -c release --no-parallel $(filter-out $@,$(MAKECMDGOALS))

dockertest-debug:
	docker run --rm -v "$(shell pwd)":/workspace -w /workspace swift:latest swift test -c debug --no-parallel $(filter-out $@,$(MAKECMDGOALS))
