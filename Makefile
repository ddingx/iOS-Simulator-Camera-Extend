# SimCam — Makefile
#
# 推荐入口（命令行）：
#
#   make bootstrap-cert     # 一次性：生成本地 self-signed 证书 SimCam Local Dev
#   make build              # xcodebuild Debug
#   make install            # 重签 + 拷到 /Applications/（需要 sudo）
#   make run                # build + install + open
#   make doctor             # 诊断 sysext / 签名 / SIP / TCC
#   make reset-tcc          # 一次性：清理旧 cdhash 留下的 TCC 失忆条目
#
# Code signing
# ------------
# 不用 Apple Developer Program，也不用 Personal Team。
# 用本地自签名 CA (CN=SimCam Local Dev)，原因和原理见 docs/signing-and-tcc.md。
# 第一次 clone 后只需要 `make bootstrap-cert` 一下。

PROJECT      := SimCam.xcodeproj
SCHEME       := SimCam
CONFIG       ?= Debug
DESTINATION  ?= platform=macOS
IDENTITY     := SimCam Local Dev

.PHONY: all bootstrap-cert build test run install open clean derived doctor reset-tcc

all: build

# ---- 一次性：生成 / 导入本地 self-signed code-signing 证书 -----------------
bootstrap-cert:
	./scripts/bootstrap-cert.sh

# ---- 构建（命令行 build；日常推荐 Xcode ⌘B）-------------------------------
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' build

# ---- Unit tests -----------------------------------------------------------
test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' test

# ---- 解析 DerivedData 里的 BUILT_PRODUCTS_DIR -----------------------------
derived:
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $$3; exit}'

# ---- 重签 + 拷到 /Applications/ (sysextd 硬约束) --------------------------
install: build
	@echo "==> Verifying '$(IDENTITY)' is in login keychain"
	@security find-identity -v -p codesigning login.keychain-db 2>/dev/null | grep -q "$(IDENTITY)" \
		|| security find-identity -v -p codesigning           | grep -q "$(IDENTITY)" \
		|| { echo "❌ '$(IDENTITY)' not found. Run: make bootstrap-cert"; exit 1; }
	sudo ./scripts/install-systemext.sh

# ---- build + install + open（一条龙）-------------------------------------
run: install
	open /Applications/SimCamApp.app

# ---- 直接打开 Xcode 工程 --------------------------------------------------
open:
	open $(PROJECT)

# ---- 诊断：SIP / sysext / 签名 / sysextd 日志 -----------------------------
doctor:
	./scripts/diagnose-sysext.sh

# ---- 清空 TCC（仅在切签名身份后执行一次）----------------------------------
reset-tcc:
	./scripts/reset-tcc.sh

clean:
	rm -rf build DerivedData
