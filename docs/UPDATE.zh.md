# 从上游更新本 fork（linux-headless 分支维护指南）

> 本仓库是 [timoncool/YuE2-Studio](https://github.com/timoncool/YuE2-Studio) 的 fork，
> `linux-headless` 分支携带我们的改动：无头模式（`--headless`）+ Linux CUDA 引擎 + **RTX 2080 Ti 专属推理加速资产与优化默认配置**。

## 本 fork 的固定原则（2026-11-20 定型，2026-11-24 增补，以后更新不变）

1. **只做 server 模式**：Rust 后台服务（standalone `music-server`，无头网络强制
   `YUE_STUDIO_HEADLESS=1`）+ vite 出 UI（`0.0.0.0:3791`，代理已改写 Origin 过
   服务端守卫）。**desktop 壳（desktop/src-tauri）保持上游原状，永不构建、
   永不修改**——上游更新时该目录直接跟上游，rebase 冲突一律取上游侧。
2. **Linux 引擎只编译本机的显卡**：`build-yue-runtime-linux.sh` 默认用
   `nvidia-smi` 探测本机卡只编那一代架构（Turing SM 7.5，只编 `f16-f16;q8_0-q8_0`，约 3 分钟，产物 ~54MB）；更新时
   **不要**改回六代全量和全量 FA 量化。只有产物要拷去别的机器时才
   `YUE_CUDA_ARCHITECTURES=universal`。
3. **保持 2080 Ti 专属推理加速资产与优化默认值**：
   - 补丁目录：`engines/patches/yue2/` 托管底层 C++/CUDA 补丁（FlashAttention 解锁 `ncols=64`、双向无 Mask 快速路径、F16 权重预反量化、静态图、单趟最小堆采样等）。
   - 默认求解器：前端 `CreatePanel.tsx` 与后端服务统一默认选用 **`ab2` (Adams-Bashforth 2)** 16 步快速求解器。
   - 默认环境变量：`yue_server.rs` 进程监控默认注入硬件加速环境变量。
   - 默认数值安全截断：`clamp_fp16` 默认开启，配合融合算子确保防溢出零额外耗时。

## 分支与远程布局

| 远程 / 分支 | 角色 | 规矩 |
|---|---|---|
| `upstream` (`timoncool/YuE2-Studio`) | 官方上游 | 只读，永不推送；只 `git fetch upstream` |
| `origin` (`dwdcth/YuE2-Studio`) | 我们自己的 fork | **推送目标**：每次本地提交或变基后推送到这里的 `linux-headless` |
| `main` | 只跟上游 | **永不直接提交**，只 `git pull --ff-only`（快进）|
| `linux-headless` | 我们的集成分支 | 所有本地改动都在这里，以 `upstream/main` 为基线 rebase |

改动全部固化在清晰的提交里（`git log upstream/main..` 可见），rebase 时按 hunk 解决冲突，不产生长期的 merge 历史。

## 日常更新与远程推送流程（五步，或直接跑脚本）

可以直接运行自动化脚本：
```bash
scripts/update-from-upstream.sh        # 一条命令做完全部步骤
```

手工执行详细步骤：

```bash
# 0. 本机编译环境三坑（脚本里已内置）：
#    - cargo 被 mbx 包装器劫持 → 用工具链目录里的真 cargo
#    - 7890 代理对 GitHub 假死   → 清空代理环境变量直连
#    - cargo 内置 libgit2 卡死   → CARGO_NET_GIT_FETCH_WITH_CLI=true
export PATH=$HOME/.rustup/toolchains/1.99.1-x86_64-unknown-linux-gnu/bin:$PATH
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export CARGO_NET_GIT_FETCH_WITH_CLI=true CARGO_TARGET_DIR=$HOME/.cargo-target/yue2-studio

# 1. 拉上游并备份本地状态
git fetch upstream
git tag "backup/$(date +%Y%m%d-%H%M)" 2>/dev/null || true

# 2. 变基重放我们的改动
git rebase upstream/main

# 3. 运行测试
cargo test --workspace

# 4. 重建服务二进制与前端依赖
cargo build --release -p music-server
npm --prefix app install --no-audit --no-fund --silent
npm --prefix app run build    # 更新生产 UI 静态资源

# 若引擎 pin 变了（见下节详细说明），重建引擎：
env PATH=/usr/local/cuda/bin:$PATH \
  scripts/build-yue-runtime-linux.sh ~/yue2-engine

# 5. 推送更新到我们自己的远程 fork (origin)
git push origin linux-headless --force-with-lease
```

## 冲突高发区与判定锚点

上游改动如果碰到这些区域就会冲突，每个改动在代码里都留了注释锚点：

| 文件 / 资产 | 我们的改动 | 冲突判定与解法 |
|---|---|---|
| `engines/patches/yue2/*.patch` | 2080 Ti 专属算子与架构补丁 | 见下节“引擎补丁维护指南” |
| `scripts/build-yue-runtime-linux.sh` | 自动打补丁 + `75-real` 与 FA 精度裁剪 | 保留 patch 应用与针对本卡的编译加速参数 |
| `app/components/CreatePanel.tsx` | 默认求解器为 `ab2` + 下拉框配置 | 保留 `solver || 'ab2'` 逻辑，UI 其它新功能跟随上游 |
| `app/components/EngineSettings.tsx` | `clamp_fp16` 默认设为 `true` | 保留 `clamp_fp16: true`，合并上游新设置项 |
| `crates/music-engine/src/yue_server.rs` | 默认注入 4 项硬件加速环境变量 | 保留 `command.env("YUE_...")` 默认注入逻辑 |
| `crates/music-server/src/lib.rs` | `yue_request_from` 默认 solver 为 `"ab2"` + 无头模式守卫 | 保留 `unwrap_or("ab2")` 与 headless 网络逻辑 |
| `desktop/src-tauri/` | 完全不做修改 | 冲突一律取上游侧（`git checkout --ours` 或直接跟上游） |

冲突解法原则：**保上游的新功能与逻辑演进，把我们的“headless网络守卫 + 2080Ti加速配置”贴上去**。

---

## 引擎补丁维护指南（当原版 yue2.cpp 更新时）

上游 YuE2-Studio 会定期通过 `engines/yue2-cpp-source.json` 更新 `yue2.cpp` 的 commit pin。当引擎 pin 发生变动时：

### 1. 自动构建与补丁应用
`scripts/build-yue-runtime-linux.sh` 在执行 `git checkout $commit && git submodule update` 之后，会自动尝试将 `engines/patches/yue2/` 下的补丁打入临时源码目录：
```bash
git -C "$worktree" apply --ignore-whitespace engines/patches/yue2/yue2_2080ti.patch
git -C "$worktree/ggml" apply --ignore-whitespace engines/patches/yue2/ggml_2080ti.patch
```

### 2. 若上游 yue2.cpp 结构变动导致补丁冲突：
如果构建日志提示 `yue2 patch already applied or skipped` 且实际出现编译错误，说明上游改动了相同代码区域。按以下步骤重新适配补丁：

1. **进入工作树定位冲突**：
   ```bash
   cd /tmp/yue2-engine
   git status
   # 尝试使用 3-way 方式或 reject 模式查看冲突点
   git apply --reject /mnt/s790/project/YuE2-Studio/engines/patches/yue2/yue2_2080ti.patch
   git -C ggml apply --reject /mnt/s790/project/YuE2-Studio/engines/patches/yue2/ggml_2080ti.patch
   ```
2. **重点保护的算子改动点**：
   - `ggml/src/ggml-cuda/fattn-mma-f16.cuh`：解除 SM 7.5 下 `ncols > 32` 的限制，保留 Turing `ncols=64`、`occupancy=3`、`nstages=1` 的特化调度分支。
   - `ggml/src/ggml-cuda/fattn.cu`：NAR 无 Mask 纯双向注意力的跳过 `scan_mask` 分支。
   - `src/sampling.h`：AR 采样的 Min-Heap Top-k 单趟算法（避免 151k 全量分词排序）。
   - `src/nar.h`：`StaticGraph` 静态图持有、零拷贝 QKV 切分视图、NAR FP16 预转权重支持。
3. **重新生成补丁**：
   解决冲突并验证编译通过后，在 `/tmp/yue2-engine` 重新导出补丁：
   ```bash
   cd /tmp/yue2-engine
   git diff src/ > /mnt/s790/project/YuE2-Studio/engines/patches/yue2/yue2_2080ti.patch
   git -C ggml diff src/ggml-cuda/ > /mnt/s790/project/YuE2-Studio/engines/patches/yue2/ggml_2080ti.patch
   ```
4. **运行回归压测**：
   编译新引擎并运行压测脚本确认性能与音质：
   ```bash
   python3 /home/banshan/.gemini/antigravity-cli/brain/7e4907e7-5662-4702-ba41-29c54e931425/scratch/run_opt_bench.py round2
   ```

---

## 远程仓库维护与推送规范

### 1. 推送规则
- **唯一远端**：`origin` (`https://github.com/dwdcth/YuE2-Studio.git`)。
- **目标分支**：`linux-headless`。
- **严禁操作**：**切勿推送到 `upstream`**（这是上游官方仓库）。

### 2. 推送命令
- **日常本地普通提交后推送**：
  ```bash
  git push origin linux-headless
  ```
- **执行 `git rebase upstream/main` 之后推送**：
  因为 rebase 会改写历史提交基线，必须使用带租约的强制推送（安全防覆盖）：
  ```bash
  git push origin linux-headless --force-with-lease
  ```

### 3. 故障回滚预案
如果 rebase 过程出现混乱，可立即中止回滚：
```bash
git rebase --abort
```
如果变基已完成但需要彻底撤销，恢复到更新前自动打的标签：
```bash
git reset --hard backup/<时间戳标签>
```
