# 设置 macOS 最低兼容版本
export MACOSX_DEPLOYMENT_TARGET=12.0

# -----------------------------------------------------------
# 编译 libffi
curl -LO https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
tar -xzf libffi-3.4.6.tar.gz
cd libffi-3.4.6

# 配置为只生成静态库
./configure --disable-shared --enable-static --with-pic --prefix=/usr/local/opt/libffi-static
make -j$(sysctl -n hw.ncpu)
sudo make install

cd ..

# -----------------------------------------------------------
# 编译 openssl
curl -LO https://www.openssl.org/source/openssl-3.3.0.tar.gz
tar -xzf openssl-3.3.0.tar.gz
cd openssl-3.3.0

# 编译为仅静态库（no-shared）
./config darwin64-x86_64-cc no-shared --prefix=/usr/local/opt/openssl-static --openssldir=/usr/local/opt/openssl-static/ssl --libdir=lib
make -j$(sysctl -n hw.ncpu)
sudo make install

cd ..

# -----------------------------------------------------------
# 编译 Python 3.12.10
curl -LO https://www.python.org/ftp/python/3.12.10/Python-3.12.10.tgz
tar -xzf Python-3.12.10.tgz
cd Python-3.12.10

# 关键
echo "*static*" > Modules/Setup.local
echo "_ssl _ssl.c \$(OPENSSL_INCLUDES) \$(OPENSSL_LDFLAGS) -lssl -lcrypto -ldl -lpthread" >> Modules/Setup.local
echo "_hashlib _hashopenssl.c \$(OPENSSL_INCLUDES) \$(OPENSSL_LDFLAGS) -lcrypto -ldl -lpthread" >> Modules/Setup.local

# 配置并静态编译 Python
export LDFLAGS="-L/usr/local/opt/openssl-static/lib -L/usr/local/opt/libffi-static/lib"
export CPPFLAGS="-I/usr/local/opt/openssl-static/include -I/usr/local/opt/libffi-static/include"
export PKG_CONFIG_PATH="/usr/local/opt/openssl-static/lib/pkgconfig:/usr/local/opt/libffi-static/lib/pkgconfig"
export PKG_CONFIG="pkg-config --static"

./configure \
	--prefix=/usr/local/opt/python-static \
	--disable-shared \
	--enable-optimizations \
	--with-openssl=/usr/local/opt/openssl-static \
	--without-ensurepip

# 编译并安装
make -j$(sysctl -n hw.ncpu)
sudo make altinstall

cd ..

# -----------------------------------------------------------
# 精简不必要文件
cd /usr/local/opt/python-static
sudo rm -rf include lib/pkgconfig share

# 删除标准库中不需要的大体积无用模块（如 GUI、测试等）
sudo rm -rf lib/python3.12/idlelib
sudo rm -rf lib/python3.12/tkinter
sudo rm -rf lib/python3.12/test
sudo rm -rf lib/python3.12/turtledemo
sudo rm -rf lib/python3.12/pydoc_data
sudo rm -rf lib/python3.12/ensurepip
sudo rm -rf lib/python3.12/lib2to3
sudo rm -rf lib/python3.12/unittest
sudo rm -rf lib/python3.12/venv
sudo rm -rf lib/python3.12/config-3.12-*

# 删除生成的字节码缓存（在压缩打包前清理）
sudo find lib/python3.12 -name "__pycache__" -type d -exec rm -rf {} +
sudo find lib/python3.12 -name "*.pyc" -delete

# 对可执行文件进行 strip
sudo strip -x bin/python3.12 || true

# 创建运行时目录
mkdir -p /usr/local/opt/runtime/lib-dynload

# 复制可执行文件到运行时目录
cp bin/python3.12 /usr/local/opt/runtime/

# 将标准库打包成 zip 文件
cd lib/python3.12
cp lib-dynload -r /usr/local/opt/runtime/
rm -rf lib-dynload

zip -r ../python312.zip .

cd ..

cp python312.zip /usr/local/opt/runtime/

# 创建 python3.12._pth 文件，指向 zip 包 (文件名受可执行文件名决定)
echo "python312.zip" > /usr/local/opt/runtime/python3.12._pth
echo "lib-dynload" >> /usr/local/opt/runtime/python3.12._pth
echo "site-packages" >> /usr/local/opt/runtime/python3.12._pth
echo "import site" >> /usr/local/opt/runtime/python3.12._pth
echo "." >> /usr/local/opt/runtime/python3.12._pth
