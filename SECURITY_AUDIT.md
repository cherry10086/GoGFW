# 安全审计与供应链记录

本文记录 `vps-proxy-tune.sh` 的外部参考、信任边界和已知剩余风险。记录日期：2026-09-01。

## 审计结论

- 本项目没有复制、下载或执行 `ike-sh/bbrv3-lite` 的脚本；仅在固定提交上审阅其事务、路径冻结、并发锁、基线和 qdisc 所有权设计。
- 对所审快照未发现明显恶意代码。该结论只描述指定提交和下列固定文件，不是对项目当前分支、历史版本、Release 制品、外部软件源或未来版本的安全担保。
- 本项目不使用第三方内核，不增加 APT 源，不导入第三方签名密钥，不自更新，也不执行远程脚本。
- `iperf3`、`mtr-tiny`、`kmod` 等依赖只允许在用户显式指定 `--install-deps` 后，通过临时隔离的 source list 从 Debian/Ubuntu 官方 HTTPS 仓库安装；系统已有的第三方 source parts 不参与该事务，`signed-by` 固定到经权限检查的发行版 archive keyring。缺少 CA 信任库或可信 keyring 时安装会 fail-closed，不降级到 HTTP 或禁用证书验证；APT 临时目录在成功、失败和信号退出路径统一清理，清理失败会保留可检测路径并报告；`mtr` 仅为可选诊断，缺少时不阻断基础测量。
- 依赖接口按 `common`、`audit`、`measure`、`apply`、`recovery` 分阶段检查；`deps install` 先模拟，只把缺失命令映射到缺失软件包，不升级已安装包。`apply --dry-run` 只要求预览依赖，不要求网络测量工具，也不创建持久状态。
- 自动调优没有黑洞检测证据时不会启用 `tcp_mtu_probing`；`somaxconn` 与 SYN backlog 分别依据监听队列和 SYN cookie/drop 证据决策。

## 权威资料

实现与文档优先依据以下上游资料，而不是“一键优化”参数表：

- [Linux IP sysctl 文档](https://docs.kernel.org/networking/ip-sysctl.html)
- [Linux `net.core` sysctl 文档](https://docs.kernel.org/admin-guide/sysctl/net.html)
- [Google BBR 上游资料](https://github.com/google/bbr)
- [ESnet iperf3 官方文档](https://software.es.net/iperf/)
- [ESnet iperf3 源码](https://github.com/esnet/iperf)
- [mtr 源码](https://github.com/traviscross/mtr)
- [systemd `sysctl.d` 顺序和覆盖规则](https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html)

Linux 内核、systemd、Google BBR、ESnet 和 mtr 的链接用于理解接口及行为。它们不代表这些组织审核或背书本项目。

## 固定的第三方参考快照

审阅对象：[`ike-sh/bbrv3-lite`](https://github.com/ike-sh/bbrv3-lite)，固定提交 [`3fdad410973e1c0484267730b3fe7aaa3ef3cc5b`](https://github.com/ike-sh/bbrv3-lite/commit/3fdad410973e1c0484267730b3fe7aaa3ef3cc5b)：

```text
3fdad410973e1c0484267730b3fe7aaa3ef3cc5b
```

该提交中主脚本标记版本为 `8.0.2`，仓库 `LICENSE` 为 MIT License。2026-08-30 通过固定 commit 的 `raw.githubusercontent.com` URL 只读取得三个文件并在本地内存中重新计算摘要；没有运行这些脚本，也没有使用 Release 或 moving branch 内容。

记录的文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `net-tcp-tune.sh` | `6778a9104dba71d1f711a5674701f267a0591be675f00f72e0cabe5d075704cf` |
| `install-alias.sh` | `3ff9c2fa362c8a763e6b8c7e2452d4d5a053f6ec145256fb1b9077893674785e` |
| `LICENSE` | `3e61aee2a10691dd78cae910d76ee179d44b610becdd2db1b5d4f7539c3b0dc1` |

复核下载文件时，应先确认 Git 提交，再在离线副本上计算：

```bash
git rev-parse HEAD
sha256sum net-tcp-tune.sh install-alias.sh LICENSE
```

哈希只提供完整性锚点，不能单独证明作者身份或代码安全；从同一个账户、域名或 Release 同时取得脚本与校验文件，不构成独立信任链。

固定快照的静态指示器复核没有发现 `eval`、base64 解码执行、`mkfs`、写入 `authorized_keys`、计划任务、矿池/挖矿关键字或常见 `nc -e` 反弹 shell。发现的网络域名限于 GitHub API/raw/release 与 XanMod 仓库；`curl`、APT、GRUB、systemd、递归删除、自更新和 `/dev/tcp` 端口探测都与其公开功能相符，但正因为这些能力扩大了 root 权限、供应链和远程失联风险，本项目不执行也不复制该实现。“未发现明显恶意代码”不是形式化证明或对运行安全性的担保。

## 对参考项目的观察

固定快照提供了值得采用的工程思路，包括：

- 修改前冻结路由和出口路径；
- 全局锁、原子写入、首次可信基线与逐轮回滚点；
- 不接管未知 qdisc，区分本工具拥有和外部拥有的状态；
- 应用后验证，不把命令返回成功等同于配置真实生效。

本项目没有直接复用该实现，原因不是认定其为恶意项目，而是其功能和信任范围大于本工具：

- 部分流程涉及 XanMod/第三方内核和软件源；
- 外部仓库密钥若未固定、人工核对指纹，仓库 TLS 或账户本身会成为单点信任；
- 软件源链路中出现 HTTP 时，即使软件包最终带签名，元数据获取和错误配置仍增加攻击面；
- 安装器、自更新器、Release 资产和校验值若来自同一发布主体，无法抵御发布账户被接管；
- DNS、IPv6、内核、全局整形等广范围改动超出普通用户态代理调优的最小权限原则。

因此，本项目只保留能够在发行版现有内核和本机标准工具内完成的最小变更。

## 明确排除的供应链路径

以下类别或项目形态未被采用，也不应为了“更高版本 BBR”混入本项目流程：

- XanMod、BBRv3、BBRplus、魔改内核或社区 ARM64 内核的一键安装项目；
- `curl | bash`、`wget | sh`、Bash process substitution 直接运行远程内容；
- GitHub `main`/`master` moving branch、URL 缩短服务、第三方 GitHub 加速/反向代理；
- 无固定版本、无可独立验证摘要的 Release 二进制或 `.deb` 包；
- 自动替换 DNS、关闭 IPv6/防火墙、修改 SSH 或 bootloader 的综合“一键优化”脚本；
- 公共随机 `iperf3` 对端作为无人值守调优的可信输入。

这是一项范围和供应链风险决策，不是对任何未逐一审计项目作恶意判断。

## 本项目的安全控制

### 输入与网络

- peer、地址族、端口、预算、run ID 和 systemd unit 使用严格白名单和值域检查；它们不会被 `eval` 或当作 shell 代码执行。
- 主动测量只连接用户明确给出的 peer；主机解析结果和实际路由在测量前冻结，漂移会降低置信度。
- peer 的 `iperf3` JSON、MTR 输出和系统命令输出都按不可信数据解析。
- TCP 重传只读取 `end.sum_sent`，并要求 `sender` 布尔值与 `-R` 方向一致、`retransmits` 为非负整数；缺失、非数字、负值或方向无法证明时保存 `retransmits_known=false` 与 JSON `null`，不转换成零。四项 TCP 必要测试任一未知都会使质量为 `unknown`、置信度为 `low`，阻止 `apply/auto`；应用后复测任一未知会回滚。
- 测量有总流量预算，设计目标为实际传输不超过预算的 102%。

### 最小写入面

- 只管理项目专属 sysctl 文件、必要的 modules-load 文件、显式指定服务的 drop-in 和 `/var/lib/vps-proxy-tune/`。
- 不调用 `sysctl --system`，避免重放或触发无关管理员配置。
- 扫描所有 sysctl 配置层级；发现其他文件定义目标 key 时拒绝覆盖。
- 重写已有工具所有权标记的 sysctl 文件时保留旧版本留下的非目标项；非目标项无法无歧义解析时拒绝继续，避免升级过程静默删除配置。
- 有效 sysctl 配置集合为空时返回空集合；仍保留 `/dev/null` mask、优先级、重复定义和冲突检查。fresh qdisc 只有 RX/TX 都是单队列、root qdisc 在白名单内且不存在 class/filter 时才可进入 live 替换；`4/1`、`1/4` 等多队列组合均拒绝。
- `tcp_mtu_probing` 没有明确黑洞证据时只记录原值和原因，不生成启用变更；监听队列和 SYN 队列分别基于证据触发，普通 ListenOverflow 不会单独扩大 `tcp_max_syn_backlog`。
- 服务限制读取 soft/hard 任一为空、未知、`infinity` 矛盾或 soft 大于 hard 时 fail-closed；不会抬高 hard，soft 不超过现有 hard。`daemon-reload` 后复核 systemd manager 值，并尽可能读取实际服务的 `/proc/<MainPID>/limits`，不把未重启进程误报为已生效。
- `verify` 对事务记录的 sysctl、modules-load 和服务 drop-in SHA-256 重新计算并比较，检测应用后的持久化文件漂移。
- 不修改 DNS、SSH、防火墙、IPv6、转发、软件源、代理配置、内核或 bootloader。

### 事务和恢复

- 第一次修改前建立不可覆盖的可信 baseline；每轮另存 manifest、摘要和运行时状态。当前格式的 baseline 还保存受哈希保护的 `identity.tsv`，绑定 baseline 文件的 inode、权限和内容，并拒绝未列出的额外文件。
- v1 状态升级只在首次需要创建或写入状态时写入私有 `state-format=2`、`state.meta` 及其 sidecar；只读查询不为迁移而写盘，也不重写历史 run/事务。旧事务仍必须通过现行 manifest、权限和所有权检查，不能证明时 fail-closed。
- 生成的配置、systemd 材料和事务元数据带稳定的 owner/format/writer 标识；v2 状态指针/registry/版本文件、事务 `meta.tsv`、`status`、`changes.tsv`、`apply.warnings`、`apply.json`、owned 文件快照、恢复脚本/单元的哈希记录还绑定 inode 和权限。未知版本、缺失或不匹配的所有权标记、哈希、inode 或权限漂移都禁止覆盖、删除或恢复；旧格式只读兼容。
- baseline 所有权只从当前经认证的 `current_run` 指针沿 `PREVIOUS_RUN` 链建立；头部只能是 `committed`/`pending-confirm`，更早节点只能是 `committed`。已回滚、链外和不可达历史记录永远不参与卸载授权；卸载删除指针前暂存该链证明，删除后只用它验证 LIFO 回滚完整且快照未变，绝不把已回滚记录重新当作漂移授权，因此管理员后来写回相同历史值也不会被误覆盖。
- 使用 `flock` 串行化修改，使用同目录原子替换持久化文件。
- 先逐项应用并核对运行时 sysctl，验证后才提交持久化文件。
- 每次确认、回滚、恢复或卸载都会重新验证完整事务链；崩溃后只允许接管当前事务，或接入一个明确链接到已提交 head 的孤儿事务，其他孤立提交、未知目录和损坏快照均 fail-closed。
- 实时 qdisc 只在 `fresh` 模式和白名单拓扑中允许；先建立 180 秒 systemd 回滚守卫，守卫不可用则不执行 live qdisc，也不持久化未实测的 `fq`。
- `fresh` 预检通过后若到 live 替换前发现 qdisc/接口拓扑竞态，整轮事务直接回滚，不会把未执行的 pacing 变更写入持久化 sysctl。
- qdisc 启动恢复单元是 `network-online.target` 的 consumer：单元保留 `Wants=`/`After=network-online.target`，但 `[Install]` 只使用 `WantedBy=multi-user.target`。安装/补偿会认证并清理旧版 `network-online.target.wants` 链接；无法认证的链接不接管。
- 应用复测只使用原 run 测速预算的剩余量，并且只连接已经冻结的 peer；TCP profile 复测双向 TCP，`mixed` profile 另外复测双向 UDP。测量资格判断与应用后的 5–30 秒复测共用同一预算函数，避免两阶段参数漂移。性能或一致性验证失败时恢复本轮开始前状态。
- 应用在复测通过后进入 `pending-confirm`，只有显式 `confirm --run` 才提交；每个 pending transaction 保存哈希校验的 guard-script 快照，恢复执行该快照而不是当前可能已升级的脚本。超时或重启由 systemd 守卫/启动恢复单元接管回滚。
- 持久恢复分为配置/sysctl 与 qdisc 两阶段：前者位于 `systemd-sysctl.service` 前，后者由 `multi-user.target` 拉起并在 `network-online.target` 后只做有限重试。baseline 保存可恢复的运行时数据和 qdisc fingerprint/spec；qdisc 恢复失败保持 `rollback-failed`，不能报告为成功。apply 会把 baseline、恢复单元旧文件/哈希/启用链接和事务暂存纳入补偿流程；未能完全清理时保留 root-only、可校验的事务或恢复 marker，供 `status/recover` 检测，而不是静默丢弃证据。apply、measurement、timeout 的子进程按经过身份校验的进程树清理，避免遗留 `iperf3`/`ping`。
- `apply --dry-run` 不创建 `current_run`、锁或事务；`verify --scope config|path|all`、`history list` 与显式 `history prune --keep N --yes` 分离读写范围。清理只触碰重新验证所有权和 manifest 的历史 run，不触碰当前运行、pending transaction、baseline 或漂移证据。
- 回滚遵循 LIFO，不允许越过当前事务直接恢复旧 run。无法证明目标或基线可信时 fail-closed。

新建 baseline 删除失败时写入固定命名、root-only、单行的 cleanup marker；`recover` 只在重新认证对应事务后重试，其他命令 fail-closed 并保留证据。其他补偿失败也保留可校验的事务或恢复 marker，供 `status/recover` 检测，而不是静默丢弃证据。

### 权限

- 状态目录为 root 所有、权限 `0700`；快照可能包含接口、路由和服务元数据，不应向普通用户公开。
- 进入 `apply`、复制回滚守卫之前，主脚本必须是 root 拥有、非符号链接的普通文件，并且从 `/` 到脚本的每级父目录都不得由 group/other 写入；推荐安装到 `/usr/local/sbin/vps-proxy-tune`。`rollback`/`uninstall` 不复制或启动新守卫，未设置同等源路径门禁，但仍应从该受保护安装路径执行。
- `audit`、`measure`、`plan` 不应写入系统配置；`apply`、`rollback`、`uninstall` 才进入 root 写入路径。
- 指定服务的 drop-in 不触发自动重启，管理员必须在维护窗口显式决定何时加载。

## 威胁模型与剩余风险

本工具降低误配置和常见供应链风险，但不能消除以下风险：

- **远程失联：** sysctl/qdisc、内核实现差异或云厂商虚拟网络仍可能造成 SSH 中断；系统断电也可能阻止守卫完成回滚。
- **测量偏差：** 单个对端、单个时段不能代表中国大陆所有运营商；恶意或过载 peer 可以伪造低质量结果。低置信度会阻止自动应用，但无法证明 peer 诚实。
- **带宽费用：** TCP profile 有四类、`mixed` profile 有六类 `iperf3` 测试，可能消耗接近所设预算的双向流量，云厂商可能分别计费。
- **发行版信任：** 官方仓库、系统内核和已安装命令仍属于信任基础；若它们已被攻陷，本工具无法建立独立安全性。
- **root 权限：** 应用必须以 root 运行。已有恶意 root、被篡改的脚本或可写入 root `PATH` 的攻击者不在防护范围内。
- **宿主机限制：** OpenVZ/LXC 或云平台可能让 sysctl 表面写入成功但实际不可控，或在重启后由宿主机覆盖。
- **并行业务变化：** 测量和验证之间的流量、路由或代理负载变化可能影响结论；检测到的漂移会拒绝自动应用，但不能覆盖所有竞态。
- **qdisc 指纹窗口：** `tc qdisc replace` 已由内核接受、但变更后指纹尚未落盘时若进程或主机立即崩溃，守卫无法证明当前 `fq` 属于本工具。为避免覆盖未知管理员状态，恢复会 fail-closed、保留 `rollback-failed`，并要求通过带外控制台核对事务 `meta.tsv` 中的 `QDISC_IFACE`、`QDISC_BEFORE`、`QDISC_BEFORE_SPEC`、`QDISC_BEFORE_HASH` 后人工恢复。

上线前仍应创建云平台快照，保持带外控制台可用，并先以 `safe --dry-run` 检查计划。

## 验证边界

Windows 本地环境只能完成文件级静态审阅，不能证明 Bash/Linux 的特权 `apply`、systemd 回滚守卫、真实重启恢复、真实服务 `LimitNOFILE` 或 network-online 后 qdisc 重试。只有 Linux CI 的 `bash -n`、ShellCheck、完整单元测试、JSON/CLI smoke 和 privileged netns，以及 disposable systemd VM 的真实 pending-confirm 重启回滚、qdisc graph、网络晚到、进程中断、timeout、confirm、漂移和 uninstall 全部通过后，才可声明运行时安全；任何一项未运行或失败都只能报告为未验证。

## 复审要求

出现以下任一情况时，应更新本文并重新审计：

- 增加新的网络目的地、下载器、软件源或自动更新功能；
- 引入第三方内核、二进制制品或新的 root 依赖；
- 扩大受管 sysctl、qdisc 或 systemd 文件范围；
- 改变 peer 输入、JSON 解析、原子写入或回滚守卫实现；
- 更新上述参考提交或任一 SHA-256。
