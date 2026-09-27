#!/usr/bin/env bash
# -----------------------------------------------------------
# Bili23 Downloader 静态 Python 运行时构建脚本（Linux / macOS）
#
# 产物：dist/<平台>_runtime/
#   ├── bili23-downloader      加载器（静态链接 libpython3.13 + OpenSSL）
#   ├── _pystand_static.int    Python 入口脚本
#   ├── bundle/ffmpeg          可选，通过 FFMPEG 环境变量提供
#   └── runtime/lib/python3.13 标准库、lib-dynload、site-packages
#
# 用法：
#   ./build.sh
#   PYTHON_VERSION=3.13.13 FFMPEG=/path/to/ffmpeg ./build.sh
#
# 可用环境变量见下方「配置」一节，均可在命令行覆盖。
# -----------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------
# 配置
PYTHON_VERSION="${PYTHON_VERSION:-3.13.13}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.3.0}"
LIBFFI_VERSION="${LIBFFI_VERSION:-3.4.8}"
XZ_VERSION="${XZ_VERSION:-5.8.1}"

# macOS 最低兼容版本（PySide6 6.9 最低支持 macOS 12）
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

LOADER_REPO="${LOADER_REPO:-https://github.com/ScottSloan/Bili23-Downloader-Loader.git}"
LOADER_REF="${LOADER_REF:-main}"

# 设为 1 时跳过对应步骤
SKIP_DEPS="${SKIP_DEPS:-0}"        # 不安装 site-packages 依赖
SKIP_LOADER="${SKIP_LOADER:-0}"    # 不编译加载器

# 可选：打包进 bundle/ 的 ffmpeg 可执行文件
FFMPEG="${FFMPEG:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

SRC_DIR="$BUILD_DIR/src"
PREFIX_DIR="$BUILD_DIR/prefix"
LIBFFI_PREFIX="$PREFIX_DIR/libffi-static"
OPENSSL_PREFIX="$PREFIX_DIR/openssl-static"
XZ_PREFIX="$PREFIX_DIR/xz-static"
PYTHON_PREFIX="$PREFIX_DIR/python-static"

PY_MAJOR_MINOR="${PYTHON_VERSION%.*}"
PYTHON_BIN="$PYTHON_PREFIX/bin/python$PY_MAJOR_MINOR"

# -----------------------------------------------------------
# 工具函数
log() {
	printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

die() {
	printf '\033[1;31m[错误] %s\033[0m\n' "$*" >&2
	exit 1
}

require() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
	done
}

# 下载并解压源码包，已存在则跳过下载
fetch() {
	local url="$1" dir="$2"
	local file="$SRC_DIR/$(basename "$url")"

	[ -f "$file" ] || curl -fL --retry 3 -o "$file" "$url"
	rm -rf "${SRC_DIR:?}/$dir"
	tar -xzf "$file" -C "$SRC_DIR"
}

# -----------------------------------------------------------
# 检测平台
case "$(uname -s)-$(uname -m)" in
	Linux-x86_64)   PLATFORM=linux_amd64 ;;
	Linux-aarch64)  PLATFORM=linux_arm64 ;;
	Darwin-arm64)   PLATFORM=macos_aarch64 ;;
	Darwin-x86_64)  PLATFORM=macos_x86_64 ;;
	*) die "不支持的平台：$(uname -s) $(uname -m)" ;;
esac

case "$PLATFORM" in
	linux_*) OS=linux; JOBS="$(nproc)" ;;
	macos_*) OS=macos; JOBS="$(sysctl -n hw.ncpu)" ;;
esac

OUTPUT_DIR="$DIST_DIR/${PLATFORM}_runtime"

require curl tar zip make pkg-config perl
[ "$SKIP_LOADER" = 1 ] || require git cmake

mkdir -p "$SRC_DIR" "$PREFIX_DIR"

log "平台：$PLATFORM，Python $PYTHON_VERSION，OpenSSL $OPENSSL_VERSION，libffi $LIBFFI_VERSION"

# -----------------------------------------------------------
# 编译 libffi（仅静态库）
log "编译 libffi $LIBFFI_VERSION"
fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" "libffi-$LIBFFI_VERSION"
(
	cd "$SRC_DIR/libffi-$LIBFFI_VERSION"
	./configure --disable-shared --enable-static --with-pic --disable-docs --prefix="$LIBFFI_PREFIX"
	make -j"$JOBS"
	make install
)

# -----------------------------------------------------------
# 编译 OpenSSL（仅静态库）
log "编译 OpenSSL $OPENSSL_VERSION"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"
(
	cd "$SRC_DIR/openssl-$OPENSSL_VERSION"

	case "$PLATFORM" in
		macos_aarch64) target=darwin64-arm64-cc ;;
		macos_x86_64)  target=darwin64-x86_64-cc ;;
		*)             target= ;;
	esac

	./config $target no-shared no-tests --prefix="$OPENSSL_PREFIX" --openssldir="$OPENSSL_PREFIX/ssl" --libdir=lib
	make -j"$JOBS"
	make install_sw
)

# -----------------------------------------------------------
# 编译 xz（仅 macOS）
# macOS 系统不自带 liblzma，若链接 Homebrew 的动态库，
# 在未安装 Homebrew 的机器上 import lzma 会失败，因此改为静态链接
if [ "$OS" = macos ]; then
	log "编译 xz $XZ_VERSION"
	fetch "https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION/xz-$XZ_VERSION.tar.gz" "xz-$XZ_VERSION"
	(
		cd "$SRC_DIR/xz-$XZ_VERSION"
		./configure --disable-shared --enable-static --with-pic --disable-nls --disable-doc \
			--disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-lzma-links --disable-scripts \
			--prefix="$XZ_PREFIX"
		make -j"$JOBS"
		make install
	)
fi

# -----------------------------------------------------------
# 编译 Python
log "编译 Python $PYTHON_VERSION"
fetch "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz" "Python-$PYTHON_VERSION"
(
	cd "$SRC_DIR/Python-$PYTHON_VERSION"

	# 关键：将 _ssl / _hashlib 编译进 libpython，由加载器静态链接 OpenSSL
	cat > Modules/Setup.local <<'EOF'
*static*
_ssl _ssl.c $(OPENSSL_INCLUDES) $(OPENSSL_LDFLAGS) -lssl -lcrypto -ldl -lpthread
_hashlib _hashopenssl.c $(OPENSSL_INCLUDES) $(OPENSSL_LDFLAGS) -lcrypto -ldl -lpthread
EOF

	export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$LIBFFI_PREFIX/lib"
	export CPPFLAGS="-I$OPENSSL_PREFIX/include -I$LIBFFI_PREFIX/include"
	export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$LIBFFI_PREFIX/lib/pkgconfig"
	export PKG_CONFIG="pkg-config --static"

	# 兼容 macOS 自带的 bash 3.2：空数组需用 ${arr[@]+"${arr[@]}"} 展开
	extra_args=()

	if [ "$OS" = macos ]; then
		# 优先链接指定目录下的静态库，避免链接到 Homebrew 的动态库
		export LDFLAGS="$LDFLAGS -Wl,-search_paths_first"
		export LIBLZMA_CFLAGS="-I$XZ_PREFIX/include"
		export LIBLZMA_LIBS="$XZ_PREFIX/lib/liblzma.a"

		extra_args+=(
			# 不链接 Homebrew 的 libintl
			ac_cv_lib_intl_textdomain=no
			# 不构建依赖 Homebrew gdbm 的模块，dbm 仅使用系统自带的 ndbm
			py_cv_module__gdbm=n/a
			--with-dbmliborder=ndbm
		)
	fi

	# --without-system-libmpdec：使用内置 libmpdec，避免 _decimal 依赖外部动态库
	# --disable-test-modules：不构建 _testcapi 等测试模块
	./configure \
		--prefix="$PYTHON_PREFIX" \
		--disable-shared \
		--enable-optimizations \
		--with-openssl="$OPENSSL_PREFIX" \
		--with-ensurepip=install \
		--without-system-libmpdec \
		--disable-test-modules \
		${extra_args[@]+"${extra_args[@]}"}

	make -j"$JOBS"
	make altinstall
)

"$PYTHON_BIN" -c "import ssl, hashlib, ctypes, lzma, decimal, sqlite3; print(ssl.OPENSSL_VERSION)"

# -----------------------------------------------------------
# 安装 site-packages 依赖
if [ "$SKIP_DEPS" != 1 ]; then
	log "安装 Python 依赖"
	"$PYTHON_BIN" -m pip install --no-cache-dir --upgrade pip
	"$PYTHON_BIN" -m pip install --no-cache-dir -r "$ROOT_DIR/requirements.txt"
fi

# -----------------------------------------------------------
# 编译加载器（需在精简前进行，依赖 libpython3.13.a 与头文件）
if [ "$SKIP_LOADER" != 1 ]; then
	log "编译加载器 ($LOADER_REF)"
	LOADER_DIR="$BUILD_DIR/loader"
	rm -rf "$LOADER_DIR"
	git clone --depth 1 --branch "$LOADER_REF" "$LOADER_REPO" "$LOADER_DIR"

	cmake -S "$LOADER_DIR/linux_macos" -B "$LOADER_DIR/build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DPython3_ROOT_DIR="$PYTHON_PREFIX" \
		-DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX"
	cmake --build "$LOADER_DIR/build" -j"$JOBS"
fi

# -----------------------------------------------------------
# 组装运行时
log "组装运行时：$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/runtime/lib"

cp -R "$PYTHON_PREFIX/lib/python$PY_MAJOR_MINOR" "$OUTPUT_DIR/runtime/lib/"
cp "$ROOT_DIR/_pystand_static.int" "$OUTPUT_DIR/"

if [ "$SKIP_LOADER" != 1 ]; then
	cp "$LOADER_DIR/build/loader" "$OUTPUT_DIR/bili23-downloader"

	case "$OS" in
		linux) strip "$OUTPUT_DIR/bili23-downloader" ;;
		macos) strip -x "$OUTPUT_DIR/bili23-downloader" ;;
	esac
fi

if [ -n "$FFMPEG" ]; then
	mkdir -p "$OUTPUT_DIR/bundle"
	cp "$FFMPEG" "$OUTPUT_DIR/bundle/ffmpeg"
	chmod +x "$OUTPUT_DIR/bundle/ffmpeg"
fi

# -----------------------------------------------------------
# 精简运行时
log "精简运行时"
"$PYTHON_BIN" "$ROOT_DIR/scripts/trim_runtime.py" "$OUTPUT_DIR/runtime"

# -----------------------------------------------------------
# 打包
log "打包"
ARCHIVE="$DIST_DIR/${PLATFORM}_runtime.zip"
rm -f "$ARCHIVE"
(
	# 文件直接位于压缩包根目录，与 Release 中的 zip 保持一致
	# -y 保留符号链接（macOS 下 Qt framework 依赖符号链接）
	cd "$OUTPUT_DIR"
	zip -qry "$ARCHIVE" .
)

log "完成：$ARCHIVE"
