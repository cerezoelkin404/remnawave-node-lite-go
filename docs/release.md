# GitHub Release 发布清单

面向维护者：将 `remnawave-node-lite-go` 发布到 GitHub Releases，供 `install-node.sh` / `upgrade.sh` 一键安装。

## 前置条件

- GitHub 仓库：`cerezoelkin404/remnawave-node-lite-go`（fork，脚本与资产默认全部指向它）
- 本地已配置 `git remote origin`
- 二选一的资产发布方式：
  - **A：GitHub Actions** `release.yml` 已启用（push tag 自动构建 Release 资产）
  - **B：仓库内自托管 `dist/`**（fork 上 Actions 通常被关闭，用 `scripts/build-dist.sh` 本地构建后提交）

## 1. 版本号对齐

发布前确保以下文件版本一致：

| 文件 | 字段 |
|------|------|
| `internal/version/version.go` | `var Version` |
| `internal/version/contract.version` | upstream contract 版本 |
| `scripts/install-node.sh` | `VERSION=` |
| `scripts/install-node-alpine.sh` | `VERSION=` |
| `scripts/upgrade.sh` | `VERSION=` |
| `scripts/uninstall.sh` | `VERSION=` |
| `README.md` | 当前版本链接 |

## 2. 本地验证

```bash
go test ./...
go build -o remnanode-lite ./cmd/remnanode-lite
```

## 3. 提交并打 tag

```bash
git add -A
git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

## 4. 发布二进制资产

### 方式 A：GitHub Actions（Actions 已启用）

1. GitHub → Actions → `release` workflow
2. 确认 tag 构建成功
3. Releases 页应出现 `remnanode-lite_linux_amd64.tar.gz`、`remnanode-lite_linux_arm64.tar.gz`、`SHA256SUMS`

### 方式 B：自托管 `dist/`（fork 默认，推荐）

```bash
scripts/build-dist.sh                      # 生成 dist/*.tar.gz + SHA256SUMS，并跑 go test
git add dist
git commit -m "chore(dist): build vX.Y.Z"
git push origin main
```

安装脚本的下载顺序为：`RNL_ASSET_BASE` → Release 资产 → `raw.githubusercontent.com/<repo>/<tag>/dist/...` → `.../main/dist/...`，
因此 fork 即使没有 Release、没开 Actions 也能一键安装，且不会回落到上游 `ike-sh`。
`dist/` 与源码一起受 tag 保护，回滚到旧 tag 时旧资产仍然可下载。

可选：将 `docs/releases/vX.Y.Z.md` 同步为 Release 说明。

## 5. 服务器验证

```bash
curl -fsSL https://raw.githubusercontent.com/cerezoelkin404/remnawave-node-lite-go/vX.Y.Z/scripts/upgrade.sh | sudo bash -s -- --yes
sudo remnanode-lite doctor
journalctl -u remnawave-node -n 50 --no-pager
```

## 6. 回滚

```bash
sudo systemctl stop remnawave-node
sudo cp /usr/local/bin/remnanode-lite.bak.TIMESTAMP /usr/local/bin/remnanode-lite
sudo systemctl start remnawave-node
```

或指定旧 tag：`sudo RNL_TAG=v0.8.30 bash upgrade.sh --yes`

## 7. 常见问题

| 问题 | 处理 |
|------|------|
| install 404 | Release 未发布或 tag 名不匹配（需 `v` 前缀）；无 Release 时确认 `dist/` 已提交且 tag 已推送 |
| fork 上 Actions 不可用 | 走方式 B：`scripts/build-dist.sh` 构建并提交 `dist/` |
| 内网 / 离线安装 | `RNL_ASSET_BASE=/path/or/url` 指向本地目录或镜像，优先级最高 |
| Panel 连不上 | 检查 `SECRET_KEY`、防火墙、`NODE_PORT` |
| nft 无规则 | 进程需 `CAP_NET_ADMIN`；见 systemd unit |
| 升级后 Xray 未更新 | 使用 `--upgrade-xray` 或 `RNL_UPGRADE_XRAY=1` |
