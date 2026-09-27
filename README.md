# Python-Static

为 [Bili23 Downloader](https://github.com/ScottSloan/Bili23-Downloader) 定制的便携式 Python 运行时。

- **Linux / macOS**：静态编译 Python，并将 `libpython` 与 OpenSSL 静态链接进加载器 [Bili23-Downloader-Loader](https://github.com/ScottSloan/Bili23-Downloader-Loader)（基于 PyStand），无需系统安装 Python。
- **Windows**：直接使用官方 Embeddable 版本，另附依赖包。

> [!NOTE]
> 本仓库只保存构建脚本。[Releases](https://github.com/ScottSloan/Python-Static/releases) 中的运行时均为预先在本地构建好后上传的。

## Release 文件

| 文件 | 平台 | 最低系统要求 |
| --- | --- | --- |
| `windows_x64_runtime.zip` | Windows x64 | Windows 10 / 11 |
| `windows_x64_runtime_for_win7.zip` | Windows x64 | Windows 7 |
| `linux_amd64_runtime.zip` | Linux x86_64 | Ubuntu 20.04 / Debian 11 / Fedora 32 / RHEL 9 |
| `linux_arm64_runtime.zip` | Linux aarch64 | Ubuntu 24.04 / Debian 13 / Fedora 40 / RHEL 10 |
| `macos_aarch64_runtime.zip` | macOS Apple Silicon | macOS 12 Monterey |
| `macos_x86_64_runtime.zip` | macOS Intel | macOS 12 Monterey |

当前版本组件：

| 组件 | 版本 |
| --- | --- |
| Python | 3.13.13 |
| OpenSSL（Linux / macOS） | 3.3.0 |
| libffi（Linux / macOS） | 3.4.8 |
| PySide6 | Linux / macOS 6.9.3，Windows 6.10.2，Windows 7 6.8.3 |
| FFmpeg | 9.0.1 |

## 目录结构

### Linux / macOS

```
<platform>_runtime.zip
├── bili23-downloader        加载器（主程序）
├── _pystand_static.int      Python 入口脚本
├── bundle/
│   └── ffmpeg
├── runtime/                 PYTHONHOME
│   └── lib/python3.13/
│       ├── lib-dynload/     C 扩展模块
│       ├── site-packages/   依赖包
│       └── ...              标准库
└── LICENSE
```

运行流程：

1. `bili23-downloader` 以自身所在目录为根目录，将 `runtime/` 设为 `PYTHONHOME`，在隔离模式下初始化内嵌的 Python 解释器。
2. 执行 `_pystand_static.int`，将 `script/` 加入 `sys.path`，然后调用 `main._main()`。
3. 程序源码（Bili23-Downloader 仓库的 `src/`）需放到根目录下的 `script/` 中，不包含在本运行时内。

`_ssl` 和 `_hashlib` 被编译进 `libpython`，与 OpenSSL 一起静态链接进加载器，因此不依赖系统的 OpenSSL。

### Windows

```
windows_x64_runtime.zip
├── runtime/          官方 Embeddable Python（python313._pth 指向 python313.zip）
├── site-packages/    依赖包（含 pywin32）
├── bundle/
│   └── ffmpeg.exe
└── LICENSE
```

自 v0.1.8 起，Windows 版不再附带加载器。

#### Windows 10 / 11

- Python：[python.org](https://www.python.org/downloads/windows/) 官方的 `python-3.13.13-embed-amd64.zip`
- 依赖：直接从 PyPI 安装

#### Windows 7

官方的 Python 3.13、PySide6 与部分依赖的二进制已不支持 Windows 7，需要替换为以下版本：

| 组件 | 来源 |
| --- | --- |
| Python 3.13.13 | [adang1345/PythonVista](https://github.com/adang1345/PythonVista)（附带 `api-ms-win-core-path-l1-1-0.dll`） |
| PySide6 6.8.3 | 基于 [crystalidea/qt6windows7](https://github.com/crystalidea/qt6windows7) |
| orjson 3.12.0 | 自行编译，见下文 |
| 其余依赖 | 与 Windows 10 / 11 版相同 |

目标机器需要 Windows 7 SP1，并安装 KB2533623（或 KB3063858）和 Universal C Runtime（KB2999226）。

**orjson**

从 Rust 1.78 起，`x86_64-pc-windows-msvc` 目标最低要求 Windows 10。PyPI 上的 orjson wheel 会静态导入 `WaitOnAddress`（Windows 8+），在 Windows 7 上无法加载。

解决方法是用 Rust 的 tier-3 目标 `x86_64-win7-windows-msvc` 重新编译，orjson 源码无需修改。该目标没有预编译的标准库，需要 nightly 工具链并开启 `build-std`：

```powershell
rustup toolchain install nightly-2026-08-01 --profile minimal --component rust-src

# 在 orjson 源码根目录执行
cargo +nightly-2026-08-01 build --release `
    --target x86_64-win7-windows-msvc `
    --features="no_panic,optimize" `
    --config 'unstable.build-std=["core","std","alloc","panic_abort"]'
```

然后把 `target/x86_64-win7-windows-msvc/release/orjson.dll` 重命名为 `orjson.cp313-win_amd64.pyd`，替换 `site-packages/orjson/` 中的同名文件。

orjson 扩展不是 abi3，编译时使用的 Python 小版本必须与运行时一致（3.13）。

以上组件均已在 Windows 7 实机上验证可用。

## 构建 Linux / macOS 运行时

`build.sh` 会自动识别当前平台（`linux_amd64` / `linux_arm64` / `macos_aarch64` / `macos_x86_64`），依次完成：

1. 编译静态库 libffi、OpenSSL（macOS 额外编译 xz）
2. 编译 Python（PGO 优化，`_ssl` / `_hashlib` 静态内置）
3. 安装 [`requirements.txt`](requirements.txt) 中的依赖
4. 编译加载器
5. 组装并精简运行时（[`scripts/trim_runtime.py`](scripts/trim_runtime.py)）
6. 打包为 `dist/<platform>_runtime.zip`

所有中间文件都在 `build/` 下，无需 `sudo`。

### 准备环境

**Linux（Debian / Ubuntu）**

```bash
sudo apt install build-essential cmake git curl zip pkg-config perl \
    zlib1g-dev libbz2-dev liblzma-dev libsqlite3-dev uuid-dev \
    libreadline-dev libncurses-dev
```

**macOS**

```bash
xcode-select --install
brew install cmake pkgconf
```

### 开始构建

```bash
./build.sh
```

生成的文件位于 `dist/`：

```
dist/
├── linux_amd64_runtime/       解压后的运行时
└── linux_amd64_runtime.zip    可直接上传到 Release
```

### 可选参数

通过环境变量传入，例如：

```bash
PYTHON_VERSION=3.13.13 FFMPEG=/path/to/ffmpeg ./build.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PYTHON_VERSION` | `3.13.13` | Python 版本 |
| `OPENSSL_VERSION` | `3.3.0` | OpenSSL 版本 |
| `LIBFFI_VERSION` | `3.4.8` | libffi 版本 |
| `XZ_VERSION` | `5.8.1` | xz 版本（仅 macOS） |
| `MACOSX_DEPLOYMENT_TARGET` | `12.0` | macOS 最低兼容版本 |
| `LOADER_REF` | `main` | 加载器仓库的分支或标签 |
| `FFMPEG` | 空 | ffmpeg 可执行文件路径，设置后复制到 `bundle/ffmpeg` |
| `SKIP_DEPS` | `0` | 设为 `1` 时不安装 site-packages 依赖 |
| `SKIP_LOADER` | `0` | 设为 `1` 时不编译加载器 |
| `BUILD_DIR` / `DIST_DIR` | `./build` / `./dist` | 中间文件与产物目录 |

`LICENSE` 需要手动放入运行时目录。

### 注意事项

- **glibc 版本**：Linux 版对 glibc 的最低要求取决于构建所用的系统。要兼容更旧的发行版，需要在更旧的系统（或容器）中构建。当前 amd64 版在 Ubuntu 20.04 下构建，arm64 版在 Ubuntu 24.04 下构建。
- **Linux 系统库**：部分扩展模块会动态链接系统库，目标机器需具备 `libz`、`libbz2`、`liblzma`、`libsqlite3`、`libuuid`、`libstdc++`，常见桌面发行版均已自带。
- **macOS 动态库**：构建脚本会避免链接 Homebrew 的动态库（`_decimal` 使用内置 libmpdec，`_lzma` 静态链接 xz，不构建 `_gdbm`），否则程序在未安装 Homebrew 的机器上会找不到依赖。CI 中会用 `otool -L` 检查。
- **PySide6 版本**：固定为 6.9.x，因为更高版本不再支持 macOS 12。
- **精简规则**：`trim_runtime.py` 会删除用不到的标准库（`tkinter`、`unittest`、`test` 等）、打包元数据，并按白名单只保留 `QtCore`、`QtGui`、`QtWidgets`、`QtNetwork`、`QtSvg`、`QtSvgWidgets`、`QtXml`、`QtDBus`。macOS 下还会删除未用到的 PyObjC 框架绑定。如果程序新增了对其他 Qt 模块的依赖，需要同步修改白名单。可以用 `--dry-run` 预演：

  ```bash
  python3 scripts/trim_runtime.py dist/linux_amd64_runtime/runtime --dry-run
  ```

## GitHub Actions

| Workflow | 说明 |
| --- | --- |
| [`build.yml`](.github/workflows/build.yml) | 手动触发，在 macOS（arm64 / Intel）上执行 `build.sh` 并上传产物 |
| [`test_runtime.yml`](.github/workflows/test_runtime.yml) | 下载 Release 中的 macOS 运行时，搭配程序源码进行启动测试 |
| [`get_depend.yml`](.github/workflows/get_depend.yml) | 手动触发，在 macOS arm64 上下载依赖包 |
