# UE 5.8.3 PRO Max

PRO Max 是基于 UE 5.8.3 的游戏开发工具集和团队引擎分支。它把 GAS／行为树、数据表、Lua、编辑器自动化及签名更新接进开发和发行流程。这个展示仓库收录技术说明及本机环境检查工具。引擎源码与安装包按 UE 授权在受限渠道维护。

## 功能与实测范围

| 能力 | 已验证的场景 | 下一道验收门槛 |
| --- | --- | --- |
| GAS 与行为树 | Win64 编辑器实际授予、激活、取消和撤回技能，调用 AI 任务及装饰器 | 原版 UE 工程编译、Cook、资产往返及多人预测 |
| Excel 配置与 Lua | 已构建配置和 Lua 模块，测试 Lua 表达式、语法错误及样板工程加载和打包 | 原版 UE 5.8.3 下按模块独立接入 |
| 蓝图与资源更新 | Win64 最小样例实际观察到蓝图属性 `1.0 → 2.0 → 1.0`。独立打包样板也实测签名候选、UE 进程就绪和失败后的存档回退 | 用两套不同的 C++ 构建和 Cook 资源验证联合切换，补齐 Android 与公网链路 |
| 编辑器 MCP | 旧安装包之后的本机修复版已观察到工具集注册和外部调用 | 从同一源码重建后复验发现、读写权限、撤销与断开 |
| 可选渲染适配 | RTX 3060 上实测 D3D12 和 DLSS 超分辨率，Lumen 有三处探针预算保护 | 与原版在同场景、同画质对照，扩到更多硬件 |

已运行的安装样本、当前源码和下一版发行物需要各自验收。当前证据支持 Win64 Development 开发预览，详见[技术与采用评估](ASSESSMENT.md)。

## 先检查本机环境

在 Windows 上使用 PowerShell 7，对已经安装的 UE 运行以下命令。

```powershell
pwsh -NoProfile -File .\Tools\Test-ProMaxReadiness.ps1 -EngineRoot 'C:\UE583'
pwsh -NoProfile -File .\Tools\Test-ProMaxReadiness.ps1 -EngineRoot 'C:\UE583' -Project 'C:\Game\Game.uproject' -CheckCpp -Json
```

检查会读取安装结构、版本、编辑器 Build ID 和已有项目模块，并显示所在磁盘的可用空间。用 `-PluginRoot 'C:\Game\Plugins\MyPlugin'` 可单独检查插件的编辑器模块。C++ 模式还会检查编译准备条件，已有的独立 Clang 安装可用 `-ClangRoot` 指定。退出码 `0` 表示通过所选静态检查，可同时有建议项。`1` 表示存在阻断项。通过后再使用一个空白项目实际编译和 Cook。

从 Epic 获取 UE、用 AI 接入签名热更新、配置公网下载和验收存档回退，见[接入目录](Adoption/README.md)。开发和发布参考实现见 [UE Game Development Infrastructure](https://github.com/GORXE111/UE-Game-Dev-Infrastructure)。分阶段验收见[开发路线](ROADMAP.md)。
