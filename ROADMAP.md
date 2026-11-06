# 开发路线

按外部开发者从获得工具到做出第一个可运行包的顺序推进。评估依据和缺口见[技术与采用评估](ASSESSMENT.md)。

独立接入按配置表与 Jenkins 门禁、项目描述与资源校验、客户端和专用服务器构建、签名发布与公网读回推进。可执行工具在基础设施仓库维护。 [独立开发者接入路线](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/main/docs/developer-adoption.md)

| 优先级 | 工作 | 通过条件 |
| --- | --- | --- |
| 已落地 | 接入预检、Win64 包体与下载核验 | 引擎和项目的静态检查输出 JSON。最小样板已在 PRO Max 上完成 Win64 Cook、打包和归档启动。下载与清单探针覆盖整包摘要、活动版本字节及缓存规则 |
| 已落地 | Win64 原生代码与资源联合更新样板 | 三版分别编译 EXE 和 Cook DataTable。真实 UE 拒绝签名有效但版本错配的候选。本机 HTTPS 实测损坏重试，故障后回退 EXE、PAK 和存档 |
| P0 | 原版 UE 的最小 GAS／AI 工程 | 全新 Launcher UE 5.8.3 环境下，独立编译、启用、Cook 并运行；启用插件的蓝图实际做双引擎资产往返 |
| P0 | 单一源码身份的内部安装版 | 固定 Epic 基线、团队提交、编译器与 SDK。从干净目录安装，完成项目编译、编辑器启动、Cook、打包启动及外部 MCP 探针 |
| P1 | 插件依赖和分发审查 | GAS／AI、配置／Lua、编辑器工具和渲染各有依赖清单。模块发布前逐项核对来源、许可和 UE 分发资格 |
| P1 | 干净的上游维护分支 | 从确切 Epic 基线复放小型补丁序列，记录冲突和回退步骤。在验证通过后再决定是否迁移集成历史 |
| P1 | 可复用的双端发行样板 | 独立游戏工程使用不同的 C++ 构建和 Cook 资源，双端完成签名更新和回退，记录存档代次及兼容条件 |
| P2 | 渲染与平台矩阵 | 同场景在官方 UE 和 PRO Max 对照帧时间、显存、画质。补充目标显卡、Windows 和 Android 真机范围 |

源码构建顺序和获取条件参考 [Epic 源码指南](https://dev.epicgames.com/documentation/unreal-engine/downloading-source-code-in-unreal-engine)。
