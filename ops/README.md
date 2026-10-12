# 服务器 Remote Control 配置

`setup-remote-control.sh` 把一台自己的 Linux 服务器配成 Claude Code Remote Control 服务器。配好之后，在 claude.ai/code 或 Claude App 的 Remote Control 列表里选中这台机器，就能直接用 Fable 在服务器本地干活。

## 一次性配置

先登录服务器，用 SSH 或阿里云控制台的远程连接终端都可以，然后以 root 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/creator915/Logita/refs/heads/claude/cool-gates-6jep8w/ops/setup-remote-control.sh -o setup-rc.sh
bash setup-rc.sh /root/agda-backend
```

脚本需要交互终端，所以要先下载再运行，不能用 `curl | bash`。中途有四处要你本人操作：

1. 在浏览器里打开登录链接，把授权代码粘回终端。
2. 信任工作目录。
3. 输入 `/model fable`，在 Fable 用量额度提示里选择继续。这个提示只会出现在服务器终端上。
4. Remote Control 第一次启动时问 `Enable Remote Control? (y/n)`，输入 `y`，再按 Ctrl-b、d 退出 tmux。

## 脚本做了什么

- 安装或更新 Claude Code、tmux。
- 在 `~/.claude/settings.json` 里把默认模型设为 `fable`，保留原有设置。
- 在 `~/.claude/CLAUDE.md` 里写一段服务器说明：这是所有者自己的机器，只在本机操作，不扫描其他主机。实例 ID 和 IP 从阿里云元数据接口自动读取，仓库里不存放。
- 安装 systemd 服务 `claude-rc`：开机自启，在独立 tmux socket 里循环运行 `claude remote-control`，掉线退出后 15 秒自动重启。

Remote Control 只走出站 HTTPS，不需要在安全组里开放任何入站端口。

## 日常命令

```bash
tmux -L claude-rc attach -t claude-rc   # 看实时输出，Ctrl-b d 退出
systemctl restart claude-rc             # 重启
systemctl status claude-rc              # 状态
claude doctor                           # 检查安装和 Remote Control 资格
claude auth login                       # 登录过期时重新登录
```
