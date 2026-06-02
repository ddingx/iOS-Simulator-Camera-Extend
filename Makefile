# SimCam — Makefile（薄封装；这是一个 Xcode 工程，主要还是 ⌘R / ⌘U）

PROJECT      := SimCam.xcodeproj
SCHEME       := SimCam
CONFIG       ?= Debug
DESTINATION  ?= platform=macOS

.PHONY: all generate build test run open clean reset-tcc derived

all: build

# 1) 生成 .xcodeproj
generate:
	xcodegen generate --spec project.yml

# 2) 构建（App + Camera Extension）
#    Signing is controlled by Configs/SimCamSigning.xcconfig + the local
#    override in Configs/SimCamSigning.local.xcconfig (gitignored). Do NOT
#    pass CODE_SIGNING_ALLOWED=NO here — that disables the Personal Team
#    signing path that TCC needs to remember permission grants.
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' build

# 3) 跑 unit tests
test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' test

# 4) 启动 menubar app
#    DERIVED is queried lazily so `make clean` / `make generate` don't trigger
#    an extra `xcodebuild -showBuildSettings` round-trip.
derived:
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $$3; exit}'

run: build
	@DERIVED="$$($(MAKE) -s derived)"; \
	  test -n "$$DERIVED" || { echo "could not resolve BUILT_PRODUCTS_DIR; run make build first"; exit 1; }; \
	  open "$$DERIVED/SimCamApp.app"

# 5) 直接打开 Xcode 工程
open: generate
	open $(PROJECT)

# 6) 清掉旧 ad-hoc 留下的 TCC 残留 + 旧 SimCamApp.app（一站式重置权限）
reset-tcc:
	./scripts/reset-tcc.sh

clean:
	rm -rf $(PROJECT) Generated build DerivedData
