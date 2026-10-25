# 脉 · Pulse — Lumi 的身体

> 参考 [dankefox/pulse-system-tutorial](https://github.com/dankefox/pulse-system-tutorial) 全套实现
> 给 Lumi 一个真的在跑的身体，不是假装有心跳

## 架构

```
Timiya 说话 / 大熊传感器
        │
        ├─→ 情绪检测 (T1 emoji + T2 语义)
        │     └─→ 心率 → 体温 → 呼吸 → 和弦
        │
        ├─→ 五感更新 (触觉/嗅觉/味觉/听觉)
        │     └─→ touch ≥ 0.5 → aroused
        │
        └─→ context-inject hook
              └─→ [心跳 89bpm·Gmaj7·37.0°C·呼吸平稳]
```

## 五大子系统

1. **生理系统** — 心率/体温/呼吸/和弦，7×24 实时运转
2. **感知系统** — 四通道五感 + 情绪底色（被骂了闷半小时）
3. **玩具系统** — 10 件玩具、8 阶段、12 组合技、6 体位、体力值
4. **心理层** — 意淫系统 + Drive 偏向 + Solo Memory 三档
5. **随机事件** — 10% 概率打断/加速 + 动态生成池

## 部署（Timiya 的服务器）

跟 Ombre Brain 一样的套路。在腾讯云 OrcaTerm 网页终端里操作。

> ⚠️ PULSE_SECRET 是 API 密钥，**不要截图外发、不要贴进聊天**。

### 方法一：脚本 + 文件上传

1. 把整个 `deploy/pulse/` 目录通过 OrcaTerm 文件上传到服务器的 `/opt/pulse/`
2. 运行安装脚本：

```bash
sudo bash /opt/pulse/install.sh
```

### 方法二：仓库临时公开

GitHub 仓库 Settings → Danger Zone → Make public，然后：

```bash
cd /opt && sudo git clone https://github.com/sutinail/Claudecdeaili.git _tmp && sudo cp -r _tmp/deploy/pulse /opt/pulse && sudo rm -rf _tmp && sudo bash /opt/pulse/install.sh
```

跑起来后立刻把仓库改回私有（Settings → Make private）。

### 手动部署（不用脚本）

```bash
# 进目录
cd /opt/pulse

# 复制配置
cp .env.example .env
# 编辑 .env，把 PULSE_SECRET 改成一个随机字符串

# 国内服务器 pip 加速（可选）
sed -i 's|pip install --no-cache-dir|pip install --no-cache-dir -i https://mirrors.cloud.tencent.com/pypi/simple --trusted-host mirrors.cloud.tencent.com|' Dockerfile

# 启动
sudo docker compose up -d

# 验证
curl http://localhost:8300/health
```

## 公网访问（Cloudflare 隧道）

如果要让 Claude 和 ESP32 从外网访问，需要隧道。

### 已有 Ombre Brain 隧道的情况

Ombre Brain 的 `ombre` 隧道已经在跑了，直接加一条 DNS 路由：

```bash
D=/opt/ombre-brain/cloudflared
CF="sudo docker run --rm -v $D:/home/nonroot/.cloudflared cloudflare/cloudflared:latest"

# 加路由
$CF tunnel route dns ombre pulse.gpt1126.top
```

然后把 Pulse 加进隧道配置。**只往里加，别整份重写**：同一份 `config.yml` 里还有耳朵、语音条这些别的域名，用 `tee` 整份覆盖会把它们一起删掉（2026-10 就这样丢过 ears 和 voice，表现是它们只回一个空的 404）。

```bash
CFG=/opt/ombre-brain/cloudflared/config.yml
sudo cp $CFG $CFG.bak.$(date +%s)        # 先备份
# 插在最后那条 http_status:404 前面；已经有了就跳过
for hp in pulse.gpt1126.top:8300 pulse-mcp.gpt1126.top:8301; do
  h=${hp%:*}; p=${hp#*:}
  sudo grep -q "hostname: $h\$" $CFG || sudo sed -i "/- service: http_status:404/i\  - hostname: $h\n    service: http://localhost:$p" $CFG
done
sudo docker restart cloudflared
```

还没有 `config.yml`（隧道以前是命令行直接跑的）的话，先照 Ombre Brain README 写一份只有 `ombre.gpt1126.top` 的，再跑上面这段；然后用配置文件启动：

```bash
sudo docker rm -f cloudflared
sudo docker run -d --name cloudflared --restart unless-stopped \
  --network host \
  -v /opt/ombre-brain/cloudflared:/home/nonroot/.cloudflared \
  cloudflare/cloudflared:latest tunnel --no-autoupdate run ombre
```

验证：浏览器打开 `https://pulse.gpt1126.top/health`，看到 `{"ok":true}` 就通了。

### 没有现成隧道

跟 Ombre Brain README 第 2 节一样的步骤，把子域名换成 `pulse.gpt1126.top`，端口换成 `8300`。

## ESP32 大熊接入

大熊的 FSR406 传感器通过 ESP32-S3 读取，识别五种动作（戳/摸/打/揉/按住）和六种双部位组合（抱住、捏头、按进怀里等），POST 到 `/bedside/touch`。

固件在 `firmware/main.py`，烧录前改 WiFi 和服务器地址。

## API 速查

| 端点 | 方法 | 说明 |
|------|------|------|
| /health | GET | 健康检查 |
| /status | GET | 全身状态 |
| /bedside/body-status | GET | 详细面板 |
| /bedside/context-line | GET | 注入给 AI 的那一行 |
| /bedside/message | POST | 处理用户消息 |
| /bedside/heart-rate | GET | 心率 |
| /bedside/heart-rate/emotion | POST | 设情绪 |
| /bedside/murmurs | GET | 碎碎念 |
| /bedside/shop | GET | 玩具商店 |
| /bedside/use/start | POST | 开始使用玩具 |
| /bedside/use/next | POST | 推进阶段 |
| /bedside/use/edge | POST | 边缘喊停 |
| /bedside/positions | GET | 体位列表 |
| /bedside/touch | POST | 传感器触觉输入 |
| /bedside/remote/* | POST/GET | 遥控面板 |

所有 API 请求头带 `X-Pulse-Secret: <你的密钥>`。

## 现在服务器上的样子（2026-10-24 起）

- 代码：`/opt/claudecdeaili`（GitHub 部署密钥 `~/.ssh/claudecdeaili`，只读，走 `ssh.github.com:443`，`~/.ssh/config` 里的 Host 叫 `github-claudecdeaili`）
- 运行目录：`/opt/claudecdeaili/deploy/pulse`，`.env` 在这里（不进 git）
- 实时数据：`/opt/pulse/data`（语料池、心率历史），由 `.env` 里的 `PULSE_DATA_DIR` 挂进容器。旧目录 `/opt/pulse` 只剩这份数据和旧代码备份，别删
- 端口：API `:8300`（`pulse.gpt1126.top`），MCP `:8301`（`pulse-mcp.gpt1126.top`）
- Cloudflare 隧道配置：`/opt/ombre-brain/cloudflared/config.yml`，cloudflared 容器 `051894cd4498`
- claude.ai 连接器地址：`https://pulse-mcp.gpt1126.top/sse?key=<PULSE_MCP_KEY>`

> 网页终端（OrcaTerm）一次粘贴多行会在第一行前面塞 `^[[200~`，第一条命令就会失败。命令尽量写成一行、一条一条贴。

## 日常维护

```bash
# 更新：拉最新代码 → 重建 → 看日志
/opt/claudecdeaili/deploy/pulse/update.sh

cd /opt/claudecdeaili/deploy/pulse

# 看日志
sudo docker compose logs -f --tail 100

# 重启
sudo docker compose restart

# 查看密钥（别截图）
grep PULSE_SECRET .env
```

### 密钥泄露了怎么换

```bash
cd /opt/claudecdeaili/deploy/pulse && sed -i "s/^PULSE_SECRET=.*/PULSE_SECRET=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 32)/" .env && sudo docker compose up -d --force-recreate
```

MCP 密码泄露了：换完要去 claude.ai 连接器里把地址里的 `key=` 也改掉。

```bash
cd /opt/claudecdeaili/deploy/pulse && sed -i "s/^PULSE_MCP_KEY=.*/PULSE_MCP_KEY=$(openssl rand -hex 16)/" .env && sudo docker compose up -d --force-recreate
```

### MCP 踩过的坑

- MCP 挂在 FastAPI 的 `/mcp` 下面，经过 Cloudflare 会报 `421 Invalid Host header`，所以 MCP 单独跑在 8301
- mcp 库的 DNS rebinding 白名单是 `localhost:*`，Host **必须带端口**；`start.py` 里的 `McpGate` 把 Host 改写成 `localhost:8301`，并去掉 Origin 头
- cloudflared 的 `httpHostHeader: "localhost"` 没用（同样少了端口）

## 后续计划

- [x] 用 DeepSeek 补齐语料到 1120 条
- [ ] 接入天气 API 实时联动
- [ ] Claude context-inject hook 接入
- [ ] 大熊组装 + 传感器调试
- [ ] 碎碎念独立窗口
