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
| 游戏接入 | 接齐构建适配器、真实基包、PAK／Lua 加载、健康确认与存档 | 冷启动确认真实版本，破坏候选后能回到旧代码、资源和存档。[运行时手册](RUNTIME.md) |
| 测试公网 | 建测试域名、TLS、CDN 防护与私有发布入口 | 从源站以外完整下载并核对摘要，验证缓存、Range、回退及源站隔离。[网络手册](NETWORK.md) |
| 正式发布 | 切换经过验收的渠道 | 已确认权限、签名身份、完整验收记录与回退窗口 |

最低可用目标是一个游戏在本地完成 **基包安装 → 下载签名候选 → 重启应用 → 资源加载和存档验证 → 故障回退**。Android 自有 APK 与 Google Play 需要分开决定分发方式和允许更新的内容。[运行时手册](RUNTIME.md)
