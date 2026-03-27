# -----------------------------------------------------------
# 编译 libffi
wget https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
tar -xzf libffi-3.4.6.tar.gz
cd libffi-3.4.6

# 配置为只生成静态库
./configure --disable-shared --enable-static --with-pic --prefix=/opt/libffi-static
make -j$(nproc)
sudo make install

cd ..

# -----------------------------------------------------------
# 编译 openssl
wget https://www.openssl.org/source/openssl-3.3.0.tar.gz
tar -xzf openssl-3.3.0.tar.gz
cd openssl-3.3.0

# 编译为仅静态库（no-shared）
./config no-shared --prefix=/opt/openssl-static --openssldir=/opt/openssl-static/ssl --libdir=lib
make -j$(nproc)
sudo make install

cd ..

# -----------------------------------------------------------
# 编译 Python 3.12.10
wget https://www.python.org/ftp/python/3.12.10/Python-3.12.10.tgz
tar -xzf Python-3.12.10.tgz
cd Python-3.12.10

# 关键
echo "*static*" > Modules/Setup.local
echo "_ssl _ssl.c \$(OPENSSL_INCLUDES) \$(OPENSSL_LDFLAGS) -lssl -lcrypto -ldl -lpthread" >> Modules/Setup.local
echo "_hashlib _hashopenssl.c \$(OPENSSL_INCLUDES) \$(OPENSSL_LDFLAGS) -lcrypto -ldl -lpthread" >> Modules/Setup.local

# 配置并静态编译 Python
export LDFLAGS="-L/opt/openssl-static/lib -L/opt/libffi-static/lib"
export CPPFLAGS="-I/opt/openssl-static/include -I/opt/libffi-static/include"
export PKG_CONFIG_PATH="/opt/openssl-static/lib/pkgconfig:/opt/libffi-static/lib/pkgconfig"
export PKG_CONFIG="pkg-config --static"

./configure \
	--prefix=/opt/python-static \
	--disable-shared \
	--enable-optimizations \
	--with-openssl=/opt/openssl-static \
	--without-ensurepip

# 编译并安装
make -j$(nproc)
sudo make altinstall

cd ..

# -----------------------------------------------------------
# 精简不必要文件
cd /opt/python-static
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
sudo rm -rf lib/python3.12/config-3.12-x86_64-linux-gnu

# 删除生成的字节码缓存（在压缩打包前清理）
sudo find lib/python3.12 -name "__pycache__" -type d -exec rm -rf {} +
sudo find lib/python3.12 -name "*.pyc" -delete

# 对可执行文件进行 strip
sudo strip bin/python3.12 || true

# 创建运行时目录
mkdir -p /opt/runtime/lib-dynload

# 复制可执行文件到运行时目录
cp bin/python3.12 /opt/runtime/

# 将标准库打包成 zip 文件
cd lib/python3.12
cp lib-dynload -r /opt/runtime/
rm -rf lib-dynload

zip -r ../python312.zip .

cd ..

cp python312.zip /opt/runtime/

# 创建 python3.12._pth 文件，指向 zip 包 (文件名受可执行文件名决定)
echo "python312.zip" > /opt/runtime/python3.12._pth
echo "lib-dynload" >> /opt/runtime/python3.12._pth
echo "site-packages" >> /opt/runtime/python3.12._pth
echo "import site" >> /opt/runtime/python3.12._pth

