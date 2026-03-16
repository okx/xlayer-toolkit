# SP1 zkVM 目标 triple 与 std::thread 实现定位

## 1. 目标 triple（Target Triple）

| 版本 | Target |
|------|--------|
| sp1-build 6.x | `riscv64im-succinct-zkvm-elf` |
| sp1-build 5.x | `riscv32im-succinct-zkvm-elf` |

你的 fibonacci 使用 sp1-build 6.0.1，故 **program 编译目标为 `riscv64im-succinct-zkvm-elf`**。

来源：`sp1-build-6.0.2/src/lib.rs` 第 16 行：
```rust
pub const DEFAULT_TARGET: &str = "riscv64im-succinct-zkvm-elf";
```

---

## 2. std 实现来源

该 target 为 **Succinct 自定义目标**，不在 upstream Rust 中。std 实现由 **succinct 工具链** 提供，工具链通过 `sp1up` 安装，路径通常为：

- 默认：`~/.sp1/toolchains/<hash>/`
- 自定义：`$SP1_DIR`（如 `$SP1_DIR/toolchains/nJ3yR87w4U`）

---

## 3. 定位 thread 实现的命令

在服务器或本机执行（根据实际路径替换 `$TOOLCHAIN`）：

```bash
# 方法 A：用 rustup 查 succinct 工具链路径
TOOLCHAIN=$(rustup show | grep -A1 "succinct" | grep "path" | awk '{print $2}')
echo "Toolchain: $TOOLCHAIN"

# 方法 B：若用环境变量
TOOLCHAIN="${RUSTUP_TOOLCHAIN:-/Users/xzavieryuan/go/bin/toolchains/nJ3yR87w4U}"
# 若 RUSTUP_TOOLCHAIN 是路径则直接用，否则用你已知的路径

# 查 rust-src 位置（工具链内置源码）
find "$TOOLCHAIN" -name "thread.rs" -path "*/library/std/*" 2>/dev/null

# 或按标准 layout 查
ls -la "$TOOLCHAIN/lib/rustlib/src/rust/library/std/src/sys/"
# 看是否有 riscv64im_succinct_zkvm_elf 或类似目录
```

---

## 4. 可能的 sys 模块结构

Rust 的 `library/std` 按 target 选择实现，通常：

```
library/std/src/sys/
  ├── unsupported/     # 不支持的功能统一返回 Err
  │   └── thread.rs   # 若 target 用此，直接返回 Unsupported
  └── <target_name>/   # 如 riscv64im_succinct_zkvm_elf
      └── ...
```

若 `riscv64im-succinct-zkvm-elf` 使用 `sys/unsupported/thread.rs`，则 **不会执行 ecall**，错误在纯 Rust 层返回。

---

## 5. 快速验证：查看报错栈中的 sys 路径

你之前的报错：

```
thread/functions.rs:131:29
```

可对应 `library/std/src/thread/functions.rs` 第 131 行。查看该函数调用的 `sys::xxx::thread` 模块即可确认：

```bash
# 在工具链的 rust-src 中
grep -r "mod thread" "$TOOLCHAIN/lib/rustlib/src/rust/library/std/src/sys/" 2>/dev/null
```

或直接看 `library/std/src/thread/mod.rs` 中的 `#[path = ...]`，确定当前 target 使用的 sys 模块。

---

## 6. 若本机没有工具链源码

Succinct 工具链可能不随附 `rust-src`，此时可：

1. **查 Rust 官方 repo**：  
   https://github.com/rust-lang/rust/blob/master/library/std/src/thread/functions.rs  
   对照 `spawn` 实现，追踪其调用的 `sys::...::Thread`。

2. **查 SP1 仓库**：  
   https://github.com/succinctlabs/sp1  
   搜索 `riscv64im_succinct_zkvm_elf`、`thread`、`sys`，看是否有对 std 的 patch 或自定义 target 配置。
