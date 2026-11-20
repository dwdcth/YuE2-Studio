# 从上游更新本 fork（linux-headless 分支维护指南）

> 本仓库是 [timoncool/YuE2-Studio](https://github.com/timoncool/YuE2-Studio) 的 fork，
> `linux-headless` 分支携带我们的改动：无头模式（`--headless`）+ Linux CUDA 引擎。

## 分支布局

| 分支 | 角色 | 规矩 |
|---|---|---|
| `main` | 只跟上游 | **永不直接提交**，只 `git pull`（快进）|
| `linux-headless` | 我们的集成分支 | 所有本地改动都在这里，以 `main` 为基线 rebase |

`origin` = 上游仓库。改动全部固化在少量提交里（`git log origin/main..` 可见），
rebase 时按 hunk 解决冲突，不产生长期的 merge 历史。

## 日常更新（五步，或直接跑脚本）

```bash
scripts/update-from-upstream.sh        # 一条命令做完全部五步
```

手工执行等价于：

```bash
# 0. 本机编译环境三坑（脚本里已内置）：
#    - cargo 被 mbx 包装器劫持 → 用工具链目录里的真 cargo
#    - 7890 代理对 GitHub 假死   → 清空代理环境变量直连
#    - cargo 内置 libgit2 卡死   → CARGO_NET_GIT_FETCH_WITH_CLI=true
export PATH=$HOME/.rustup/toolchains/1.99.1-x86_64-unknown-linux-gnu/bin:$PATH
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export CARGO_NET_GIT_FETCH_WITH_CLI=true CARGO_TARGET_DIR=$HOME/.cargo-target/yue2-studio

# 1. 拉上游
git switch main && git pull --ff-only && git switch linux-headless

# 2. 重放我们的改动（更新前先打 tag，随时可退）
git tag backup/$(date +%Y%m%d) || true
git rebase main

# 3. 测试
cargo test --workspace

# 4. 重建（引擎 pin 变了才重建引擎）
cargo build --release -p music-server
old_pin 变了 → PATH=/usr/local/cuda/bin:$PATH \
  scripts/build-yue-runtime-linux.sh ~/yue2-engine   # 脚本自动检测 nvcc 加 CUDA 后端

# 5. 重启服务（用 systemd 或手工）
```

**本机部署架构（2026-11-20 定型）**：Rust 后台服务 + vite 出 UI，不用 desktop 壳。

```bash
# 服务（0.0.0.0:8791，无头网络强制，引擎 CUDA）
YUE_STUDIO_HEADLESS=1 YUE_ENGINE_ROOT=$HOME/yue2-engine \
  ~/.cargo-target/yue2-studio/release/music-server &

# UI（0.0.0.0:3791，浏览器从局域网直接开 http://<机器IP>:3791；
# 代理已把 Origin 改写为 loopback 过服务端守卫，见 app/vite.config.ts）
cd app && npm run dev &
```

desktop 壳（浏览器 UI 的 `--headless` 二进制）只在界面代码变了时才值得重建：
`cd desktop/src-tauri && cargo build --release`（注意它用独立的
`CARGO_TARGET_DIR=$HOME/.cargo-target/yue2-desktop`）。

## 冲突高发区与判定锚点

**2026-11-20 实战记录**（a35616e → 8df2deb，跨 v3.8.4–v4.1.0）：上游 v4.x
自己实现了 Linux CUDA 引擎链路（构建脚本自动检测 nvcc、PyPI wheel 版
cuBLAS、cuda12 支持）和 `--headless`（托盘语义，面向有桌面的机器）——
我们与上游重叠的改动全部**改为跟随上游**，只保留 music-server 侧的独有
贡献：`YUE_STUDIO_HEADLESS=1` 无头网络强制、SIGTERM 优雅停机、settings
手写文件修复、pick-executable 传路径、`cuda_build()` 的 Auto 目录门
（显式 CUDA 不受门限制，缺后端由 restart_engine 明确报错）。
冲突解法：**上游已实现等价功能的一律取上游**，我们的残留引用（如已被
上游删除的函数）改写为上游风格；上游测试在特定硬件（Turing 卡的
FP16 clamp、文件名字面量）上的环境敏感 bug 顺手修正。

上游改动如果碰到这些函数/区域就会冲突，每个改动在代码里都留了注释锚点（搜
`headless`、`Linux`、`cuda13`）：

| 文件 | 我们的改动 | 上游常见动因 |
|---|---|---|
| `crates/music-server/src/lib.rs` | `serve()` 的 forced env、`shutdown()/close_the_studio()`、`cancel_job()`、`cuda_build()` 的 Auto 目录门 | 新功能加路由（不冲突）、引擎选项重构（冲突）|
| `crates/music-server/src/remote.rs` | `start(saved, forced)`、`persisted()`、`print_access()` | 网络访问功能演进 |
| `crates/music-server/src/install_record.rs` | `write()` 补建父目录 | 下载记录机制演进 |
| 测试模块 | settings 最小文件测试 | 同位置插入新测试（两边都保）|

冲突解法原则：**保上游的新逻辑，把我们的"headless/平台分支"语义贴上去**——
我们的改动几乎都是"在既有决策点上加一个 Linux/headless 条件"，很少整体改写。

## 何时需要重建什么

| 上游变了什么 | 需要做什么 |
|---|---|
| Rust 代码 | `cargo build --release -p music-server`（+ 跑测试）|
| `engines/yue2-cpp-source.json` 的 commit | 重建引擎（脚本自动检测 pin 变化）|
| 前端 `app/` | `npm --prefix app run build` + 重建 desktop 壳（UI 内嵌在二进制里）|
| 模型 pin（`model_manager.rs` 的 sha/版本）| 无需手动：工作室自己检测并按 setup 流程下载 |
| `rust-toolchain.toml` / 上游要求的 Rust 版本 | 按用户自己装的 rustup 工具链对齐 |

## 回退

rebase 出问题：`git rebase --abort` 回到更新前；已提交但想放弃：
`git reset --hard backup/<日期tag>`。

## 长期路线：把改动推回上游

上游 README 明确欢迎 Linux 修复（"If you live on Linux, it would be great if
you polished them and sent the fixes back as a pull request"）。我们的改动
全部用上游的英文注释风格写成，天然适合拆成 PR：

1. 无头模式（服务 + desktop 壳 + 文档）——通用功能，Windows 也受益；
2. Linux CUDA 引擎链路（hardware/engine_runtime/构建脚本）；
3. 小修：settings serde 默认值、install_record 建目录、pick-executable 传路径。

上游合并哪部分，我们就从本分支删掉对应提交，维护负担随之消失。
