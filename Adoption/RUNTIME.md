# 接入游戏运行时与存档

本页从能够用 UE 打开并打包的最小工程开始。先在一个测试项目和独立安装目录验证完整包，再接入签名更新。这里的参考实现使用 UE 5.8、Windows Win64 和 Android ARM64，按重启切换原生代码与 Cook 资源。公开仓库通过了脚手架、离线事务和主机测试。新项目仍需完成实际编译、Cook、进程启动和回退验收。[参考实现验收范围](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/docs/verification-scope.md)

在自己的工程开始构建前，按[真实项目检查](README.md#检查真实项目)运行联合预检。项目检查的 `runtimeValidated` 保持为 `false`。即使源码中找到就绪确认相关标记，也需要下文的真实启动和回退证据。

先运行[最小包体验收](README.md#跑一次-win64-包体验收)，确认实际 Cook、PAK 挂载及游戏启动。加上 `-VerifySignedUpdate` 可复现 Windows 启动器验签、UE 进程确认候选、故障回退和存档隔离，再把流程移入自己的工程。

## 1. 让基包先独立启动

1. 用匹配的 UE 版本构建一个最小 C++ 工程，加入可操作的启动地图和一个测试存档槽。增加一个只能由新内容实现的可观察标记，例如可加载地图的内容版本。使用 Unreal Automation Tool 或编辑器完成 Build、Cook、Stage、Package，从生成的目录实际启动。记录工程提交、引擎 Build ID、平台、配置、地图清单、APK 包名或 Windows 目标名。 [Epic 打包指南](https://dev.epicgames.com/documentation/en-us/unreal-engine/packaging-your-project)
2. 以项目源码为准补齐三段构建适配器。参考生产工具会调用 `Tools/Build-Project.ps1`、`Tools/Package-Project.ps1`、`Tools/Release/Read-NativeSourceHash.ps1`，并从 `Content/Lua/game/release_status.lua` 读取唯一的字面版本号。若目标项目无需 Lua，需要先调整并验证生产器和两端就绪协议，不要填虚假的 Lua 加载结果。公开脚手架生成的是源码工程，游戏逻辑、地图及这些生产适配器由接入项目维护。 [构建前置检查](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/Tools/Release/ReleaseSets/project_integration.py)
3. 先复现 `SampleGame` 参考布局，或把 producer、客户端、安卓包名和网关计划里耦合的样例身份一起移植。为每个平台固定 `projectId`、`channel`、`baseReleaseId`、`engineBuildId`、`shellCompatibilityId`、公钥或签名证书指纹，以及 HTTPS 清单地址。固定的示例证书指纹为全零，需要用项目自己的测试证书替换。发布密钥存放在仓库与输出之外，证据只记录公钥身份、签名和摘要。 [打包与发布](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/docs/packaging-and-publication.md)
4. 从参考仓库根目录运行 `python Tools/Release/ReleaseSets/windows_pipeline.py --help` 或 `python Tools/Release/ReleaseSets/android_pipeline.py --help` 确认当前参数。流程为 `build → prepare → archive`。从真实构建记录生成 `shell-freeze.json` 和基包清单。归档保留安装包大小、SHA-256 和构建证据。独立保存干净基包，测试使用从它复制或安装出的实例。

| 平台 | 安装基包 | 候选更新与启动 |
| --- | --- | --- |
| Windows | 用 `Build-WindowsPlayer.ps1` 构建发布启动器，使用 Ed25519 生成匹配的测试密钥，安装包内含冻结的游戏程序、PAK、清单和启动配置 | `windows_pipeline.py candidate` 签发完整的新版载荷，启动器在启动新进程前校验并选择版本。进程使用启动器给出的资源目录和存档目录 |
| Android ARM64 | 参考工具为自有 APK 生成 `assets/release-player.json` 与 `assets/release-base-manifest.json`。加入 Android 启动桥之前，先验证签名证书与这两份文件都匹配 | Android 引导入口先选定已验签的 `libUnreal.so`、对应 PAK 和存档代次，再启动 UE。候选签名使用 APK 对应的 RSA 证书体系。包名和签名关系与完整 APK 覆盖安装单独验收 |

发布 Android 完整 APK 时，应核对应用标识、版本号和允许覆盖更新的签名证书。Google Play 对平台外自更新和下载原生可执行代码有限制。Play 分发应把原生更新交给商店，并按实际渠道审核资源与脚本策略。当前原生联合更新方案面向自有 APK 测试渠道。[Android 应用签名](https://developer.android.com/studio/publish/app-signing) · [Google Play 设备与网络滥用政策](https://support.google.com/googleplay/android-developer/answer/16559646)

## 2. 在游戏里实现真实就绪确认

实现一个游戏侧启动适配器，将更新事务接到真实的游戏初始化过程。可以沿用项目的 GameInstance 子系统。

1. 读取启动器生成的票据和当前进程身份。使用票据给定的 `payloadRoot`、`userRoot`，校验当前 `releaseId`、`manifestSha256`、`buildId` 和存档 schema。Windows 使用 `-SampleGameReleaseTicket` 与 `-UserDir`，Android 桥接层同时给出选中 PAK 的 `-pakdir`、`-paklist`。路径来自受信启动器；不要从 URL、玩家输入或配置界面覆盖它们。
2. 观测实际加载的关卡、资源标记和 Lua 版本。配置表须成功读取并校验 schema，再继续进入可玩的状态。验证资产可访问，并能区分基础包、候选包和回退版本，避免拿旧包资源启动却确认新包。
3. 在候选存档代次上读写并完成迁移。游戏确认已加载新内容、可用的配置和正确存档后，才生成就绪记录。记录绑定本次 `attemptId`、`releaseId`、`manifestSha256`、`buildId`、进程 `pid`、`userRoot`、`saveSchema` 和 `luaVersion`。
4. Windows 将记录原子写入票据的 `health.json` 路径，启动器在记录有效且游戏进程正常退出后确认。Android 由游戏侧代码通过 JNI 调用 `ReleasePlayer.acknowledge`，Android 引导层验证记录并确认后才允许检查更新。进入地图、进程仍在运行或收到任意健康文件都不足以确认。

公开的 Win64 样板含可编译的就绪适配器。它在真实地图进入 BeginPlay 后检查签名载荷中的版本标记，并通过隔离用户目录验证存档。样板协议用 `adoption-sample-<releaseId>` 作为 `luaVersion` 测试值。接入项目须由自己的适配器读取实际内容和脚本版本，并按项目定义的就绪条件写入回执。 [更新与回退契约](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/docs/update-and-rollback.md)

## 3. 资源、脚本和配置按同一版本切换

- 当前参考联合更新交付完整清单和对应文件集合，选中版本后以冷启动生效。选中的游戏原生文件、目标平台 Cook 过的 PAK、实际 Lua 和配置输入须同源构建，并记录摘要。该布局以 PAK 为主，IoStore、跨版本增量和运行中替换原生代码需要各自的实现及验收。
- 蓝图、地图、Lua 和由游戏读取的数据表可先用一处最小改动验收。把运行时需要的 Lua 或表产物以项目实际支持的方式纳入 Cook 和签名文件清单，核对加载来源、依赖与覆盖优先级。项目 `Config/` 下的壳配置受兼容冻结管理，和游戏运行时读取的数据表分开。新版引擎、APK 的 Java／权限／清单、签名身份、安装壳依赖等变更需要重新制作基包。反射类型、资产改名和序列化布局变化逐项审查。 [兼容冻结实现](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/Tools/Release/ReleaseSets/compatibility.py)
- 使用 `candidate` 从真实生产证明签发后，保留原始签名清单，检查项目、平台、渠道、基包、文件角色及大小和 SHA-256。`inspect_release_set.py` 可只读检查 Ed25519 签名候选。Android 证书签名由 Android 生产及引导路径校验。通过本机验收后再走 [公网入口与分发](NETWORK.md) 的完整读回和推广流程。

## 4. 存档代次与迁移

把旧版本的确认代次作为只读来源。激活前从其中分叉一个新的候选存档目录，原版本继续保留自己的目录。游戏统一从票据指定的用户目录加载和写回。将游戏进度、必要配置与可重建缓存分开，并记录允许导入的路径、容量和清理规则。

维护显式的 schema 与逐级迁移表。迁移前保留旧存档，候选启动后只改候选副本。对未知 schema、损坏或未完成迁移的输入明确失败；重试应保持一致。回退时重新选择旧版本和它的旧代次。回退会舍弃失败候选里的未确认进度，产品界面应有相应提示。跨基包导入须另测。云端账号、联机服务器数据库和多设备存档冲突是独立接入工作。

## 5. 从测试演示到可以上线

从参考仓库根运行 `python Tools/Release/ReleaseSets/demo_transaction.py`。它通过临时密钥与占位文件覆盖 Windows 和 Android 载荷布局的事务流程。然后从干净安装目录用真实 Windows 游戏包和 Android APK 在隔离渠道执行以下验收：

| 场景 | 通过条件 |
| --- | --- |
| 新装与无网启动 | 基包进入可操作的关卡，正确写入基线存档，记录实际原生与资源版本 |
| 签名错误、错误渠道、缺文件、文件篡改、空间不足或断网 | 原有版本保持可用，半成品从未被选中 |
| 下载成功后启动 | 新进程加载预期原生代码、关卡／资源、Lua 与配置，真正写入匹配的就绪回执 |
| 就绪前退出、超时或迁移失败 | 下次启动恢复旧版本和旧存档，拒绝立即再次选中失败版本 |
| 重新打开已确认版本 | 候选存档可继续使用，安装目录和频道没有跨项目串包 |
| 跨基包与实际目标设备 | 用匿名真实旧档验证接续，验证正式交付使用的包签名、设备 ABI 与渠道规则 |

每次记录基包与候选的 SHA-256、运行日志和就绪／回退证据。按通过的阶段标识 `host-fixture`、`packaged-baseline`、`packaged-update-and-recovery`、`public-readback`。AI 在缺少真实工程、编译环境、签名身份、就绪适配器或设备时应报告对应阻断，保留已完成阶段的证据。
