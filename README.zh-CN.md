# VPS Proxy Tune

`vps-proxy-tune.sh` 是一套面向日本、美国等跨境 VPS 的保守型 TCP/UDP 网络调优工具，适用于以 Xray、sing-box 等普通用户态代理为主要负载的服务器。它不按机房国家套用固定“神参数”，而是根据 VPS 到你自有 `iperf3` 对端的 RTT、吞吐、重传、UDP 丢包、负载延迟和主机资源生成建议。TCP 重传只有在 `iperf3` JSON 明确证明发送方向且计数为非负整数时才会采用；否则报告为 `null`/`unknown`，不会伪装成零。

默认策略是生产安全优先：只使用当前发行版内核已经提供的标准 BBR，不安装 XanMod、BBRv3/BBRplus 内核，不下载或执行第三方脚本，也不会自动重启代理服务或 VPS。`mixed` profile 会在 TCP 四项测试之外增加双向 UDP 测试，作为 QUIC/UDP 用户态代理路径的近似观测；它不会创建 TUN、NAT 或防火墙规则。

> **重要：** sysctl 和 qdisc 的修改可能影响吞吐、延迟，极端情况下也可能中断远程连接。首次应用前请创建 VPS 快照，保留一个独立的管理会话，并先执行 `audit`、`measure` 和 `plan` 阅读结果。

## 支持范围

| 系统 | 架构 | 支持状态 |
| --- | --- | --- |
| Debian 12 / 13 | amd64、arm64 | 支持 |
| Ubuntu 22.04 / 24.04 / 26.04 | amd64、arm64 | 支持 |
| OpenVZ、受限 LXC | 视宿主机权限而定 | 可审计；不可安全写入时拒绝应用 |
| 非 Debian/Ubuntu、非 systemd 系统 | 任意 | 不支持自动持久化 |

需要 Bash 4.4 或更新版本。应用、回滚和卸载必须以 root 运行；只读命令仍可能因为状态目录权限而需要 `sudo`。

本工具适合普通用户态代理。TUN、WireGuard、透明代理、NAT 网关、路由器或多层自定义流量控制不在自动调优范围内。

## 依赖

工具使用发行版提供的命令和软件包：

- `bash`、`coreutils`、`diffutils`（`cmp`）、`grep`、`sed`、`awk`；
- `ca-certificates`，用于验证官方 APT HTTPS 仓库（极简系统应预先安装，工具不会降级到 HTTP）；
- `iproute2`（`ip`、`ss`、`tc`）；
- `iputils-ping`，用于端到端 RTT/丢包采样；
- `procps`（`sysctl`）；
- `util-linux`（`flock`）；
- `systemd`（`systemctl`、`systemd-run`），用于应用守卫和跨重启恢复；
- `iperf3`，用于主动吞吐测试；
- `jq`，用于严格读取 `iperf3` JSON；
- `mtr-tiny`，用于端到端路径辅助观测（缺少时仍可完成基础测量）；
- `kmod`（`modprobe`），仅用于加载当前发行版内核已经提供的标准 BBR/`sch_fq` 模块。

缺少依赖时，工具默认仅报告缺失项。可先按阶段检查：

```bash
sudo /usr/local/sbin/vps-proxy-tune deps check --phase common
sudo /usr/local/sbin/vps-proxy-tune deps check --phase measure --json
```

只有显式执行 `deps install`（或使用现有命令的兼容参数 `--install-deps`）才会通过临时、隔离的 APT 配置访问 Debian/Ubuntu 官方 HTTPS 仓库；安装前先模拟，只传入缺失命令对应的软件包，不升级已安装的软件包。该配置不加载系统已有的第三方 source parts，并以 `signed-by` 固定到本机 root 拥有且不可由 group/other 写入的发行版 archive keyring，临时索引和缓存使用后删除。它不会持久增加软件源、导入第三方密钥或下载预编译内核。

官方 HTTPS 安装要求系统已存在 `/etc/ssl/certs/ca-certificates.crt`。极简镜像缺少该信任根时，工具会 fail-closed：请先通过云厂商可信控制台、镜像构建流程或受信任的离线包安装 `ca-certificates`，再重试 `--install-deps`；工具绝不会为自举而降级到 HTTP 或关闭证书验证。

建议先在自有中国大陆服务器上启动对端：

```bash
sudo apt-get install iperf3
iperf3 -s -p 5201
```

仅开放测试所需端口，并用防火墙限制为 VPS 的源 IP。不要把公共、未知或不受你控制的 `iperf3` 服务用于自动决策。

## 快速开始

先把审核过的脚本安装到 root 拥有、不可由普通用户写入的固定路径，再做只读审计：

```bash
sudo install --owner=root --group=root --mode=0755 \
  ./vps-proxy-tune.sh /usr/local/sbin/vps-proxy-tune
sudo /usr/local/sbin/vps-proxy-tune audit
```

`apply` 会验证脚本及其所有父目录的所有权和写权限；直接从普通用户可写目录执行会 fail-closed。这是为了保证复制进回滚守卫的代码在应用期间不能被替换。应用后事务先进入 `pending-confirm`，默认 180 秒内必须执行 `confirm`；超时由 systemd 守卫自动回滚。`rollback`/`uninstall` 不会启动新的守卫，但仍建议始终使用同一个受保护的安装路径。

`audit` 只读检查发行版/架构、虚拟化和容器限制、CPU/内存、默认路由、接口/MTU/队列、root qdisc、TCP 拥塞控制、softnet、监听队列、conntrack 以及目标 sysctl 的其他定义来源。

对自有对端执行测量。可重复传入 `--peer`，默认总流量预算为 1024 MiB，最大 4096 MiB：

```bash
sudo /usr/local/sbin/vps-proxy-tune measure \
  --peer 203.0.113.10:5201 \
  --peer iperf.example.cn:5201 \
  --family auto \
  --profile tcp \
  --budget-mib 1024
```

需要同时观察 QUIC/UDP 路径时使用 `--profile mixed`；每个 peer 至少预留 6 MiB，预算会按测试数量分摊：

```bash
sudo /usr/local/sbin/vps-proxy-tune measure \
  --peer 203.0.113.10:5201 --family auto --profile mixed --budget-mib 1024
```

上面的 `203.0.113.10` 是文档保留地址，运行时必须替换成你实际控制的 `iperf3` 服务器 IP 或域名。

记录输出中的 `run_id`，生成计划但不写系统：

```bash
sudo /usr/local/sbin/vps-proxy-tune plan --run RUN_ID
```

生产 VPS 推荐使用 `safe`：

```bash
sudo /usr/local/sbin/vps-proxy-tune apply --run RUN_ID --mode safe
# apply 成功复测后会返回 pending-confirm（退出码 20）
sudo /usr/local/sbin/vps-proxy-tune confirm --run RUN_ID
sudo /usr/local/sbin/vps-proxy-tune verify
```

只有确认这是没有自定义 qdisc 的新 VPS 时，才考虑 `fresh`：

```bash
sudo /usr/local/sbin/vps-proxy-tune apply --run RUN_ID --mode fresh
```

交互式一体流程会依次执行审计、测量和计划，并在应用前展示确认：

```bash
sudo /usr/local/sbin/vps-proxy-tune auto \
  --peer 203.0.113.10:5201 \
  --budget-mib 1024 \
  --mode safe
```

只有高置信度结果才具备自动应用资格。`--yes` 用于明确授权无人值守应用；低置信度、配置冲突、未知 qdisc 或任一 TCP 必要测试的重传计数未知，即使指定 `--yes` 也不会被绕过。`plan`/`apply`/`rollback` 的 `--dry-run` 只读取已有 run 和系统状态，不创建状态目录、锁文件或持久化配置；`auto --dry-run` 为了展示完整链路会在 `/tmp` 私有目录中实际测量，结束后自动清理。先用它查看所有拟议动作：

```bash
sudo /usr/local/sbin/vps-proxy-tune auto \
  --peer 203.0.113.10:5201 \
  --mode safe \
  --dry-run
```

需要为某个 systemd 代理服务提高文件描述符上限时，可在应用阶段指定 unit：

```bash
sudo /usr/local/sbin/vps-proxy-tune apply \
  --run RUN_ID \
  --mode safe \
  --service sing-box.service
```

unit 名称会经过严格校验。工具只创建独立 drop-in：先同时读取 systemd 的 soft/hard `LimitNOFILE`，任一为空、未知、矛盾（包括 soft 大于 hard）都 fail-closed；不自动抬高 hard，soft 始终不超过现有 hard，目标上限为 `min(262144, fs.nr_open)`。`daemon-reload` 后会重新核对 systemd manager 值，并尽可能读取实际服务 `/proc/<MainPID>/limits`；已运行进程不会被假装成已经更新，报告会明确记录实际观察值。工具不会改代理配置，也不会自动重启服务；需在维护窗口由管理员自行重启后才会生效。`apply --dry-run` 的人类可读输出和 JSON 都会显示当前值、目标值、drop-in 路径及“不会重启”的事实；交互应用会在确认提示前再次展示，并在确认后拒绝任何服务状态漂移。

## 命令接口

```text
vps-proxy-tune.sh audit [--json] [--dry-run] [--install-deps]
vps-proxy-tune.sh measure --peer HOST[:PORT] [--peer HOST[:PORT] ...]
                          [--family auto|4|6] [--profile tcp|mixed] [--budget-mib MiB]
                          [--json] [--dry-run] [--install-deps]
vps-proxy-tune.sh plan --run RUN_ID [--json] [--dry-run] [--install-deps]
vps-proxy-tune.sh apply --run RUN_ID [--mode safe|fresh]
                        [--service UNIT] [--yes] [--dry-run] [--json]
                        [--install-deps]
vps-proxy-tune.sh auto --peer HOST[:PORT] [--peer HOST[:PORT] ...]
                       [--family auto|4|6] [--profile tcp|mixed] [--budget-mib MiB]
                       [--mode safe|fresh] [--service UNIT]
                       [--yes] [--dry-run] [--json] [--install-deps]
vps-proxy-tune.sh verify [--scope config|path|all] [--json]
vps-proxy-tune.sh deps check|install [--phase common|audit|measure|apply|recovery|all]
                          [--dry-run] [--yes] [--json]
vps-proxy-tune.sh status [--json]
vps-proxy-tune.sh history list [--limit N] [--json]
vps-proxy-tune.sh history prune --keep N [--yes|--dry-run] [--json]
vps-proxy-tune.sh rollback [--run RUN_ID] [--dry-run] [--json]
vps-proxy-tune.sh confirm --run RUN_ID [--json]
vps-proxy-tune.sh recover [--run RUN_ID] [--phase all|config|qdisc] [--boot] [--json]
vps-proxy-tune.sh uninstall [--dry-run] [--yes] [--json]
```

通用说明：

- `--json` 输出便于自动化读取的报告；报告包含 `schema_version`、`run_id`、环境、冻结路径、原始指标、质量评级、置信度、推荐值、实际变更、警告与回滚状态。操作结果固定提供 `outcome`（`ok`、`pending_confirm`、`blocked`、`failed`、`rolled_back`、`rollback_failed`）和 `reason_code`；错误、阻止、成功回滚和回滚失败也会输出合法 JSON。
- `plan`/`apply`/`rollback` 的 `--dry-run` 只显示计划动作，不修改运行时 sysctl、qdisc、锁、状态目录或持久化文件，并要求目标 run 已经存在；`apply --dry-run` 只检查预览所需的文件命令和 `jq`，不要求 `ping`/`iperf3`/测量依赖；`measure --dry-run` 只做依赖和参数预检，不发送网络请求也不创建 run。
- `verify` 是只读一致性检查，只接受 `--scope` 和 `--json`；`verify --dry-run` 没有额外语义，会被明确拒绝。测量报告中的 `metrics.retransmits_known=false` 或 `metrics.retrans_pct=null` 表示 TCP sender 方向/计数器无法证明，`apply` 和 `auto` 必须保持零变更。
- `deps check` 按 `common`、`audit`、`measure`、`apply`、`recovery` 阶段报告缺失依赖；`deps install` 先模拟，只安装缺失包，不升级已有包。`--install-deps` 仍是 `audit`、`measure`、`plan`、`apply` 和 `auto` 的兼容入口。
- 为保证 dry-run 本身零系统写入，`--dry-run` 与 `--install-deps` 互斥；请先单独显式安装依赖，再执行 dry-run。
- `auto --dry-run` 会在 `/tmp` 下创建私有临时状态，实际测量仍只连接指定 peer；测量、计划和应用预览结束后临时目录会被删除，不会写入 `/var/lib/vps-proxy-tune` 或 `/run`。
- `RUN_ID` 必须来自本机已完成的运行记录，不能是任意路径。

## 测量与决策方式

测量前，工具会冻结每个 peer 的解析 IP、地址族、源地址、默认出口设备和路由指纹，并记录 boot ID、network namespace、kernel 和 monotonic 时间。解析或路由在运行中发生变化、ECMP 无法确定、服务端 busy、测试不完整或测量跨越重启/超过 1 小时，都会降低置信度并阻止自动应用。

在总预算内执行单流上传、单流反向下载、四流上传和四流反向下载；`mixed` 再增加单流双向 UDP。每项测试时长按该 peer 的 RTT 自适应为 5–30 秒（约覆盖 30 个 RTT，且有上限）；每项 iperf 负载最多分配该 peer 预算的 70%/测试数量，并预留 5% 的传输速率余量。最终的 102% 硬上限按接口字节计数，包含 MTR、空载/负载 ping 和测速流量。工具同时观测：

- RTT p50/p95、抖动与目标端丢包；
- UDP 丢包率、jitter 和成功测试数（服务端未返回 UDP 计数时显示为不可用）；
- loaded RTT 和空载 RTT 的增量；
- `iperf3` sender 方向已证明时的重传次数与估算 TCP 段数之比；缺失、非数字、负值或方向不一致时保留为 unknown，不参与质量计算；
- `/proc/net/softnet_stat` 增量；
- CPU busy/steal 与测试外的接口流量。后台流量同时由空载窗口和测速期间超过测试字节加 10% 协议余量的部分估算，并取较差值。

中间路由器不响应 ICMP 或对 ICMP 限速，不会直接被认定为端到端丢包。高置信度要求 TCP 四类测试成功且四项重传计数都已知；`mixed` 还要求 UDP 测试成功并能获得有效结果；同时路径稳定、稳态吞吐变异系数不高于 15%、后台流量不高于测试速率的 10%、CPU steal 低于 10%，并且存在可用的 TCP 或 ICMP RTT。

质量分级使用固定阈值：目标端丢包低于 0.5%、loaded RTT 增量不超过 20 ms、估算重传低于 0.5% 时为 `good`；任一项分别高于 2%、80 ms、2% 时为 `poor`；其余为 `fair`。如果重传计数未知，整体质量为 `unknown`，不使用内部零值代替。估算重传率用于比较调优前后的相对变化，不等同于抓包得到的真实丢包率。

缓冲上限按每条可信路径计算：

```text
BDP(bytes) = 单流有效吞吐(Mbit/s) × RTT p95(ms) × 125
目标上限   = 向上取 2 的幂(2 × BDP)，最低 4 MiB
```

目标还受内存限制：小于 1 GiB 为 4 MiB，1–2 GiB 为 8 MiB，2–4 GiB 为 16 MiB，4–8 GiB 为 32 MiB，8 GiB 及以上为 64 MiB。工具只会提高 `tcp_rmem`/`tcp_wmem` 的第三项和 `rmem_max`/`wmem_max`，不会因为一次低速测量下调管理员现有值。

## `safe` 与 `fresh`

| 行为 | `safe`（默认） | `fresh` |
| --- | --- | --- |
| 标准 BBR 可用时配置拥塞控制 | 是 | 是 |
| 设置首选默认 qdisc 为 `fq` | 仅当前已是 `fq`；否则只报告并跳过 | 仅在当前已是 `fq` 或 live 验证成功时 |
| 立即替换当前 root qdisc | 否 | 仅在确认安全时 |
| 允许精确匹配系统默认参数的单队列 `fq_codel` 转为 `fq` | 否 | 是 |
| 接管 `mq`、`noqueue`、HTB、CAKE、未知 class/filter | 否 | 否 |
| 适用场景 | 正在承载业务的 VPS | 没有自定义流控的新 VPS |

`fresh` 的实时 qdisc 修改还要求：单队列、无 class/filter，并且当前 `fq_codel` 精确匹配可证明的默认参数，或 `pfifo_fast` 精确匹配默认 3-band/priomap；随后必须先建立 180 秒 systemd 回滚守卫，并在复测成功且 `confirm` 后才提交。现有 `fq` 无需替换；预检时字段缺失、定制参数、`mq`、`noqueue`、HTB、CAKE 或未知拓扑会跳过该 pacing 提案。若预检后到 live 替换前发生拓扑竞态，整轮 apply 会回滚，避免留下未实测的 `fq` 持久化。守卫无法建立时，实时 qdisc 修改和未实测的 `fq` 持久化都会被拒绝。

应用后会使用该 run 在 `--budget-mib` 中尚未消耗的余额，对测量时按“单流有效吞吐 × RTT p95”选出的 peer 执行上传/反向下载；`mixed` 还复测双向 UDP。验证速率为基线吞吐的 105%，测试时长继续使用 RTT 推导的 5–30 秒；最多预留原预算的 45%，并按 2 个（TCP）或 4 个（mixed）测试均分。若余额不足以在不受限速偏差影响的情况下复测，置信度会先降为 `low`，因而不会开始应用；运行中预算或路径发生漂移仍会触发回滚。全过程继续按接口字节执行 102% 总硬上限。吞吐下降超过 15%、loaded RTT 增加超过 30 ms、重传估算超过基线两倍、UDP 丢包超过基线两倍，或任一配置不一致时，本轮修改自动回滚。

## 工具可能修改的内容

在检测、置信度和冲突检查全部通过后，工具只管理：

- `/etc/sysctl.d/90-vps-proxy-tune.conf`；
- 必要时的项目专属 modules-load 文件；
- 指定 systemd 服务的项目专属 drop-in；
- 权限为 `0700` 的 `/var/lib/vps-proxy-tune/` 状态、基线和运行记录；
- `fresh` 模式中符合白名单条件的出口 root qdisc。

sysctl 变更限于经过计划的 socket/TCP 缓冲上限、`tcp_moderate_rcvbuf`、可用时的标准 BBR/`fq`，以及有持续证据时的监听队列或 `netdev_max_backlog`。`tcp_mtu_probing` 只审计并保留原值；没有明确的端到端黑洞检测证据时不会生成启用变更。监听队列只在三段观测中至少两段同时出现合法负载下的 ListenOverflow/Drop 且队列达到 80% 时逐级提高；SYN backlog 还必须有 SYN cookie/drop 证据，不能由普通 ListenOverflow 单独触发；softnet dropped 持续增长且可用内存超过 20% 时才提高 `net.core.netdev_max_backlog`，自动上限为 10000。

写入前会扫描 `/etc/sysctl.conf` 和全部 `sysctl.d` 层级。其他本地配置已定义目标 key 时会拒绝覆盖并显示来源，不会依赖 `sysctl --system` 重放管理员的其他配置。

## 明确不会修改的内容

本工具不会修改或安装：

- `tcp_mem`、`udp_mem`、TIME_WAIT、TCP Fast Open、ECN、keepalive；
- RPS/RFS、网卡 offload、IRQ affinity；
- IP 转发、`rp_filter`、IPv6 开关；
- DNS、SSH、防火墙、代理软件配置；
- conntrack（普通用户态代理不需要调整）；
- 软件源、swap、bootloader；
- XanMod、BBRv3、BBRplus 或任何其他第三方内核；
- ingress shaping、IFB、NAT、透明转发规则。

它不会执行 `curl | bash`，不会从 GitHub moving branch 或第三方 GitHub 代理下载代码，不会运行下载的二进制。除显式安装官方仓库依赖外，主动网络连接只发往你通过 `--peer` 指定的地址。

## 状态、验证与恢复

查看当前状态和持久化一致性：

```bash
sudo /usr/local/sbin/vps-proxy-tune status
sudo /usr/local/sbin/vps-proxy-tune verify --scope all
sudo /usr/local/sbin/vps-proxy-tune history list --limit 20
```

`verify --scope config` 只检查 sysctl、owned 文件、服务 drop-in 和持久恢复材料；`path` 只检查 qdisc 指纹、冻结路由和地址解析；默认 `all` 同时检查两类。`history prune --keep N --yes` 只清理经过所有权、权限、无符号链接和 manifest 校验的安全历史 run；清理前会保护 `current_run`、所有 pending transaction、baseline、漂移或无法解释的文件，先用 `--dry-run` 预览。

`apply` 完成运行时写入和复测后不会立即把事务标记为永久提交，而是返回退出码 `20` 并进入 `pending-confirm`。确认管理连接、sysctl、qdisc 和服务状态都正常后执行：

```bash
sudo /usr/local/sbin/vps-proxy-tune confirm --run RUN_ID
```

未在 180 秒内确认时，systemd 回滚守卫会恢复本轮变更；主机在事务中途重启时，持久恢复分两阶段：`systemd-sysctl.service` 前先恢复配置和运行时 sysctl，qdisc 恢复单元作为 `network-online.target` 的 consumer，在 `Wants=`/`After=` 网络在线后运行，并且只由 `multi-user.target` 拉起，不再挂入 `network-online.target.wants`。qdisc 网络未就绪或恢复失败时保留 `rollback-failed`，不会误报成功。确认、回滚、恢复和卸载都会先复核完整事务链；需要手动接管恢复时可执行 `recover --run RUN_ID --phase all|config|qdisc`，不要直接删除状态目录或锁文件。

首次可信 baseline 在任何修改前创建，完成后永不覆盖，作为卸载时的审计锚点。每轮应用另存 manifest、文件哈希、运行时 sysctl、qdisc、路由和服务状态；v2 baseline 另外保存 `identity.tsv` 及其哈希记录，绑定 baseline 文件的 inode、权限和内容，并拒绝额外文件。后续恢复按 LIFO 逐轮进行，并且只有当前 authenticated `current_run` 链上的有效事务能证明工具所有权；已回滚、链外或不可达历史事务不会重新获得授权。卸载在删除指针前暂存当前链证明，管理员把值改回历史相同值也不会因此被覆盖；全局 `flock` 防止并发写入，持久化文件使用同目录原子替换。

升级到 v2 时，首次需要创建或写入状态的流程（例如 `measure`、`plan`、`apply`）只会补写私有的 `state-format`、`state.meta` 及其 inode/权限/哈希 sidecar；只读的 `status`/`history` 不会为了查询而迁移状态，历史 run、事务和配置也不会被重写。新事务还会为 `meta.tsv`、`status`、`changes.tsv`、`apply.warnings`、`apply.json` 和 owned 文件快照保存哈希/身份记录，并在追加或原子替换后刷新。旧事务仍必须通过当前 manifest、所有权和状态校验，无法证明安全时会保留证据并拒绝自动恢复。

重写已经由本工具标记的 sysctl 文件时，会保留旧版本放在同一文件中的非目标 sysctl 项；如果这些旧项无法被无歧义解析，apply 会 fail-closed，而不是静默删除它们。

恢复当前运行之前的状态；省略 `--run` 时选择当前 run：

```bash
sudo /usr/local/sbin/vps-proxy-tune rollback --run RUN_ID
sudo /usr/local/sbin/vps-proxy-tune rollback
```

回滚严格遵循 LIFO（后进先出）。`--run` 只用于确认当前事务 ID，不能跳过较新的事务直接恢复旧 run；如需回到更早状态，必须逐轮从最新事务开始回滚。

卸载会先按事务 LIFO 恢复本工具仍能证明所有权的变更，并校验首次可信 baseline，再删除本工具拥有的持久化配置；审计和测量历史默认保留：

```bash
sudo /usr/local/sbin/vps-proxy-tune uninstall
```

交互模式要求输入 `UNINSTALL` 确认；非交互环境必须显式提供 `--yes`。卸载仍按 LIFO 回滚全部当前事务，任一步无法可靠恢复时会报告部分失败，不会宣称完整成功。

如果基线不完整、文件所有权不明或恢复目标被外部修改，工具会 fail-closed 并报告需要人工处理的路径，不会伪造“已恢复”。

实时 qdisc 存在一个很小但无法完全消除的崩溃窗口：内核已接受 `tc qdisc replace`、但工具尚未来得及记录“变更后”指纹时，如果进程或机器立即崩溃，守卫无法证明当前 `fq` 由本工具创建，因此会保守拒绝覆盖。此时需通过带外控制台检查 `tc qdisc show`，再核对对应事务 `meta.tsv` 中的 `QDISC_IFACE`、`QDISC_BEFORE`、`QDISC_BEFORE_SPEC` 和 `QDISC_BEFORE_HASH` 后人工恢复；工具会明确标记 `rollback-failed`，不会把未知状态报成成功。

如果新建 baseline 的补偿删除被中断，会留下固定命名的 root-only cleanup marker；`recover` 会在重新认证对应事务后重试，其他命令会停止并保留证据。

## 安全建议

- 应用前创建云平台快照，并保持云厂商串口/VNC 控制台可用。
- 在 `tmux`/`screen` 中运行，另开一个 SSH 会话持续观测连通性。
- 使用自有且受访问控制的 `iperf3` 对端；peer 可影响推荐结果，应视为信任边界。
- 测速可能产生接近 `--budget-mib` 的流量和费用；确认云厂商流量计费方式。
- 不要用 `--yes` 代替阅读首次计划；生产机优先 `safe`。
- 测量只代表 VPS 到指定 peer 的路径，不能保证所有中国移动、联通、电信或跨境时段都获得相同表现。

第三方代码参考和供应链边界见 [SECURITY_AUDIT.md](SECURITY_AUDIT.md)。

## 开发与测试

```bash
bash -n vps-proxy-tune.sh tests/test_unit.sh tests/integration_netns.sh tests/integration_systemd_vm.sh tests/integration_systemd_reboot.sh
shellcheck -x vps-proxy-tune.sh tests/test_unit.sh tests/integration_netns.sh tests/integration_systemd_vm.sh tests/integration_systemd_reboot.sh
bash tests/test_unit.sh
sudo bash tests/integration_netns.sh
# 仅在一次性、可销毁的真实 systemd VM 中执行；脚本默认拒绝普通主机/容器
VPS_TUNE_THROWAWAY_VM=1 sudo -E bash tests/integration_systemd_vm.sh
```

集成测试只在随机命名的 network namespace/veth 上创建 netem 延迟、抖动、丢包和限速，不访问互联网；本地缺少 namespace 权限或测试依赖时会明确跳过。CI 在原生 `x86_64` 与 `aarch64` runner 上覆盖 Debian 12/13 与 Ubuntu 22.04/24.04/26.04，并在独立 privileged job 中把 namespace 测试设为必须执行，不能静默跳过。

`tests/integration_systemd_vm.sh` 会在确认是一次性真实 systemd VM 后执行完整的
pending-confirm、guard 回滚、confirm、recover、verify、history prune、qdisc 依赖图
和卸载流程；它通过立即启动 guard service 确定性地覆盖超时回滚。真实重启必须使用
两阶段协议，避免 SSH/CI 进程在 guest 关机时把中断误判成测试结果：

```bash
# 在一次性 VM 内执行；prepare 会请求真实重启并结束当前进程
VPS_TUNE_THROWAWAY_VM=1 sudo -E bash tests/integration_systemd_reboot.sh prepare
# VM 重新上线、systemd/network-online 已启动后，在同一快照内执行
VPS_TUNE_THROWAWAY_VM=1 sudo -E bash tests/integration_systemd_reboot.sh verify
```

该协议检查 pending-confirm 的启动回滚、network-online 后 qdisc 恢复、恢复依赖图，
然后建立第二条已认证事务链并执行 confirm、verify 和 uninstall。Windows 本地环境
无法证明 Bash/Linux 的特权 `apply`、systemd 守卫、真实重启或 network-online 后
qdisc 重试；应以 Linux CI 和特权 systemd VM 的实际结果为准。后者还应覆盖中断后
的进程组清理、恢复材料漂移、v1 迁移以及“只安装缺失依赖、不升级已有包”。

## 许可证

本项目使用 MIT License，详见 [LICENSE](LICENSE)。
