# 公网下载网关接入手册

先在测试域名和测试渠道完成真实下载，再安排生产切换。下载链路为「玩家 → HTTPS 下载域名 → CDN 或边缘防护 → Nginx 源站」。发布人员从受控网络走 SSH，把经签名的文件送进私有暂存区。发布器经玩家同一路径读回文件并核对 SHA-256，再提升联合更新或整包下载的当前指针。

## 准备部署参数

| 参数 | 配置和记录要求 |
| --- | --- |
| 域名与证书 | 分配测试和生产下载主机名，记录 DNS 区域、CDN 服务、证书签发和续期负责人。构建基包前固定该渠道的 HTTPS 清单地址 |
| 源站 | Linux、Python 3、OpenSSH 和 Nginx。按实际最大候选包计算磁盘及出站带宽，记录回退版本的保留空间 |
| 发布账户 | 分配专用非 root 账户，限定可写目录。预先核对 SSH 主机密钥，并固定到 `known_hosts`。清单签名私钥存放在发行机的受控密钥存储中 |
| 发行身份 | 固定项目 ID、平台、基包、发布渠道、只增不减的版本 ID、签名公钥或证书指纹。测试环境使用独立密钥 |

对照基础设施仓库的完整 TLS 虚拟主机和发布器。样例主机名是 `updates.example.com`，存储根是 `/srv/ue-game-updates`。当前 `Tools/Release/PlayerHosting/players.py` 的 `ORIGIN`、远程脚本的站点配置文件路径和渠道白名单均在源码里约束。项目接入时，同步调整客户端安装配置、发布器、远程脚本及 Nginx，再生成基包和发布计划。联合更新的 `/updates/versions/` 路由保留在虚拟主机文件内，供现有发布预检识别。 [网关安装说明](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/docs/server-gateway.md)

## DNS、TLS 和防护

1. **先建立测试入口。** 用 CDN 提供的 DNS 目标创建下载主机记录。检查公共 DNS 的 A、AAAA 或 CNAME 解析及代理状态。IPv4 和 IPv6 使用相同的防护边界。核对证书覆盖下载主机名，边缘到源站启用 TLS 并验证源站证书。
2. **限制源站入口。** 让源站 443 仅允许可信 CDN 回源地址，或使用经过认证的回源连接、私网回源或隧道。核查同一源站 IP 是否仍由其他直连 DNS 记录暴露。对自己控制的测试源站，从 CDN 外网络验证绕过 CDN 的直接访问被拒绝。 [Cloudflare 源站防护参考](https://developers.cloudflare.com/fundamentals/security/protect-your-origin-server/) · [认证回源示例](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/explanation/)
3. **隔离管理流量。** SSH 从 VPN、堡垒机或指定发行网络进入。下载域名只暴露静态文件读取，私有暂存、锁文件、管理日志及 SSH 无公开 HTTP 路径。当前发布器会让远端执行发行端传入的工作脚本，因此发行 SSH 账号视为受信任操作员，权限限于所属发布目录。
4. **在边缘吸收流量并观察误拦。** 启用适用于下载域名的 DDoS 防护。按路由设置合理的限速，对清单轮询和大文件流量分别观察。游戏更新走程序请求，测试规则时覆盖常见移动网络、共享出口和 Range 请求，确认正常客户端无需浏览器挑战。Nginx 限流可补充源站保护，配置客户端 IP 限速时只信任已配置的代理来源。 [Nginx 请求限速](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html) · [Nginx 可信来源地址](https://nginx.org/en/docs/http/ngx_http_realip_module.html)

## 下载和缓存

| 样例路由 | 行为 |
| --- | --- |
| `/samplegame/<channel>/updates/manifest.json` 和 `.sig` | 当前联合更新清单。保持 `Cache-Control: no-store`，CDN 对这两条路径绕过缓存 |
| `/samplegame/<channel>/updates/versions/<id>/...` | 版本化清单、签名、显示信息和签名清单列出的文件。成功响应使用不可变缓存，已发布的 URL 保持原字节 |
| `/samplegame/players/manifest.json` | 整包下载目录。样例用 `no-cache`，由客户端或缓存重新验证。应避免 CDN 规则覆盖回源策略 |
| `/samplegame/players/releases/<id>/...` | Windows ZIP、Android APK 和对应 SHA-256 文件。核对 HEAD、整包 GET 和有效的 206 Range 响应 |
| 未发布路径、暂存路径及写请求 | 暂存目录不对外路由，缺失路径返回 404 且不缓存。POST、PUT 等写请求被拒绝 |

安装包和资源按原始字节传输。验证完整 GET 的 `Content-Length` 和 SHA-256，禁止 CDN 对签名资源重压缩或改写。合法 Range 要核对 `Content-Range` 和返回的切片字节。网关能返回 206 只证明服务器支持 Range。当前公开样例的联合更新客户端可复用已通过摘要校验的完整文件，未完成的单文件还需要重新下载。可先用[本机 HTTPS 更新验收](README.md#复用包体验收本机-https-更新)检查损坏重试和版本恢复。逐字节续传及公网缓存另做验收。 [HTTP Range 规范](https://www.rfc-editor.org/rfc/rfc9110.html#section-14) · [缓存策略规范](https://www.rfc-editor.org/rfc/rfc9111.html) · [不可变响应规范](https://www.rfc-editor.org/rfc/rfc8246.html)

以最大真实包和至少两个网络环境测冷缓存与热缓存，记录响应状态、回源率、吞吐、耗时和截断失败。选 CDN 时核对当前套餐的最大缓存对象、Range 行为和流量预算。大文件走对象存储时，可将它放到相同下载域名的后端路由中，保留当前发布器的同源、无重定向校验。即使边缘不能缓存某个大包，也要以真实整包 GET 判定能否交付。 [Cloudflare Range 行为参考](https://developers.cloudflare.com/cache/reference/range-requests/)

## 上线验收和回退

1. **验证 Nginx 并准备发布。** 安装测试虚拟主机和路由片段，校验配置后再重载。先执行发布器的 `prepare` 和 `plan`，记录文件数量、SHA-256、盘量和预期前一版本。联合更新的 `inspect` 可读回远程状态。下载和验收报告也要预留本机空间。
2. **经真实域名验证。** 在授权测试环境用外网解析访问 CDN 下载入口。确认 TLS 域名与证书链匹配、当前清单和签名可读、候选版本整文件摘要一致、整包 HEAD 和 Range 通过。检查缺失路径、暂存路径、写方法和源站旁路均符合上面的预期。保留日志和发布报告。
3. **提升指针后验证真实客户端。** 联合更新发布器整文件公网核对通过后才提升 `current`，再读回活动清单和签名。整包发布器独立验证下载文件后切换下载目录。旧的独立原生发布器使用不同顺序，应独立安排发布窗口和回退演练。用对应平台的安装包冷启动，验证下载、挂载、游戏就绪确认和存档读回。
4. **先恢复服务，再追踪故障。** 提升后读回失败时，按发布器报告确认是否恢复旧指针。保留旧版本目录、失败证据及对应清单，核对锁的所有者和冻结计划后才按 `resume` 恢复同一次发布。客户端可能已经接受较高版本并有防降级约束，这时用新版本 ID 发布经签名且存档兼容的恢复构建。故障启动的本地回退和服务端指针回退分别验收。

DNS 切换前保存旧记录、旧边缘规则和上一套可用源站配置。网络问题用这些已知配置恢复，考虑已有 DNS 缓存的存活期，再从外部网络重新读回。应用版本问题走已签名的恢复发布。试运行结束后保留清单签名、完整公网下载报告、客户端启动与回退记录，并归档当天的 DNS、TLS 和边缘规则摘要。 [双端交付的验证范围](https://github.com/GORXE111/UE-Game-Dev-Infrastructure/blob/2d0654e54b78aeed17161747c6deedb9dce3d0b1/docs/verification-scope.md)

### 外网探针示例

在外部 Windows 机器上运行，先换成自己的测试域名、渠道及已发布的测试包。探针用于查看响应，正式验收以发布器整文件读回报告和客户端记录为准。

```powershell
$downloadName = 'updates.example.com'
$channel = 'v107-release-pc'
$downloadOrigin = "https://$downloadName"
$manifest = "$downloadOrigin/samplegame/$channel/updates/manifest.json"
$archive = "$downloadOrigin/samplegame/players/releases/test-001/SampleGame-Windows.zip"

Resolve-DnsName $downloadName
curl.exe -sS --max-time 30 -D - -o NUL "$manifest"
curl.exe -sS --max-time 30 -D - -o NUL "$manifest.sig"
curl.exe -sS --max-time 30 -I "$archive"
curl.exe -sS --max-time 30 --max-filesize 65536 -D - -o NUL -H 'Accept-Encoding: identity' -H 'Range: bytes=0-65535' "$archive"
```

清单和签名 GET 应返回 200，整包 HEAD 的 `Content-Length` 应等于已准备的文件大小。对大于 64 KiB 的测试包，Range 探针应返回 206 及 `Content-Range: bytes 0-65535/<完整大小>`。正式整包读回还要计算完整 SHA-256 并比对发布计划和旁车文件。

也可在外部 Windows 机器上用本仓库的只读脚本核对单个整包。以下命令从发布机已核验的本地 `prepared.json` 取预期值。测试域名须与该计划对应。

```powershell
$plan = Get-Content -LiteralPath 'C:/Work/TestRelease/prepared.json' -Raw | ConvertFrom-Json
$package = @($plan.catalog.packages | Where-Object platform -eq 'Windows')
if ($package.Count -ne 1) { throw 'Expected one Windows package in the prepared plan.' }
pwsh -NoProfile -File .\Adoption\Test-Download.ps1 `
  -Url ("https://updates.example.com" + $package[0].url) `
  -ExpectedSize $package[0].size -ExpectedSha256 $package[0].sha256 -RequireImmutable
```

`verified` 表示 HEAD、206、首段字节与完整 GET 一致，整包大小和摘要与发布计划一致。`blocked` 返回退出码 1 及失败阶段。脚本走直连 HTTPS 并使用系统证书信任，验证消耗一次完整下载的流量。用实际测试域名单独验收 DNS、CDN 规则、源站隔离及发布器的整批读回。

联合更新的测试渠道指针切换后，用签名生产器生成的本地副本检查活动清单、签名与指定版本目录是否一致。

```powershell
pwsh -NoProfile -File .\Adoption\Test-ReleaseFeed.ps1 `
  -UpdatesUri 'https://updates.example.com/samplegame/v107-release-pc/updates/' `
  -ReleaseId 123 `
  -ManifestPath 'C:\Work\PreparedUpdate\payload\manifest.json' `
  -SignaturePath 'C:\Work\PreparedUpdate\payload\manifest.json.sig'
```

把域名、渠道、编号和输入路径换成这次测试发布的冻结值。探针确认当前与版本化清单及签名的字节匹配，并检查缓存头。客户端验签和发行全量文件读回仍各自作为上线门槛。
