# MobileVLCKit 分发符号修复

日期：2026-10-16。应用版本仍为 1.3.0（6），本次只修复依赖准备和归档符号。

## 根因与处理

App Store Connect 分发提示归档缺少 MobileVLCKit.framework 的 dSYM，要求 UUID `99DC0B74-A3D1-3ED3-AC1F-2B8FC6A452A3`。检查确认原 SDK 准备脚本主动过滤了官方 XCFramework 的 `dSYMs` 目录，重建时也未传 `-debug-symbols`。之前的 Release 归档成功和运行验证没有覆盖依赖符号完整性，不能作为分发符号合格的证据。

官方 3.7.3 下载包本身包含匹配的真实 DWARF 符号。继续使用锁定的归档 SHA-256 `0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9`，仅裁剪框架和符号的 CPU 架构，通过 `xcodebuild -create-xcframework -debug-symbols` 打包。设备保留 arm64，模拟器保留 arm64／x86_64。迁移前后两个 framework 二进制 SHA-256 完全相同；未重新编译解码器，也未更换 SDK 版本。

`prepare_compatibility_sdk.py` 的缓存清单升级到第 2 版，记录 DWARF 哈希和各架构 UUID。旧的受管理缓存自动升级，未经管理或校验失败的缓存拒绝覆盖；只有候选 SDK 的二进制和符号核对成功后才替换旧目录。重复准备通过，不重新解压。

Release 构建阶段检查 MobileVLCKit 的 dSYM 存在且 UUID 与内嵌框架一致。`release_preflight.py --archive <路径>` 同时检查实际归档中的主应用和内嵌 framework UUID 是否有 dSYM 覆盖；SDK 有符号不再替代实际归档校验。

Apple 说明二进制与 dSYM 依靠相同构建 UUID 关联，预编译依赖必须使用对应构建的符号：[调试信息说明](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information)、[查找缺失符号](https://developer.apple.com/documentation/xcode/locating-a-missing-debug-symbol-file)。本次使用官方原始符号，没有从已裁剪的框架伪造 dSYM。

## 现有归档修复

用户失败的实际归档：`/Users/songpeng/Library/Developer/Xcode/Archives/2026-10-16/Glide 2026-10-16, 11.09.xcarchive`。

修复前独立校验准确报告仅 MobileVLCKit 缺符号。现已在归档的 `dSYMs/MobileVLCKit.framework.dSYM` 补入官方 arm64 符号，UUID 与用户报错及内嵌二进制完全一致。修复前记录并对照应用内全部文件及归档 Info.plist 的 20 项 SHA-256，全部保持不变；主应用 UUID 仍为 `973A7BC5-B3F1-3FDE-9E6E-74692E09EF0C`。补符号后的 `codesign --verify --deep --strict` 通过。

`Scripts/verify_archive_symbols.py` 默认只读；显式 `--repair-mobilevlckit` 仅允许给 Glide 归档补入本地受管理 SDK 的同 UUID 符号。UUID 不同或已有不同符号时拒绝写入，同一归档重复修复不再复制。不会修改已签名的 `.app` 或归档版本／元数据。

## 验证结果

- 新 Release 归档 `/tmp/Glide4K/Glide-1.3.0-6-symbols.xcarchive` 成功，Xcode 自动收集 MobileVLCKit dSYM，无需手工修补新归档；独立校验主应用和 framework 的 UUID 覆盖均通过。
- 原签名归档与新归档均通过 `release_preflight.py --archive`。
- 负面检查通过：不同架构／UUID 的符号被 SDK 验证拒绝；不匹配的归档修复被拒绝且不创建符号目录；重复修复幂等；旧的缺符号归档仍被发布预检拦截。
- Release 构建脚本单独验证：正确符号通过，缺失符号和错误 UUID 均以非零状态拦截。
- iOS 模拟器 Debug 编译通过，确认加入符号后模拟器切片仍可使用；本次没有播放代码改动，未重复播放器运行测试。
- 工程 plist、Python 语法和工作树空白检查通过。

[结构化验证记录](Glide-1.3.0-MobileVLCKit-symbols-audit.json)。

首次在受限环境检查原应用签名时返回证书信任不可用；允许系统读取本机证书信任信息后，同一签名的 `codesign` 检查通过，没有修改签名或证书。

本次未重新上传 App Store Connect，也未确认 Apple 服务端处理结果。用户可在 Xcode Organizer 中选择原 11:09 归档，重新执行分发；已对同一归档补齐符号，无需因此调整构建号。若构建号已被 Apple 成功接收，则后续重复上传是否需要新号以服务端实际状态为准。
