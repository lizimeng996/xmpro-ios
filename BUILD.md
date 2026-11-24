# XMPro iOS · 构建指南

本文面向希望自行编译、运行单元测试或二次开发本项目的开发者。项目采用 **AGPL-3.0-or-later** 许可协议，移植自 [angusdevgo/XMPro](https://github.com/angusdevgo/XMPro)。

---

## 1. 工具链与目标环境

| 项目 | 规格 |
| --- | --- |
| Xcode | 15+（已在 Xcode 27.2 / iOS 27.2 SDK 上完整验证编译与 371 项 XCTest） |
| Swift | Swift 5.9+ 编译器，语言模式 `SWIFT_VERSION = 5.0` |
| 最低部署版本 | iOS 16.0（iOS 26.1+ 自动启用原生 Liquid Glass API） |
| 工程配置源 | `project.yml`（XcodeGen）与随附的 `XMPro.xcodeproj` |

---

## 2. 工程结构

```text
XMPro/
├── App/            # 应用入口（XMProApp）、依赖注入容器（AppDependencies）
├── Protocol/       # 纯 Swift 协议层（MD5/SHA1、AES 信封、TAC Ticket、业务签名、ServerClock、HTTPTransport、OrderedJSON）
├── Domain/         # 领域模型（Album、Track、Comment、Quota、SocialModels）
├── Data/           # 状态持久化（StateDocument、StateRepository、CredentialsVault、AccountStore、DeviceIdentity）
├── Services/       # 业务服务（Client、History、Login、Experience、Bookmark、Welfare、UsageLedger、Channel、Backup、AccountCoordinator）
├── Player/         # 播放核心（PlaybackEngine + Biquad DSP 音效、PlaybackSession、PlaybackQueue、SmartSkipScanner、锁屏与后台控制）
└── Features/       # SwiftUI 界面（主页、听书、搜索、专辑、播放器、登录/GeeTest、福利、设置、Liquid Glass 设计系统）

XMProTests/         # XCTest 单元测试套件（31 个测试文件，371 个测试方法）
tools/              # 独立 Python 协议参考实现与黄金测试向量（golden_vectors.json）
```

---

## 3. 命令行构建与测试

先确认 `xcode-select` 指向完整 Xcode（或通过 `DEVELOPER_DIR` 指定）：

```bash
# 查看 scheme 与可用目标
xcodebuild -list -project XMPro.xcodeproj
xcodebuild -scheme XMPro -showdestinations

# iOS 模拟器构建并运行全部单元测试（将模拟器名称或 ID 替换为本机可用设备）
xcodebuild \
  -project XMPro.xcodeproj \
  -scheme XMPro \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  test

# 无签名校验真机架构构建
xcodebuild \
  -project XMPro.xcodeproj \
  -scheme XMPro \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 打包无签名 Release IPA（供自签安装）

如需直接产出不含个人签名信息、可供 Sideloadly / AltStore / SideStore / TrollStore 等工具自签安装的真机 IPA：

```bash
rm -rf build/ipa-out && mkdir -p build/ipa-out/Payload

xcodebuild \
  -project XMPro.xcodeproj \
  -scheme XMPro \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ipa-out/DerivedData \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  OTHER_SWIFT_FLAGS='$(inherited) -file-prefix-map '"$PWD"'=. -debug-prefix-map '"$PWD"'=.' \
  build

cp -R build/ipa-out/DerivedData/Build/Products/Release-iphoneos/XMPro.app build/ipa-out/Payload/XMPro.app
rm -rf build/ipa-out/Payload/XMPro.app/_CodeSignature build/ipa-out/Payload/XMPro.app/embedded.mobileprovision
(cd build/ipa-out && zip -qry ../XMPro-0.1.0-unsigned.ipa Payload -x '*.DS_Store')
```

生成的无签名包位于 `build/XMPro-0.1.0-unsigned.ipa`（默认已被 `.gitignore` 忽略，不会污染仓库）。

---

## 4. 使用 XcodeGen 重新生成工程

若增删文件或修改了 `project.yml`：

```bash
xcodegen generate
```

生成后请确认：
1. `XMPro` 与 `XMProTests` 两个 target 的源码列表完整；
2. `tools/golden_vectors.json` 仍作为测试资源打包进 `XMProTests` bundle；
3. `XMPro/Info.plist` 中保留 `UIBackgroundModes: [audio]`；
4. `DEVELOPMENT_TEAM` 保持为空字符串，不提交个人签名团队 ID。

---

## 5. 黄金向量与脱敏规范

- 协议层加密与签名逻辑通过 [tools/golden_vectors.json](tools/golden_vectors.json) 在 `XMProTests` 中进行回归验证。
- 提交代码前，请务必确认：
  - 不包含真实账号 Cookie、Token、手机号、私钥或未脱敏的抓取样本；
  - `XMPro.xcodeproj/project.pbxproj` 与 `project.yml` 中的 `DEVELOPMENT_TEAM` 为空。

---

## 6. 已知限制

- **离线下载**：本移植不提供离线音频下载功能，仅在状态 JSON 中兼容保留 `downloads` 字段以便与 Android 版双向备份互通。
- **后台福利任务**：受 iOS 后台执行策略限制，不支持后台常驻定时领取听时；自动领取仅在前台触发。
- **智能跳过静音**：默认关闭，仅支持扫描本地可读取媒体资源，扫描失败自动降级不影响正常播放。
- **App Store 上架**：因 AGPL-3.0 协议与 App Store 分发条款冲突，本项目仅面向个人自签侧载使用。
