#!/bin/bash
# 从上游更新 linux-headless 分支：拉取 → rebase → 测试 → 重建服务（引擎 pin 变了才重建引擎）。
# 用法: scripts/update-from-upstream.sh   （详见 docs/UPDATE.zh.md）
set -euo pipefail
cd "$(dirname "$0")/.."

# 本机编译环境三坑：mbx 劫持 cargo（用工具链真 cargo 直连）、7890 代理对 GitHub 假死（清代理）、
# cargo 内置 libgit2 卡死（改用 git CLI 拉取）。工具链名可按已安装版本覆盖。
TOOLCHAIN="${RUST_TOOLCHAIN:-1.99.1-x86_64-unknown-linux-gnu}"
export PATH="$HOME/.rustup/toolchains/$TOOLCHAIN/bin:$PATH"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cargo-target/yue2-studio}"

engine_pin() { sed -n 's/.*"commit": "\(.*\)".*/\1/p' engines/yue2-cpp-source.json; }

[ "$(git branch --show-current)" = "linux-headless" ] || { echo "[ERROR] 请在 linux-headless 分支上运行" >&2; exit 1; }
# 只看已跟踪文件的改动：untracked 的构建产物（gen/schemas 等）不该挡住更新
git diff --quiet && git diff --cached --quiet || { echo "[ERROR] 已跟踪文件有未提交改动，先提交或暂存" >&2; git status --short | head -5 >&2; exit 1; }

old_pin="$(engine_pin)"
echo "== 1/5 拉上游"
git fetch upstream
git tag "backup/$(date +%Y%m%d-%H%M)" 2>/dev/null || true
git rebase upstream/main

echo "== 2/5 测试"
cargo test --workspace

echo "== 3/5 重建服务二进制与前端依赖"
cargo build --release -p music-server
service="$CARGO_TARGET_DIR/release/music-server"
[ -x "$service" ] && echo "    → $service"
# vite 直接跑源码，不需要构建；但上游更新可能换了前端依赖
npm --prefix app install --no-audit --no-fund --silent && echo "    → app 依赖已同步"

if [ "$old_pin" != "$(engine_pin)" ]; then
    echo "== 4/5 引擎 pin 变了（$old_pin → $(engine_pin)），重建引擎（脚本自动检测 nvcc 加 CUDA 后端）"
    env PATH=/usr/local/cuda/bin:$PATH bash scripts/build-yue-runtime-linux.sh "$HOME/yue2-engine"
else
    echo "== 4/5 引擎 pin 未变（$(engine_pin)），跳过重建"
fi

echo "== 5/5 完成。重启两个进程（本 fork 只做 server 模式，不构建 desktop 壳）："
echo "    YUE_STUDIO_HEADLESS=1 YUE_ENGINE_ROOT=\$HOME/yue2-engine \\"
echo "      $service &"
echo "    cd app && npm run dev &      # UI: http://<机器IP>:3791"
echo ""
echo "    若变基通过且验证无误，推送到自己远程 fork："
echo "    git push origin linux-headless --force-with-lease"
