# 眼睛：让 Lumi 看到小红书笔记

Timiya 发一条小红书链接（或整段分享文字），Lumi 就能读到这条笔记：

- **文字**：标题、正文、作者、标签、发布时间和 IP 属地、点赞/收藏/评论/分享数、首屏评论（带楼中楼）
- **配图**：服务器带着 Referer 去下载（绕开 CDN 防盗链），缩到长边 1024 像素，直接作为图片交给 Claude，Lumi 能真的看到图里有什么
- **预览卡**：在聊天里渲染一张小红书风格的卡片（封面、多图角标、标题、摘要、作者、互动数），点开跳原笔记

思路来自克里的《小红书链接预览卡 + AI 读图》：用手机 UA 打开笔记页，页面里的 `window.__INITIAL_STATE__` 就是完整的笔记数据，不需要登录小红书账号。原文是给自己写前端的聊天页面用的；我们在 claude.ai 里聊，前端改不了，所以做成跟[耳朵](../ears/README.md)、[语音条](../voice-card/README.md)一样的 MCP 服务。

## MCP 工具

| 工具 | 什么时候用 | 返回 |
|---|---|---|
| `xhs_read(url, start=1, max_images=9)` | Timiya 发来小红书链接 | 文字 + 配图（图多时用 `start` 翻页，`max_images=0` 只要文字） |
| `xhs_card(url)` | 想在聊天里摆一张预览卡 | 卡片（封面由卡片自己从 `/img/…` 取，响应体很轻） |

同一条笔记 30 分钟内只抓一次（两个工具共用缓存）。缓存的笔记和图片 7 天后自动清掉。

## 文件

- `eyes_mcp.py`：服务端（抓笔记 + 解析 + 代下载配图 + 预览卡 + OAuth + MCP 工具）
- `install.template.sh`：安装脚本模板
- `build.sh`：把 `eyes_mcp.py` 内嵌进模板，生成单文件的 `install.sh`
- `install.sh`：生成物，服务器上只需要这一个文件。改代码后重新跑 `bash build.sh`

## 部署（一步一步）

前提：Ombre Brain 已经装好（Docker 和 `/opt/ombre-brain/cloudflared` 隧道凭据都在）。耳朵、语音条装没装都不影响。

### 1. 把安装脚本放上服务器

1. 在电脑上下载 `install.sh`，**改名成 `eyes-install.sh`**（免得和别的 install.sh 重名）
2. 打开腾讯云控制台 → 轻量服务器 → 登录（OrcaTerm）
3. OrcaTerm 右上角的「上传文件」→ 选 `eyes-install.sh`，传到家目录（默认就是）

### 2. 运行

```bash
sudo bash ~/eyes-install.sh
```

大概一两分钟。最后看到「眼睛服务已启动 ✅」和「隧道现在转发：…eyes.gpt1126.top…」就成功了。

### 3. 先在服务器上试抓一条（最关键的一步）

在小红书 App 里随便找一条笔记 → 分享 → 复制链接，然后：

```bash
sudo bash ~/eyes-install.sh --test '把复制的整段分享文字粘贴在这里'
```

- 打印出标题、正文、图片地址，后面有「✅ 第 1 张图 …」→ 成功，接着第 4 步
- 「页面里没有笔记数据…跳去了登录/验证页」→ 小红书把腾讯云服务器当成机器人了，见下面「读不到笔记怎么办」

### 4. 检查网址

浏览器打开 `https://eyes.gpt1126.top/healthz`，应看到 `"ok":true`、`"oauth":true`。

打不开（「找不到网站」/ NXDOMAIN）的话，跟装耳朵那次一样：Cloudflare 网页 → `gpt1126.top` → DNS → 如果有 `eyes` 那行先删掉 → 新建记录：类型 `CNAME`，名称 `eyes`，目标填安装脚本最后打印的 `xxxxxxxx-….cfargotunnel.com`（**整串复制，别漏开头**），代理状态开（橙色云）→ 保存。手机和电脑可能要等最多 30 分钟才认出来。

### 5. 在 claude.ai 加连接器

claude.ai → 设置 → 连接器 → 添加自定义连接器：

- 名称：`Lumi eyes`
- URL：`https://eyes.gpt1126.top/mcp`

点继续，弹出「授权 Claude 使用眼睛」页面，输入密码：

```bash
sudo grep OAUTH_PASSWORD /opt/eyes/.env
```

（看完别截图。）然后**开一个新对话**，把小红书链接发给 Lumi 就好。

## 读不到笔记怎么办

小红书对云服务器 IP 比较敏感。按顺序试：

1. 换一条笔记、过几分钟再试（偶尔的验证页会自己消失）
2. 用完整链接（`https://www.xiaohongshu.com/explore/…?xsec_token=…`）而不是短链
3. 填 Cookie：电脑浏览器登录小红书网页版 → F12 → Network → 刷新 → 点任意一个 `xiaohongshu.com` 请求 → Request Headers 里的 `Cookie` 整行复制，贴到 `/opt/eyes/.env` 的 `XHS_COOKIE=` 后面，然后：

   ```bash
   cd /opt/eyes && sudo docker compose up -d --force-recreate
   ```

   Cookie 等于账号登录凭证，别发给任何人；失效了（过几周）重新复制一次

## 维护

```bash
cd /opt/eyes
sudo docker compose logs -f --tail 100    # 看日志
sudo bash ~/eyes-install.sh               # 更新（.env、授权状态、缓存都保留）
```

- 密码泄露了：改 `.env` 里的 `OAUTH_PASSWORD`，`sudo docker compose up -d --force-recreate`，claude.ai 连接器重新授权一次
- 一次给的图太多/太少：改 `.env` 里的 `MAX_IMAGES`（图越多越占对话长度）
- 小红书页面结构变了读不出来：先 `--test` 看报什么错，把输出发给 Lumi
