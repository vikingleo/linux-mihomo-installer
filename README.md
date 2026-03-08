# mihomo-migrate

这份 `README.md` 是本仓库的**唯一施工说明**。

目标读者：

- 人工维护者
- 新机器上的 agent

本仓库当前只负责：

- 检测 `mihomo` 是否已安装；未安装时自动从官方 release 安装二进制
- 提供脱敏后的 Mihomo 配置模板，不在仓库内保存节点明文
- 运行安装脚本时交互式读取订阅地址，并渲染为实际配置
- 安装 `config.yaml` 到 `/etc/mihomo/config.yaml`
- 安装 `ruleset/` 到 `/etc/mihomo/ruleset/`
- 必要时创建 `mihomo` systemd unit
- 重启 `mihomo`
- best-effort 清理历史遗留的 `mihomo-telegram-watchdog` 用户侧脚本与 systemd 单元

本仓库**不再负责**：

- Telegram Bot API 健康检查
- 自动切线 watchdog
- OpenClaw Gateway 代理环境注入
- 用户侧运行时 policy 文件维护

这些能力现在统一由 OpenClaw 标准插件接管，例如 `network-proxy-watchdog`。

## 目标状态

施工完成后，应满足以下状态：

1. 系统存在可工作的 `mihomo` 服务。
2. `/etc/mihomo/config.yaml` 由本仓库模板渲染生成。
3. `/etc/mihomo/ruleset/` 来自本仓库的 `ruleset/`。
4. 渲染后的配置中存在 `专项代理` 代理组，供 OpenClaw 插件切换。
5. OpenClaw 已启用 Telegram 渠道。
6. OpenClaw 已启用标准插件 `network-proxy-watchdog`。
7. 插件通过 Mihomo controller API 控制 `专项代理`，而不是调用旧 shell watchdog。
8. 机器上不存在旧版 `mihomo-telegram-watchdog` 常驻链路；即使历史上装过，也应被清理。

说明：

- 若机器原本没有安装 `mihomo`，`install.sh` 会自动从官方 GitHub release 下载 Linux 对应架构的 `.gz` 二进制，并安装到 `/usr/local/bin/mihomo`
- 仓库内 `config.yaml` 是脱敏模板，安装时需要提供订阅地址
- Mihomo controller secret 默认不会写死在仓库里；脚本会优先复用已安装配置里的 secret，否则自动生成一个新的随机值

## 不要做的事

新机器施工时，**不要**再创建或恢复以下内容：

- `mihomo-telegram-watchdog.sh`
- `mihomo-telegram-watchdog.service`
- `mihomo-telegram-watchdog.timer`
- `mihomo-persist-telegram-policy.sh`
- `telegram-watchdog.env`
- `openclaw-gateway.proxy.conf`
- `secret.txt`
- 用户侧 `config.telegram-policy.yaml` 热更新方案

如果发现历史机器上仍有这些文件，它们只属于遗留兼容物，应该清理，而不是继续沿用。

## 仓库内容

本仓库应至少包含：

- `config.yaml`
- `ruleset/`
- `install.sh`
- `self-check.sh`
- `.env.example`
- `README.md`

本仓库现在不应再包含任何旧 watchdog 运行文件。
Mihomo controller secret 只在渲染后的 `/etc/mihomo/config.yaml` 与 OpenClaw 配置中保持一致，不单独维护一个 `secret.txt` 副本。

## 脱敏说明

当前仓库已按“可分发迁移包”思路做了脱敏：

- 不再在仓库内保存节点 `server` / `uuid` / `password` 等明文
- 不再在仓库内保存固定的 Mihomo controller secret
- 订阅地址不写死在仓库内，而是在安装时输入或通过环境变量传入

当前 `config.yaml` 是模板文件，其中至少包含以下占位符：

- `__MIHOMO_SUBSCRIPTION_URL__`
- `__MIHOMO_SECRET__`

安装脚本会把占位符渲染成实际值后，再写入 `/etc/mihomo/config.yaml`。

## 使用方法

在仓库目录执行：

```bash
bash install.sh
```

如果当前用户不是 root，脚本会在需要时使用 `sudo`。
如果没有通过环境变量提供订阅地址，脚本会交互式提示输入。

若你希望 agent 或 CI 走非交互方式，推荐先基于 `.env.example` 准备环境变量：

```bash
cp .env.example .env
$EDITOR .env
set -a
. ./.env
set +a
bash install.sh
```

安装完成后，建议立刻执行：

```bash
bash self-check.sh
```

它会检查：

- `mihomo` 二进制与配置校验
- `/etc/mihomo/ruleset/` 是否完整
- `专项代理` 是否可被 Mihomo controller 查询
- OpenClaw Telegram / `network-proxy-watchdog` 配置是否齐全
- 旧 watchdog 遗留是否仍存在

## 前置条件

施工前先确认：

- agent 具备写 `/etc/mihomo` 的权限（root 或 sudo）
- 已安装并可运行 OpenClaw
- OpenClaw 所在用户能够正常运行 `systemctl --user`（若该环境需要 user service）
- 机器是 Linux 且使用 systemd
- 机器可以访问 GitHub release，或你已通过环境变量指定可下载的 Mihomo 包

建议先检查：

```bash
uname -s
command -v mihomo || true
systemctl status mihomo --no-pager || true
command -v openclaw
```

若 OpenClaw 尚未安装，应先完成 OpenClaw 基础安装；`mihomo` 本身可由 `install.sh` 自动补装。

### 自动安装 Mihomo 的规则

当 `command -v mihomo` 找不到可执行文件时，`install.sh` 会：

1. 先在常见离线目录中自动查找匹配的 Mihomo `.gz` 包
2. 若未找到，再调用官方 GitHub release API 获取目标版本
3. 按当前 Linux 架构选择合适的 `.gz` 资产
4. 下载并安装到 `/usr/local/bin/mihomo`
5. 若系统不存在 `mihomo` unit，则自动创建 `/etc/systemd/system/mihomo.service`

默认行为：

- 版本：最新 release
- 二进制位置：默认 `/usr/local/bin/mihomo`；若系统已存在 `mihomo`，优先复用现有可执行文件路径
- systemd unit：`/etc/systemd/system/mihomo.service`

可选覆盖环境变量：

- `MIHOMO_VERSION`：指定版本号，如 `v1.19.20` 或 `1.19.20`
- `MIHOMO_SUBSCRIPTION_URL`：直接指定订阅地址，跳过交互输入
- `MIHOMO_SECRET`：直接指定 Mihomo controller secret；未提供时会自动生成或复用已有值
- `MIHOMO_DOWNLOAD_URL`：直接指定下载地址
- `MIHOMO_DOWNLOAD_FILE`：直接指定本地离线 `.gz` 包路径
- `MIHOMO_DOWNLOAD_MIRROR_PREFIXES`：下载镜像前缀列表，支持逗号或分号分隔；脚本会在官方 URL 失败后依次重试
- `MIHOMO_OFFLINE_SEARCH_DIRS`：离线包自动扫描目录列表，支持冒号、逗号或分号分隔
- `MIHOMO_ASSET_NAME`：指定 release 资产名
- `MIHOMO_RELEASE_URL_BASE`：指定 release 下载基础地址，默认 `https://github.com/MetaCubeX/mihomo/releases`
- `MIHOMO_BIN`：指定安装后的二进制路径
- `MIHOMO_SYSTEMD_UNIT`：指定 systemd unit 文件路径

如果目标机器无法直接访问 GitHub，可按下面优先级提供 fallback：

1. 最先：自动扫描 `MIHOMO_OFFLINE_SEARCH_DIRS` 中的本地离线包
2. 最稳妥：提供 `MIHOMO_DOWNLOAD_FILE`
3. 次优：提供 `MIHOMO_DOWNLOAD_URL`
4. 再次：提供 `MIHOMO_ASSET_NAME` + `MIHOMO_DOWNLOAD_MIRROR_PREFIXES`

注意：

- 若 API 不可达、脚本无法自动探测资产名，就需要显式提供 `MIHOMO_ASSET_NAME` 或 `MIHOMO_DOWNLOAD_URL`
- `MIHOMO_DOWNLOAD_FILE` 期望是官方 release 对应的 `.gz` 压缩包，而不是解压后的裸二进制
- 默认离线扫描目录为：当前仓库目录、`dist/`、`/opt/packages`、`/opt/distfiles`、`/var/cache/mihomo`

#### 方式 0：让脚本自动扫描离线包目录

如果你已经把 Mihomo 包放进默认目录之一，直接执行：

```bash
bash install.sh
```

如果你要指定自定义扫描目录：

```bash
MIHOMO_OFFLINE_SEARCH_DIRS='/data/pkg:/srv/cache/mihomo' bash install.sh
```

### 国内网络 / 离线包示例

#### 方式 1：使用本地离线包

```bash
MIHOMO_DOWNLOAD_FILE=/opt/packages/mihomo-linux-amd64-v1-v1.19.20.gz bash install.sh
```

#### 方式 2：指定固定下载地址

```bash
MIHOMO_DOWNLOAD_URL='https://example.invalid/mihomo-linux-amd64-v1-v1.19.20.gz' bash install.sh
```

#### 方式 3：官方地址失败后，自动尝试镜像前缀

```bash
MIHOMO_ASSET_NAME='mihomo-linux-amd64-v1-v1.19.20.gz' \
MIHOMO_DOWNLOAD_MIRROR_PREFIXES='https://mirror-1.example.invalid/,https://mirror-2.example.invalid/' \
bash install.sh
```

这类镜像前缀会被拼成：

- `<mirror-prefix>/<官方下载URL>`

因此适合“反代整个 GitHub 下载 URL”的代理型镜像。

## 施工顺序

建议严格按下面顺序执行。

### 1. 按机器实际情况审查 `config.yaml` 模板

部署前，agent 需要检查模板中的非敏感策略部分是否符合目标机器用途，例如规则、路由组名、controller 地址。

重点检查：

- `proxy-providers.subscription`：应保留订阅 provider 模式，不要改回明文节点列表
- `proxy-groups`：必须保留 `专项代理`
- `rules`：Telegram / GitHub 等专项规则是否仍指向 `专项代理`
- `external-controller`：通常为 `127.0.0.1:9090`
- `secret`：模板里应保持占位符，实际值由安装脚本渲染并与 OpenClaw 插件配置保持一致

说明：

- 不要再额外维护 `secret.txt`
- 不要把真实订阅地址直接写回仓库模板
- 若需要固定 controller secret，可通过环境变量 `MIHOMO_SECRET` 传入；否则脚本会自动生成或复用已有值

最低要求：

- `专项代理` 组必须存在
- 实际订阅里至少要有 2 个可切换节点，自动切线才有意义

### 2. 运行安装脚本并输入订阅地址

执行：

```bash
bash install.sh
```

若未提供 `MIHOMO_SUBSCRIPTION_URL`，脚本会提示：

```text
请输入 Mihomo 订阅地址:
```

`install.sh` 当前职责有三类：

1. 确保 `mihomo` 二进制和 systemd unit 可用
2. 交互式读取订阅地址、渲染脱敏模板并安装到 `/etc/mihomo`
3. best-effort 清理历史遗留的旧 watchdog 文件与 user systemd 单元

预期结果：

- `/etc/mihomo/config.yaml` 已由模板渲染并更新
- `/etc/mihomo/ruleset/` 已更新
- 若原本没装 `mihomo`，现在已安装到 `/usr/local/bin/mihomo`
- 若原本没有 `mihomo` unit，现在已创建 systemd unit
- `mihomo` 已重启
- 若用户目录里存在旧版 `mihomo-telegram-watchdog` 相关文件，会被删除
- 安装输出中会打印当前使用的 Mihomo controller secret，便于同步到 OpenClaw 插件配置

### 2.5 运行自检脚本

执行：

```bash
bash self-check.sh
```

如需覆盖默认路径，可使用环境变量：

- `MIHOMO_DIR`
- `MIHOMO_CONFIG`
- `MIHOMO_CONTROLLER_URL`
- `OPENCLAW_CONFIG`
- `TARGET_GROUP`

示例：

```bash
OPENCLAW_CONFIG=/srv/openclaw/openclaw.json TARGET_GROUP='专项代理' bash self-check.sh
```

### 3. 验证 Mihomo controller 可用

OpenClaw 插件的 Mihomo driver 依赖 controller API，因此必须验证：

- `external-controller` 可访问
- `secret` 正确
- `专项代理` 组可被 controller API 查询

示例：

```bash
curl -fsS -H 'Authorization: Bearer <MIHOMO_SECRET>' http://127.0.0.1:9090/version
curl -fsS -H 'Authorization: Bearer <MIHOMO_SECRET>' \
  'http://127.0.0.1:9090/proxies/%E4%B8%93%E9%A1%B9%E4%BB%A3%E7%90%86'
```

如果第二条命令失败，通常说明：

- `专项代理` 组不存在
- Mihomo 未成功加载最新配置
- controller secret 不一致

### 4. 配置 OpenClaw Telegram 渠道

OpenClaw 至少需要以下 Telegram 配置：

- `channels.telegram.enabled = true`
- `channels.telegram.botToken`
- `channels.telegram.proxy`

其中：

- `botToken` 给 Telegram 通道本身使用
- `proxy` 给 Telegram Bot API 出站访问使用

如果目标机器访问 `api.telegram.org` 需要代理，必须配置 `channels.telegram.proxy`，例如：

```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "<YOUR_BOT_TOKEN>",
      "proxy": "http://127.0.0.1:7890"
    }
  }
}
```

注意：这里的代理配置已经替代了旧版 `openclaw-gateway.proxy.conf` 的大部分原始用途；新机器不要再为 Telegram Bot API 单独恢复那个 drop-in。

### 5. 启用 `network-proxy-watchdog` 插件

目标是让 OpenClaw 标准插件接管以下能力：

- 定时健康检查
- Telegram Bot API 探测
- 连续失败计数
- 达到阈值后切换 `专项代理`

OpenClaw 配置中应存在类似结构：

```json
{
  "plugins": {
    "allow": [
      "telegram",
      "network-proxy-watchdog"
    ],
    "entries": {
      "network-proxy-watchdog": {
        "enabled": true,
        "config": {
          "enabled": true,
          "stateFile": "~/.openclaw/state/network-proxy-watchdog/state.json",
          "healthCheck": {
            "kind": "telegram-bot-api",
            "timeoutMs": 15000,
            "intervalMs": 60000,
            "proxyUrl": "http://127.0.0.1:7890",
            "telegramApiBaseUrl": "https://api.telegram.org"
          },
          "switchPolicy": {
            "failureThreshold": 3,
            "switchCooldownMs": 300000
          },
          "driver": {
            "type": "mihomo",
            "controllerUrl": "http://127.0.0.1:9090",
            "secret": "<MIHOMO_SECRET>",
            "groupName": "专项代理"
          }
        }
      }
    }
  }
}
```

施工原则：

- `driver.type` 必须是 `mihomo`
- `driver.groupName` 必须指向 `专项代理`
- `driver.secret` 必须与 `config.yaml` 中 `secret` 一致
- `healthCheck.proxyUrl` 通常与 `channels.telegram.proxy` 保持一致
- `healthCheck.kind` 应为 `telegram-bot-api`

### 6. 重启 OpenClaw 并做插件级验证

修改 OpenClaw 配置后，需要重启对应服务或 gateway 进程。

然后优先验证以下命令：

```bash
openclaw proxy-watchdog status
openclaw proxy-watchdog describe-driver
openclaw proxy-watchdog current-target
openclaw proxy-watchdog run-once
```

预期：

- `status` 能输出有效配置摘要
- `describe-driver` 能看到 `type = mihomo`
- `current-target` 能读到 `专项代理` 当前线路
- `run-once` 不应报 controller 连接错误或 group not found

### 7. 验证切线能力

若要验证自动切线链路，至少要确认：

- `专项代理` 里确实有多个可用目标
- `failureThreshold` 设置合理
- `switchCooldownMs` 不会妨碍测试

建议先做一次手动切线验证：

```bash
openclaw proxy-watchdog list-targets
openclaw proxy-watchdog switch --target '<某个专项代理成员名>'
openclaw proxy-watchdog current-target
```

若手动切线都失败，就不要继续排查自动切线，应先解决 Mihomo driver/controller/group 配置问题。

### 8. 确认没有旧方案残留

验收时，确认以下项目不存在或未启用：

```bash
systemctl --user status mihomo-telegram-watchdog.service --no-pager
systemctl --user status mihomo-telegram-watchdog.timer --no-pager
ls -l ~/.local/bin/mihomo-telegram-watchdog.sh
ls -l ~/.config/mihomo/telegram-watchdog.env
```

允许历史机器上查到 `not found` 或 `unit could not be found`。

如果它们存在，应清理，而不是继续启用。

## 推荐验收清单

完成施工后，agent 应逐项打勾：

- [ ] `mihomo -t` 校验通过
- [ ] `/etc/mihomo/config.yaml` 已更新
- [ ] `专项代理` 组可经 controller API 查询
- [ ] OpenClaw Telegram 通道可正常使用 Bot API
- [ ] `network-proxy-watchdog` 已启用
- [ ] `openclaw proxy-watchdog status` 正常
- [ ] `openclaw proxy-watchdog run-once` 正常
- [ ] 手动切线正常
- [ ] 旧 watchdog service/timer 不存在或未启用

## 常见失败点

### 1. Mihomo controller 访问失败

常见原因：

- `config.yaml` 中没开 `external-controller`
- `secret` 配错
- Mihomo 没重启成功

### 2. 查询不到 `专项代理`

常见原因：

- `proxy-groups` 中没有这个组
- 组名改了，但 OpenClaw 插件里的 `driver.groupName` 没同步

### 3. Telegram 探测一直失败，但其实线路正常

常见原因：

- `channels.telegram.botToken` 不正确
- `channels.telegram.proxy` 或 `healthCheck.proxyUrl` 未配置
- 目标机器直连 `api.telegram.org` 不通

### 4. 插件能探测但不会切线

常见原因：

- `专项代理` 只有一个成员
- 正处于 `switchCooldownMs` 冷却期
- `failureThreshold` 未达到

## 实施原则总结

让新机器的 agent 始终记住下面几条：

1. 不要复活旧 watchdog。
2. 本仓库只维护 Mihomo 静态配置。
3. 自动巡检与切线统一交给 OpenClaw 标准插件。
4. `专项代理` 是双方对接的核心边界，不要随意删名或改名。
5. 如果要排障，先验证 Mihomo controller，再验证 OpenClaw 插件，最后再看 Telegram 网络。
