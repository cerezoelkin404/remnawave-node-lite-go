#!/usr/bin/env bash
# 构建仓库内自托管的二进制资产（dist/），供没有 GitHub Release 的 fork 直接安装使用。
#
# 为什么需要它：fork 的 GitHub Actions 默认关闭，也没有 Release 资产，
# 而安装脚本必须能下载到 remnanode-lite。把构建产物提交到 dist/ 后，
# 安装脚本会通过
#   https://raw.githubusercontent.com/<repo>/<tag>/dist/remnanode-lite_linux_<arch>.tar.gz
# 获取二进制，全程不依赖上游 ike-sh 仓库。
#
# 用法：
#   scripts/build-dist.sh                 # 构建 amd64 + arm64，跑测试
#   scripts/build-dist.sh --skip-test     # 跳过 go test
#   scripts/build-dist.sh --arch amd64    # 只构建一个架构
#   scripts/build-dist.sh --no-docker     # 直接用本机 go（需 go >= go.mod 要求）
#
# 产物：
#   dist/remnanode-lite_linux_amd64.tar.gz
#   dist/remnanode-lite_linux_arm64.tar.gz
#   dist/SHA256SUMS
#
# 构建完成后提交并打标签（安装脚本默认取最新 tag）：
#   git add dist && git commit -m "chore(dist): rebuild v<version>"
#   git tag -a v<version> -m "v<version>" && git push origin main --tags
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${DIST_OUT:-${REPO_ROOT}/dist}"
GO_IMAGE="${GO_IMAGE:-golang:1.26-bookworm}"
CACHE_DIR="${RNL_BUILD_CACHE:-${HOME}/.cache/rw-node-lite-build}"
ARCHES="amd64 arm64"
RUN_TEST=1
USE_DOCKER=auto
TAG=""

usage() {
  cat <<'EOF'
用法：build-dist.sh [--tag vX.Y.Z] [--arch amd64|arm64] [--out DIR] [--skip-test] [--no-docker] [--help]

  --tag TAG      覆盖版本号（默认取 internal/version/version.go 的 Version）
  --arch ARCH    只构建指定架构（可重复）
  --out DIR      输出目录（默认 <repo>/dist）
  --skip-test    跳过 go test ./...
  --no-docker    不使用 docker，直接调用本机 go
  --help         帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag 需要值}"; shift 2 ;;
    --arch) ARCHES="${2:?--arch 需要值}"; shift 2 ;;
    --out) OUT_DIR="${2:?--out 需要值}"; shift 2 ;;
    --skip-test) RUN_TEST=0; shift ;;
    --no-docker) USE_DOCKER=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

VERSION="$(sed -n 's/^var Version = "\(.*\)"$/\1/p' "${REPO_ROOT}/internal/version/version.go")"
if [ -z "$VERSION" ]; then
  echo "无法从 internal/version/version.go 解析 Version" >&2
  exit 1
fi
if [ -n "$TAG" ]; then
  VERSION="${TAG#v}"
fi
CONTRACT_VERSION="$(tr -d ' \n\r' <"${REPO_ROOT}/internal/version/contract.version")"

LDFLAGS="-s -w -X remnawave-node-lite-go/internal/version.Version=${VERSION} -X remnawave-node-lite-go/internal/version.ContractVersion=${CONTRACT_VERSION}"

if [ "$USE_DOCKER" = auto ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    USE_DOCKER=1
  else
    USE_DOCKER=0
  fi
fi

# 容器内直接执行 go（不要用 bash -lc：登录 shell 会重置 PATH，导致 go 不可见）
run_go() {
  if [ "$USE_DOCKER" = 1 ]; then
    docker run --rm \
      -v "${REPO_ROOT}:/src" \
      -w /src \
      -v "${CACHE_DIR}:/gocache" \
      -e CGO_ENABLED=0 \
      -e GOCACHE=/gocache/gocache \
      -e GOPATH=/gocache/gopath \
      "${GO_IMAGE}" go "$@"
  else
    (cd "$REPO_ROOT" && CGO_ENABLED=0 go "$@")
  fi
}

mkdir -p "$OUT_DIR" "${CACHE_DIR}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "==> 版本：${VERSION}（contract ${CONTRACT_VERSION}）"
if [ "$USE_DOCKER" = 1 ]; then
  echo "==> 构建方式：docker ${GO_IMAGE}"
else
  echo "==> 构建方式：本机 go"
fi

if [ "$RUN_TEST" -eq 1 ]; then
  echo "==> go test ./..."
  run_go test ./...
fi

for arch in $ARCHES; do
  case "$arch" in
    amd64|arm64) ;;
    *) echo "不支持的架构：$arch" >&2; exit 1 ;;
  esac
  echo "==> 编译 linux/${arch}"
  stage="${TMP_ROOT}/${arch}"
  mkdir -p "$stage"
  # 容器内只挂载了仓库目录，所以产物先写到仓库下的临时目录再拷出
  build_out="${REPO_ROOT}/.build-dist-${arch}"
  rm -rf "$build_out"
  mkdir -p "$build_out"
  if [ "$USE_DOCKER" = 1 ]; then
    docker run --rm \
      -v "${REPO_ROOT}:/src" \
      -w /src \
      -v "${CACHE_DIR}:/gocache" \
      -e CGO_ENABLED=0 \
      -e GOOS=linux \
      -e "GOARCH=${arch}" \
      -e GOCACHE=/gocache/gocache \
      -e GOPATH=/gocache/gopath \
      "${GO_IMAGE}" \
      go build -trimpath -ldflags "${LDFLAGS}" -o "/src/.build-dist-${arch}/remnanode-lite" ./cmd/remnanode-lite
  else
    (cd "$REPO_ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
      go build -trimpath -ldflags "$LDFLAGS" -o "${build_out}/remnanode-lite" ./cmd/remnanode-lite)
  fi
  if [ ! -f "${build_out}/remnanode-lite" ]; then
    echo "编译失败：未生成 linux/${arch} 二进制" >&2
    exit 1
  fi
  cp "${build_out}/remnanode-lite" "${stage}/remnanode-lite"
  rm -rf "$build_out"

  printf '%s\n' \
    "remnanode-lite v${VERSION} linux/${arch}" \
    "" \
    "由 scripts/build-dist.sh 从本仓库源码构建；安装脚本会自动使用本资产。" \
    "解压后安装到 /usr/local/bin/remnanode-lite" \
    >"${stage}/README.txt"

  file="remnanode-lite_linux_${arch}.tar.gz"
  tar -C "$stage" -czf "${OUT_DIR}/${file}" remnanode-lite README.txt
  echo "    生成 $(du -h "${OUT_DIR}/${file}" | cut -f1)  ${file}"
done

( cd "$OUT_DIR" && sha256sum remnanode-lite_linux_*.tar.gz >SHA256SUMS )
echo "==> 校验文件：${OUT_DIR}/SHA256SUMS"
cat "${OUT_DIR}/SHA256SUMS"

echo
echo "下一步："
echo "  git add dist && git commit -m \"chore(dist): build v${VERSION}\""
echo "  git tag -a v${VERSION} -m \"v${VERSION}\" && git push origin main --tags"
echo "（推送 tag 后 raw.githubusercontent.com/<repo>/v${VERSION}/dist/... 即可下载）"
