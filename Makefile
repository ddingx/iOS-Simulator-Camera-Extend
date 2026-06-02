# SimCam — Makefile（薄封装；这是一个 Xcode 工程，主要还是 ⌘R / ⌘U）

PROJECT      := SimCam.xcodeproj
SCHEME       := SimCam
CONFIG       ?= Debug
DESTINATION  ?= platform=macOS
DERIVED      := $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $$3; exit}')

.PHONY: all generate build test run open clean

all: build

# 1) 生成 .xcodeproj
generate:
	xcodegen generate --spec project.yml

# 2) 构建（App + Camera Extension）
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' build CODE_SIGNING_ALLOWED=NO

# 3) 跑 unit tests
test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' test CODE_SIGNING_ALLOWED=NO

# 4) 启动 menubar app
run: build
	open "$(DERIVED)/SimCamApp.app"

# 5) 直接打开 Xcode 工程
open: generate
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) Generated build DerivedData
