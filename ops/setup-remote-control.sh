#!/usr/bin/env bash
# 在自己的 Linux 服务器上配置 Claude Code Remote Control（服务器模式）。
# 配好后：开机自启、掉线自动重启、默认模型 Fable，在 claude.ai/code 或 Claude App
# 的 Remote Control 列表里直接选这台机器即可。
#
# 用法（以 root 在服务器上运行，需要交互，请在真正的终端里跑）：
#   bash setup-remote-control.sh [工作目录] [会话名]
#   默认工作目录 /root/agda-backend，默认会话名为主机名。
#
# 本脚本不含任何密钥。登录走 claude.ai 账号授权，凭证只保存在服务器本机。
set -euo pipefail

WORKDIR="${1:-/root/agda-backend}"
RC_NAME="${2:-$(hostname)}"
SERVICE=claude-rc
LOOP=/usr/local/bin/claude-rc-loop
UNIT=/etc/systemd/system/${SERVICE}.service
TMUX_SOCK=claude-rc   # 独立的 tmux socket，和你自己的 tmux 会话互不影响
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '\033[1;33m%s\033[0m\n' "$*"; }
pause() { read -r -p "$* 按回车继续..." _; }

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
[ -t 0 ] && [ -t 1 ] || { echo "需要交互终端。请在 SSH 或阿里云控制台的远程连接终端里运行。"; exit 1; }
[ "$WORKDIR" != "$HOME" ] || { echo "不要用家目录做工作目录：家目录的信任选择不会保存，每次重启都会卡住。"; exit 1; }

step "1/7 安装依赖：tmux curl python3"
need=()
for p in tmux curl python3; do command -v "$p" >/dev/null 2>&1 || need+=("$p"); done
if [ ${#need[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq "${need[@]}"
  elif command -v dnf >/dev/null; then dnf install -y -q "${need[@]}"
  else echo "请手动安装：${need[*]}"; exit 1; fi
fi

step "2/7 安装或更新 Claude Code"
if command -v claude >/dev/null 2>&1; then
  claude update || note "自动更新失败，继续使用当前版本"
else
  curl -fsSL https://claude.ai/install.sh | bash
fi
if [ ! -e /usr/local/bin/claude ] && [ -x "$HOME/.local/bin/claude" ]; then
  ln -s "$HOME/.local/bin/claude" /usr/local/bin/claude
fi
claude --version

step "3/7 工作目录：$WORKDIR"
mkdir -p "$WORKDIR"

step "4/7 默认模型设为 Fable，并检查会抢占订阅登录的设置"
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
d = {}
if os.path.exists(p):
    with open(p) as f:
        d = json.load(f)
d["model"] = "fable"
bad = [k for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                   "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX") if k in d.get("env", {})]
if "apiKeyHelper" in d:
    bad.append("apiKeyHelper")
with open(p, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("已写入", p, "model = fable")
if bad:
    print("警告：settings.json 里有这些项，会让 Remote Control 拒绝启动，请删掉：", ", ".join(bad))
PY
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL; do
  grep -qs "$v" ~/.bashrc ~/.profile /etc/environment && note "警告：shell 配置里设置了 $v，请删除，否则会顶替订阅登录。"
done

step "5/7 写入服务器说明（~/.claude/CLAUDE.md），让每个会话都知道这是谁的机器"
md() { curl -sf --max-time 2 "http://100.100.100.200/latest/meta-data/$1" 2>/dev/null || true; }
IID=$(md instance-id); REGION=$(md region-id); PUB=$(md eipv4); [ -n "$PUB" ] || PUB=$(md public-ipv4)
PRIV=$(md private-ipv4); [ -n "$PRIV" ] || PRIV=$(hostname -I | awk '{print $1}')
OS=$(. /etc/os-release && echo "$PRETTY_NAME")
CPU=$(nproc); MEM=$(free -g | awk '/Mem:/{print $2}')
MARK_BEGIN="<!-- BEGIN remote-control-setup -->"
MARK_END="<!-- END remote-control-setup -->"
CM="$HOME/.claude/CLAUDE.md"
touch "$CM"
python3 - "$CM" "$MARK_BEGIN" "$MARK_END" <<PY
import sys, re
path, b, e = sys.argv[1], sys.argv[2], sys.argv[3]
block = f"""{b}
# 这台服务器

- 这是服务器所有者本人的云主机。Claude 通过 Remote Control 在这台机器本地运行，代所有者做开发和运维。
- 实例 ID：${IID:-未知}；地域：${REGION:-未知}；公网 IP：${PUB:-未知}；私网 IP：${PRIV:-未知}。
- 系统：${OS}；${CPU} 核；内存 ${MEM} GB；主工作目录：${WORKDIR}。
- 所有命令都在本机执行。在本机上安装软件、编译、改配置、看日志、管理服务，都是所有者授权的正常运维。

# 工作规矩

- 只操作本机。不对其他主机或网段做端口扫描、批量登录尝试或压力测试。
- 不把密钥、AccessKey、私钥写进 git 仓库、日志或聊天回复。
- 改 sshd、防火墙、systemd 服务、用户账号之前，先说明要改什么、怎么回滚。
- 长任务用 nohup 或 tmux 跑，输出写进日志文件，再看日志。
- Remote Control 本身跑在 systemd 服务 ${SERVICE} 里，对应 tmux -L ${TMUX_SOCK} 的会话 ${SERVICE}。不要停掉或重启它，否则当前对话会断开。
{e}"""
s = open(path).read()
pat = re.compile(re.escape(b) + r".*?" + re.escape(e), re.S)
s = pat.sub(block, s) if pat.search(s) else (s.rstrip() + "\n\n" + block + "\n").lstrip()
open(path, "w").write(s)
print("已更新", path)
PY
if [ -x /usr/local/bin/agda-stock ] && ! grep -q "agda-cubical-run" "$CM"; then
  cat >> "$CM" <<'AGDA'

# Agda 环境

- /usr/local/bin/agda 是自建后端 agda-cubical-run；原版 Agda 在 /usr/local/bin/agda-stock。
- cubical 库在 /root/agda-backend/cubical-upstream，已写进 ~/.agda/libraries 和 ~/.agda/defaults。
- 源码树 /root/agda-backend/agda-source。改 Runtime.hs 后运行 cabal build agda-cubical-run，再把产物 cp 到 /usr/local/bin。
AGDA
fi

step "6/7 登录 claude.ai 账号（Remote Control 只认订阅登录，不认 API key）"
METHOD=$(claude auth status 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authMethod",""))' 2>/dev/null || true)
if [ "$METHOD" = "claude.ai" ]; then
  echo "已用 claude.ai 账号登录。"
else
  note "接下来会打印一个登录链接。在你自己电脑的浏览器里打开它，授权后把页面给出的代码粘回这里。"
  claude auth login
fi

note "
接下来会在 $WORKDIR 打开一次交互式 Claude Code，完成两件只需做一次的事：
  1. 出现目录信任提示时，选择信任这个目录。
  2. 输入 /model fable 回车。如果提示 Fable 需要用量额度，选择继续使用 Fable。
     这一步只能在服务器终端上确认，手机和网页端收不到这个弹窗。
完成后输入 /exit 退出，脚本会继续。"
pause ""
(cd "$WORKDIR" && claude) || true

step "7/7 安装 systemd 服务 ${SERVICE}：开机自启，tmux 里循环运行 claude remote-control"
cat > "$LOOP" <<LOOPEOF
#!/usr/bin/env bash
# 由 setup-remote-control.sh 生成。在 tmux 会话 ${SERVICE} 里循环运行 Remote Control 服务器。
export HOME=/root
export PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL
cd "${WORKDIR}"
while true; do
  claude remote-control --name "${RC_NAME}"
  rc=\$?
  echo "[\$(date '+%F %T')] remote-control 退出，退出码 \$rc，15 秒后重启"
  sleep 15
done
LOOPEOF
chmod 755 "$LOOP"

cat > "$UNIT" <<UNITEOF
[Unit]
Description=Claude Code Remote Control server (tmux -L ${TMUX_SOCK}, session ${SERVICE})
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=root
Environment=HOME=/root
ExecStart=/usr/bin/tmux -L ${TMUX_SOCK} new-session -d -s ${SERVICE} -x 200 -y 50 ${LOOP}
ExecStop=/usr/bin/tmux -L ${TMUX_SOCK} kill-session -t ${SERVICE}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl stop "$SERVICE" 2>/dev/null || true
tmux -L "$TMUX_SOCK" kill-session -t "$SERVICE" 2>/dev/null || true
systemctl enable --now "$SERVICE"
sleep 3
systemctl --no-pager --lines=0 status "$SERVICE" || true

note "
马上进入 tmux 会话 ${SERVICE}。第一次运行时 Remote Control 会问 Enable Remote Control? (y/n)，输入 y。
看到会话链接后，先按 Ctrl-b 再按 d 退出 tmux，服务会继续在后台运行。"
pause ""
tmux -L "$TMUX_SOCK" attach -t "$SERVICE" || true

step "完成"
cat <<DONE
现在打开 claude.ai/code 或 Claude App，在 Remote Control 列表里找 "${RC_NAME}"，就能直接用 Fable 操作这台服务器。

常用命令：
  tmux -L ${TMUX_SOCK} attach -t ${SERVICE}   查看 Remote Control 的实时输出，Ctrl-b d 退出
  systemctl restart ${SERVICE}         重启 Remote Control
  systemctl status ${SERVICE}          查看服务状态
  claude doctor                        检查安装和 Remote Control 资格
  claude auth login                    登录过期时重新登录
DONE
