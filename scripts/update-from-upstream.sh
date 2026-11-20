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
[ -z "$(git status --porcelain)" ] || { echo "[ERROR] 工作区不干净，先提交或暂存" >&2; exit 1; }

old_pin="$(engine_pin)"
echo "== 1/5 拉上游"
git fetch origin
git tag "backup/$(date +%Y%m%d-%H%M)" 2>/dev/null || true
git rebase origin/main

echo "== 2/5 测试"
cargo test --workspace

echo "== 3/5 重建服务二进制"
cargo build --release -p music-server
service="$CARGO_TARGET_DIR/release/music-server"
[ -x "$service" ] && echo "    → $service"

if [ "$old_pin" != "$(engine_pin)" ]; then
    echo "== 4/5 引擎 pin 变了（$old_pin → $(engine_pin)），重建 CUDA 引擎"
    env PATH=/usr/local/cuda/bin:$PATH bash scripts/build-yue-runtime-linux.sh "$HOME/yue2-engine" -RuntimeBackend cuda
else
    echo "== 4/5 引擎 pin 未变（$(engine_pin)），跳过重建"
fi

echo "== 5/5 完成。提醒："
echo "    - 前端变了才需要重建 desktop 壳（浏览器 UI）: cd desktop/src-tauri && CARGO_TARGET_DIR=\$HOME/.cargo-target/yue2-desktop cargo build --release"
echo "    - 重启你的无头服务（yue2-studio-desktop --headless 或 music-server + YUE_STUDIO_HEADLESS=1）"
