# 用 Epic UE 接入热更新框架

这个目录面向已有 UE 授权的开发者。由开发者从 Epic 获取引擎和依赖，由 AI 或开发者在自己的游戏仓库内接入发行流程。先完成本机验证，再用独立测试域名验收公网分发。

## 获取引擎和依赖

1. 关联 Epic 与个人 GitHub 账号，接受 EpicGames 组织邀请，确认能访问 Epic 的 UnrealEngine 仓库。已有 Launcher UE 5.8.3 的开发者可以直接从它开始验证项目层接入。需要自定义引擎补丁时再选择源码构建。[Epic 源码访问指南](https://www.unrealengine.com/ue-on-github)
2. 源码路径选短目录，给依赖、编译输出和 DDC 预留空间。从 Epic 拉取固定版本并核对来源。本框架以 Epic 5.8.3 基线 `396c9f059903aed5fec78ecd3d437a40c6415368` 为参考。

   ```powershell
   git clone --depth 1 --branch 5.8.3-release https://github.com/EpicGames/UnrealEngine.git C:/UE583
   git -C C:/UE583 rev-parse HEAD
   ```

3. 根据 Epic 指南安装 Visual Studio 的 C++ 工具链和 Windows SDK。依次运行 `Setup.bat` 和 `GenerateProjectFiles.bat`，打开生成的解决方案并构建 **Development Editor / Win64**。Android 另按目标引擎配置 Android SDK、NDK 和 JDK。出现访问错误时先核对 Epic 授权和 GitHub 登录，出现依赖下载错误时单独检查 Setup 的日志。[Epic 源码构建指南](https://dev.epicgames.com/documentation/en-us/unreal-engine/building-unreal-engine-from-source)

引擎与第三方依赖由各自的获准渠道取得。现有基础设施仓库尚无通用复用许可证，第三方在自己项目里采用前须取得维护者授权。分发引擎代码、编辑器或其他 Engine Tools 时按 Epic EULA 确认适用渠道和版本授权。[Epic EULA](https://www.unrealengine.com/eula/unreal)

## 跑通本机入口

在展示仓库根目录用 PowerShell 7 检查已有安装或源码根目录。报告是 JSON，`blocked` 对应退出码 1。源码目录检查成功只表示必要文件存在。

```powershell
pwsh -NoProfile -File .\Adoption\Start-UEAdoption.ps1 -EngineRoot 'C:\UE583'
```

取得授权后，检出已验证的基础设施参考版本。用 Python 3.11+ 虚拟环境安装 `cryptography`，选一个全新的项目输出目录。

```powershell
git clone https://github.com/GORXE111/UE-Game-Dev-Infrastructure.git C:/Work/UE-Infrastructure
git -C C:/Work/UE-Infrastructure checkout --detach 2d0654e54b78aeed17161747c6deedb9dce3d0b1
py -3.11 -m venv C:/Work/ue-adoption-venv
& 'C:/Work/ue-adoption-venv/Scripts/python.exe' -m pip install cryptography

pwsh -NoProfile -File .\Adoption\Start-UEAdoption.ps1 `
  -EngineRoot 'C:\UE583' -LocalDemo `
  -InfrastructureRoot 'C:\Work\UE-Infrastructure' `
  -ProjectOutput 'C:\Work\SampleGame' `
  -PythonExecutable 'C:\Work\ue-adoption-venv\Scripts\python.exe'
```

`local-demo-passed` 表示两种平台的签名与回退夹具已通过，且生成了 `SampleGame.uproject`。夹具使用临时密钥和模拟包体。生成的工程从原生 UE 行为开始。首次编译、Cook、打包、健康确认以及真实更新属于后续接入门槛。

## 检查真实项目

进入构建前可用同一入口检查已安装引擎、工程编辑器模块和发行适配器。

```powershell
pwsh -NoProfile -File .\Adoption\Start-UEAdoption.ps1 `
  -EngineRoot 'C:\UE583' -Project 'C:\Work\Game\Project\SampleGame\SampleGame.uproject' `
  -Platform Win64
```

Android 自有 APK 改用 `-Platform Android`，并以 `-InfrastructureRoot` 指向配置了公开 Android 签名证书及证书摘要的生产工具副本。独立 Clang 安装可用 `-ClangRoot` 指定。`-ReadinessSource` 可提示 AI 查看一份启动确认源码，其检查结果仍需通过真实包体运行确认。

`project-inputs-inspected` 表示所选静态检查已通过。查看 JSON 中的 `engine` 和 `projectIntegration`，可以分别处理引擎和游戏项目的阻断项。若只需检查项目，可单独运行 `Test-ProjectIntegration.ps1`。完整流程见[运行时手册](RUNTIME.md)。

在已有 PRO Max 5.8.3 开发安装上，公开脚手架生成的空白工程已实际通过 `SampleGameEditor Win64 Development` 编译，DLL 对应安装版的编辑器 Build ID。官方 Launcher UE 的项目编译及安卓设备运行各自需要验收。

## 跑一次 Win64 包体验收

准备可编译 Win64 项目的 UE 5.8.3 Installed Build、固定版本的基础设施仓库和上一步的 Python 环境。输出使用一个全新的短英文路径。以下是使用团队 Clang 安装版的例子。

```powershell
pwsh -NoProfile -File .\Adoption\Invoke-Win64PackageSmoke.ps1 `
  -EngineRoot 'C:\UE583' -InfrastructureRoot 'C:\Work\UE-Infrastructure' `
  -OutputDirectory 'C:\Work\UE-Package-Smoke-01' `
  -PythonExecutable 'C:\Work\ue-adoption-venv\Scripts\python.exe' `
  -ClangRoot 'C:\LLVM' -MaxParallelActions 1 -VerifyNativeAssetUpdate
```

脚本在输出目录生成样板，编译编辑器模块，再用 UAT Cook、Stage、打包和归档。归档游戏以 NullRHI 启动。烟测模块在指定地图实际进入游戏状态后写标记并退出。`win64-package-smoke-passed` 要求 UAT 和游戏都退出为 0，归档含 PAK，且游戏日志有就绪和正常退出记录。`blocked` 报告失败阶段，日志保留在输出目录。

首次 Cook 可能需要编译全局着色器。`-MaxParallelActions` 控制 UBT 编译任务数，Cook 的着色器工作进程由引擎另行调度。

2026 年 11 月 5 日在本机 PRO Max 5.8.3 开发安装上实测通过。编辑器编译、UAT 和归档游戏退出码均为 0。游戏实际挂载 `SampleGame-Windows.pak`，加载 `/Engine/Maps/Entry` 并正常退出，独立 UnrealPak 列表也确认该地图在 PAK 内。

`-VerifyNativeAssetUpdate` 需要 Installed Build 中的 Python Editor Script Plugin。它为 100、101、102 分别编译 EXE，并用 UE 编辑器生成同路径的 DataTable。每版单独 Cook 和打包，候选复用增量 Cook。脚本锁定基包 100 的清单摘要，用一次性的 Ed25519 密钥签发候选。真实 UE 进程在地图开始运行后读取 PAK 内的表，核对 C++、表和启动票据的版本。102 写入自己的存档副本后故意退出，下一次启动重新加载 101 的 EXE、PAK 与存档，并逐字节核对原存档。

`-VerifyNativeAssetUpdate` 也会在独立安装中验收一次错配。用有效测试签名提交 101 的 EXE 和 100 的 PAK，要求 UE 在改写存档前拒绝确认，并重新启动 100。`SignedUpdate/report.json` 保存每版 EXE 和 PAK 的 SHA-256、实际运行的 C++ 与资产版本、进程退出状态和存档代次。正常更新和错配测试的日志分别保存在 `SignedUpdate/store/boots` 和 `SignedUpdate/mismatched-pair`。若只验收签名与回退，可改用 `-VerifySignedUpdate`，三版共用一套 EXE 和 PAK。省略两种开关时只验收最小包体启动。

要复测已有的三份样板归档，可以跳过重新 Cook 和打包，直接运行以下命令。输出应使用全新短英文路径，预留约四倍单个包体大小另加 128 MiB 的磁盘空间，完成后保留三个版本和验收证据。

```powershell
python -X utf8 -B .\Adoption\Win64Smoke\verify_update.py `
  --archive 'C:\Work\UE-Package-Smoke-01\Archive\Windows' `
  --candidate-archive '101=C:\Work\UE-Package-Smoke-01\Archive-101\Windows' `
  --candidate-archive '102=C:\Work\UE-Package-Smoke-01\Archive-102\Windows' `
  --verify-mismatched-pair `
  --infrastructure 'C:\Work\UE-Infrastructure' `
  --output 'C:\Work\UE-Update-Smoke-02'
```

此验收使用测试 DataTable 和固定 schema 的存档。真实项目需按[运行时手册](RUNTIME.md)验证目标玩法、反射布局、存档迁移、线上下载及 Android 运行。

## 复用包体验收本机 HTTPS 更新

用上一步的三份归档运行参考 Windows 客户端的真实下载器。脚本在 `127.0.0.1:443` 临时提供 HTTPS 清单、签名和版本文件，端口需要空闲。测试证书仅对脚本进程生效。输出使用全新短英文目录，并预留约六倍单个包体大小另加 128 MiB。

```powershell
python -X utf8 -B .\Adoption\Win64Smoke\verify_feed.py `
  --archive-100 'C:\Work\UE-Package-Smoke-01\Archive\Windows' `
  --archive-101 'C:\Work\UE-Package-Smoke-01\Archive-101\Windows' `
  --archive-102 'C:\Work\UE-Package-Smoke-01\Archive-102\Windows' `
  --infrastructure 'C:\Work\UE-Infrastructure' `
  --output 'C:\Work\UE-Https-Smoke-01'
```

验收覆盖下载损坏时拒绝激活、修正后重试成功、故障候选回退及原存档恢复。`report.json` 保存请求与已发送字节、游戏启动回执和恢复结果。公网 DNS、CDN 缓存、外网下载及带宽仍按[网络手册](NETWORK.md)验收。

## 让 AI 接手集成

把本目录的位置交给 AI，并提供**已授权的引擎路径、游戏仓库路径、目标平台和发布渠道**。按 [AGENTS.md](AGENTS.md) 执行并给每步留可核验的结果。

```text
请读 Adoption/AGENTS.md，按阶段把热更新框架接入我的项目。
引擎根目录 <UE 路径>
游戏仓库 <项目路径>
目标平台和分发方式 <Windows／安卓自有 APK／Google Play>
本轮目标 <离线演示／实际包体测试／公网测试>
测试域名和渠道 <已有测试入口，或待提供>
先报告预检和项目缺失项，再在可恢复的测试数据上执行并记录结果。
```

| 阶段 | 工作 | 通过条件 |
| --- | --- | --- |
| 本机 | 预检、生成样板、离线验证签名事务 | 报告区分引擎检查、夹具结果和已生成工程 |
| 游戏接入 | 运行项目预检，接齐构建适配器、真实基包、PAK／Lua 加载、健康确认与存档 | 冷启动确认真实版本，破坏候选后能回到旧代码、资源和存档。[运行时手册](RUNTIME.md) |
| 测试公网 | 建测试域名、TLS、CDN 防护与私有发布入口 | 从源站以外完整下载并核对摘要，验证缓存、Range、回退及源站隔离。[网络手册](NETWORK.md) |
| 正式发布 | 切换经过验收的渠道 | 已确认权限、签名身份、完整验收记录与回退窗口 |

最低可用目标是一个游戏在本地完成 **基包安装 → 下载签名候选 → 重启应用 → 资源加载和存档验证 → 故障回退**。Android 自有 APK 与 Google Play 需要分开决定分发方式和允许更新的内容。[运行时手册](RUNTIME.md)
