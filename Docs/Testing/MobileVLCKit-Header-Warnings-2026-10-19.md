# MobileVLCKit 公开头文件告警修复

日期：2026-10-19。对应 Xcode 的四条 double-quoted include in framework header 告警，均来自固定 MobileVLCKit 3.7.3：

| 头文件 | 原引用 | 规范后的引用 |
| --- | --- | --- |
| VLCAdjustFilter.h | "VLCFilter.h" | <MobileVLCKit/VLCFilter.h> |
| VLCConsoleLogger.h | "VLCLogging.h" | <MobileVLCKit/VLCLogging.h> |
| VLCFileLogger.h | "VLCLogging.h" | <MobileVLCKit/VLCLogging.h> |
| VLCLogMessageFormatter.h | "VLCLogging.h" | <MobileVLCKit/VLCLogging.h> |

Clang 对该诊断的定义见 [Diagnostics Reference](https://clang.llvm.org/docs/DiagnosticsReference.html#wquoted-include-in-framework-header)。

## 实现

SDK 准备脚本升级到第 3 版，对真机和模拟器两个 slice 的四处引用做确定性替换，共八个头文件，并记录规范后的 SHA256。项目的 CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER 继续开启。

已有第 2 版受管理缓存先核对二进制、dSYM 哈希和各架构 UUID，然后原地升级头文件；无需重新下载 SDK。重复执行保持缓存清单不变；未知的引用内容拒绝处理。首次从官方归档准备时应用相同规范，其他头文件内容及播放器二进制不作修改。

执行 python3 Scripts/prepare_compatibility_sdk.py 即可升级旧缓存。本机已经完成升级。重新 Build 会重新编译受影响的依赖；历史归档及已推送标签保持原有内容。

## 验证

- 修复前，直接导入 MobileVLCKit 公开 umbrella 头文件并开启 -Werror=quoted-include-in-framework-header，准确复现四条错误。
- 修复后，iOS arm64、模拟器 arm64／x86_64 均以相同严格选项通过，相关诊断为零；使用 -fno-modules 直接检查全部公开头文件，避免模块缓存掩盖问题。
- 验证首次头文件规范与重复执行一致，异常引用被拒绝；现有 SDK 重复准备不修改清单。
- 修复前后播放器二进制、dSYM 的 SHA256 及各架构 UUID 全部一致。
- 完整 iOS Release 编译通过，使用独立 DerivedData、generic/platform=iOS、CODE_SIGNING_ALLOWED=NO，并将该类告警提升为错误。该类诊断为零；工具链另有无 AppIntents 依赖时跳过元数据提取的提示，与这四处头文件引用无关。

结构化结果见 [验证结果](MobileVLCKit-Header-Warnings-2026-10-19.json)。本轮属于依赖头文件规范及构建验证，不以此声称新增播放运行时验收。
