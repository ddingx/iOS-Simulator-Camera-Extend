# Signing & TCC — why SimCam uses a self-signed code-signing cert

> Last updated: 2026-06-03 — written after one full day of debugging
> "扩展跑不进 system extensions" + "TCC 每次重 build 都要重新授权".
> If you are about to "clean up" this signing setup, read this first.
> 大概率你会浪费一天时间得到我们已经得到过的结论。

## TL;DR

SimCam 的 host app 和 CMIO Camera Extension 都被签名锁到一张
**self-signed code-signing 证书**，CN = `SimCam Local Dev`。每个开发者
在自己机器上用 `scripts/bootstrap-cert.sh` 一次性生成；证书不入仓。

不能用：

* Apple Development（Personal Team） —— Apple 不给 Personal Team 颁
  System Extension capability，profile 申请会直接报错
  *"Personal development teams ... do not support the System Extension
  capability"*。
* 纯 ad-hoc 签名（`codesign --sign -`） —— 能装上 system extension，
  但 TCC 用 cdhash 锁 designated requirement，每次 rebuild cdhash 一变，
  Camera / Screen Recording / Microphone 授权全部失效，需要在系统设置里
  手动删了重批，开发体验崩。
* Apple Developer Program (Developer ID) —— 这是工业最优解，但需要
  $99/年，且 SimCam 是开源项目，没法把私钥入仓共享。

能用，且我们选择的：

* **self-signed certificate**，CN = `SimCam Local Dev`，每个开发者
  本地 keychain 一份。codesign 用 CN 签，TCC designated requirement 锁
  到 CN（而不是 cdhash），所以**重 build cdhash 怎么变都不影响授权记忆**。

---

## 1. 这个项目的签名约束有多刁钻

System Extension 的激活路径有三个独立校验门：

1. **host app 必须带 `com.apple.developer.system-extension.install`
   entitlement** —— 否则 `OSSystemExtensionRequest` 提交时会被 host 自己
   的 codesign 校验挡掉，sysextd 日志里**完全看不到**任何 `Submitting`
   事件。这是今天 (2026-06-03) 的事故根因之一。
2. **`.systemextension` bundle 必须满足 sysextd 的若干硬约束**：bundle
   id 是 host 的前缀（`dev.simcam.app.extension`）、文件名（去后缀）
   等于 bundle id、`.app` 必须落在 `/Applications/` 下且 owner 是
   `root:wheel`、host 的 `application-groups` 与 extension 一致。Apple
   DTS forums/thread/823200 反复确认这些规则，错一项就是 *"no policy,
   cannot allow apps outside /Applications"* 这种误导性错误。
3. **签名 anchor**：sysextd 必须能验证 host & extension 的代码签名 ——
   要么是 Apple anchor (Developer ID / Apple Development)，要么开发者
   模式打开（`sudo systemextensionsctl developer on`）下接受任意签名。

而 TCC 又有一条独立约束：

4. **TCC 数据库是按 designated requirement 索引的**。同一个 bundle id，
   只要 codesign 出来的 DR 字符串变了，TCC 就当成另一个 app 处理。

| 签名方式 | DR 内容 | rebuild 后 DR 是否稳定 |
| --- | --- | --- |
| Apple Developer ID | `... certificate leaf[subject.OU] = "<TeamID>"` | 是（锁 team） |
| Apple Development | 类似上 | 是 |
| **self-signed CA**（我们的方案） | `identifier "..." and certificate leaf[subject.CN] = "SimCam Local Dev"` | 是（锁 CN） |
| **ad-hoc** (`-`) | `... certificate leaf = H"<cdhash>"` | 否 — 每次 build 都变 |

参考：

* https://developer.apple.com/forums/thread/819406 (Quinn on TCC + ad-hoc)
* https://developer.apple.com/forums/thread/678816
* https://developer.apple.com/forums/thread/823200 (sysextd 路径误判)
* `man csreq`、`man codesign --display --requirements`

## 2. 为什么不直接走 Apple Developer Program

* SimCam 是开源项目，团队私钥不能入仓，必须每个 maintainer 各自申请，
  但 System Extension capability 又要求账号付费 ($99/年) 才能勾，门槛
  不友好。
* Personal Team 不支持 System Extension capability —— 见今天 Xcode
  截图 *"Cannot create a Mac App Development provisioning profile for
  'dev.simcam.app'. Personal development teams, including 'Asher Guo',
  do not support the System Extension capability."*

如果未来真要做正式发行版，应当切到 Developer ID + notarization；但开
发与 CI 流程仍然推荐保留 self-signed 路径。

## 3. self-signed 路径的工作原理

### 3.1 一次性 bootstrap

每个开发者执行：

```sh
make bootstrap-cert
```

它会调 `scripts/bootstrap-cert.sh`，使用 `openssl` 生成一份 ECC P-256
密钥 + X.509 自签名证书（CN=`SimCam Local Dev`，extKeyUsage =
codeSigning），导入 login keychain，并 `security
set-key-partition-list` 让 `codesign` 在 GUI prompt 之外也能用它。

证书私钥停留在该开发者的 login keychain；**仓库中只 commit
`Configs/SimCamSigning.xcconfig`（公开的 CN 字符串），不 commit 任何
密钥**。

### 3.2 build & 安装

```sh
sudo systemextensionsctl developer on   # 一次性
make run
```

> **关于 SIP**：上面这条路线 SIP 保持完整启用即可——sysextd 之所以接受 self-signed 签名，是因为 `systemextensionsctl developer on` 单独放行了非 Apple anchor 的 system extension，不需要碰 SIP。
>
> **唯一需要最小化降级 SIP 的场景**：你想用 lldb / Xcode attach 调试正在运行的 system extension。这时去 Recovery 跑 `csrutil enable --without kext --without debug` 后 reboot 即可（**不是** `csrutil disable`）。详细步骤见 [docs/no-developer-account.md §2.2.1](file:///Users/guoshuyu/workspace/swmansion-copy/docs/no-developer-account.md)。

`make run` 链路：

1. `xcodebuild -scheme SimCam -configuration Debug` —— host & extension
   都用 `Configs/SimCamSigning.xcconfig` 锁定的 `Manual /
   "SimCam Local Dev"` 路径签名。
2. `sudo scripts/install-systemext.sh` —— 把 .app 拷到
   `/Applications/SimCamApp.app`，`chown root:wheel`，再用 codesign
   `--sign "SimCam Local Dev"` + `--entitlements` heredoc 重签 host 与
   extension（确保 `com.apple.developer.system-extension.install`、
   sandbox=true on extension、application-groups 这些 entitlements 真
   的写进 codesign blob，不被 Xcode 偷掉）。
3. `open /Applications/SimCamApp.app` —— menubar 出现，点击 *Activate
   Virtual Camera*，sysextd 接受激活，`systemextensionsctl list` 看到
   `[activated enabled]`。

### 3.3 后续开发

编辑代码后只要 `make run` 即可。第一次 build 时机器会弹一次
Camera / ScreenCapture 授权；**之后所有 rebuild 都不会再弹**，因为
codesign DR 锁到 CN 而 CN 不变。

## 4. 仓库里哪些东西必须保持不变

如果你正打算"清理"或"现代化"签名配置，下面这些都是**今天血泪教训留
下的硬约束**，不要动：

* `Configs/SimCamSigning.xcconfig` 中的
  `SIMCAM_CODE_SIGN_IDENTITY = "SimCam Local Dev"` —— 改这个 = TCC 失忆。
* `Sources/SimCamApp/Resources/SimCamApp.entitlements` 里的
  `com.apple.developer.system-extension.install = true` —— 删掉 = sysext
  请求被静默丢弃。
* `Sources/SimCamExtension/Resources/SimCamExtension.entitlements` 里的
  `com.apple.security.app-sandbox = true` —— 删掉 = CMIO Camera
  Extension category check 失败。
* `scripts/install-systemext.sh` 里两段 entitlements heredoc —— 这是
  entitlements 的 *single source of truth*；Xcode 自动签名 / 自动管理
  profile 路径有可能 strip 掉 entitlements，所以我们故意走 Manual + 脚
  本注入。
* host bundle id `dev.simcam.app` 与 extension bundle id
  `dev.simcam.app.extension` 的前缀关系。
* extension `.systemextension` 文件名（去后缀）必须等于 extension
  bundle id `dev.simcam.app.extension`，否则 sysextd 会报误导的 *"no
  policy, cannot allow apps outside /Applications"*。
* `.app` 拷到 `/Applications/` 后必须 `chown root:wheel`。

## 5. 发生事故时的诊断流程

```sh
scripts/diagnose-sysext.sh
```

它会按顺序打印：SIP 状态、developer mode、`/Applications/SimCamApp.app`
是否存在 + owner、host & extension codesign 与 entitlements、当前
running 进程、`systemextensionsctl list`、最近 5 分钟 sysextd 日志中
`dev.simcam` 相关条目。

经验上 99% 的"扩展跑不进去"都能在前 6 项里看到根因。

## 6. 失败时如何重置 TCC（最坏情况）

```sh
scripts/reset-tcc.sh
```

仅在你**真的换了证书**（例如你重新跑了 `bootstrap-cert.sh` 选了不同
的 CN）时才需要这一步 —— 它会 `tccutil reset Camera/ScreenCapture/
Microphone dev.simcam.app` 并把 `/Applications/SimCamApp.app` 备份后清
理，让下一次 install 从干净状态开始。

平时 rebuild **不需要** reset；如果你发现自己经常需要 reset，先确认
`security find-identity -v -p codesigning` 里你那张 `SimCam Local Dev`
证书没被替换，或者 `Configs/SimCamSigning.xcconfig` 没被人改回 ad-hoc。
