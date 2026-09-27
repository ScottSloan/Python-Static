"""精简 Linux / macOS 运行时目录（runtime/lib/python3.x）。

    python trim_runtime.py <runtime 目录>            # 执行精简
    python trim_runtime.py <runtime 目录> --dry-run  # 仅预演

依次处理：
  1. 删除标准库中用不到的包（GUI、测试、ensurepip 等）
  2. 删除 lib-dynload 中的测试模块
  3. 删除 pip、*.dist-info 等打包元数据
  4. 按白名单裁剪 PySide6，只保留程序用到的 Qt 模块
  5. macOS：删除未使用的 PyObjC 框架绑定
  6. 清理 __pycache__ / *.pyc
"""

import argparse
import re
import shutil
from pathlib import Path

# 标准库中不需要的包
STDLIB_REMOVE = {
    "idlelib",
    "tkinter",
    "test",
    "turtledemo",
    "pydoc_data",
    "ensurepip",
    "lib2to3",
    "unittest",
    "venv",
}

# lib-dynload 中的测试模块（构建时已 --disable-test-modules，此处兜底）
DYNLOAD_REMOVE = re.compile(r"^(_test|_ctypes_test|_xxtestfuzz|xxlimited|xxsubtype)")

# site-packages 中不需要的包
SITE_REMOVE = {"pip", "setuptools", "_distutils_hack", "bin"}

# 程序用到的 Qt 模块
QT_MODULES = {"Core", "DBus", "Gui", "Network", "Svg", "SvgWidgets", "Widgets", "Xml"}

# PySide6/ 顶层保留的非模块文件
PYSIDE6_KEEP = {"__init__.py", "_config.py", "_git_pyside_version.py", "py.typed", "Qt"}

# PySide6/Qt/ 下保留的目录
PYSIDE6_QT_KEEP = {"lib", "plugins"}

# Linux：PySide6/Qt/lib 中除 QT_MODULES 外额外保留的库（平台插件依赖）
LINUX_QT_LIB_EXTRA = {
    "WaylandClient",
    "WaylandCompositor",
    "WaylandEglClientHwIntegration",
    "WaylandEglCompositorHwIntegration",
    "XcbQpa",
}

PLUGINS_KEEP = {
    "linux": {
        "iconengines",
        "imageformats",
        "platforminputcontexts",
        "platforms",
        "platformthemes",
        "wayland-decoration-client",
        "wayland-graphics-integration-client",
        "wayland-graphics-integration-server",
        "wayland-shell-integration",
        "xcbglintegrations",
    },
    "darwin": {"iconengines", "imageformats", "platforms"},
}

# qframelesswindow / darkdetect 实际用到的 PyObjC 模块及其依赖
PYOBJC_KEEP = {
    "objc",
    "Cocoa",
    "AppKit",
    "Foundation",
    "CoreFoundation",
    "Quartz",
    "PyObjCTools",
    "ExceptionHandling",  # PyObjCTools.Debugging 依赖（AppHelper 调试路径）
}

# 没有 _metadata.py 但同样属于 PyObjC 的伞形包，以及无人引用的 pycocoa
PYOBJC_EXTRA_REMOVE = {
    "ApplicationServices",
    "CoreServices",
    "DictionaryServices",
    "LaunchServices",
    "SearchKit",
    "libdispatch",
    "pycocoa",
}

IMPORT_RE = re.compile(r"^\s*(?:from|import)\s+([A-Za-z_]\w*)", re.MULTILINE)


class Trimmer:
    def __init__(self, dry_run: bool):
        self.dry_run = dry_run
        self.freed = 0

    def remove(self, path: Path) -> None:
        if not path.exists() and not path.is_symlink():
            return

        if path.is_dir() and not path.is_symlink():
            self.freed += sum(f.stat().st_size for f in path.rglob("*") if f.is_file() and not f.is_symlink())
            if not self.dry_run:
                shutil.rmtree(path)
        else:
            if not path.is_symlink():
                self.freed += path.stat().st_size
            if not self.dry_run:
                path.unlink()


def find_stdlib(runtime: Path) -> Path:
    matches = list(runtime.glob("lib/python3.*"))
    if len(matches) != 1:
        raise SystemExit(f"[错误] {runtime} 下找到 {len(matches)} 个 lib/python3.* 目录")
    return matches[0]


def qt_module_name(name: str) -> str | None:
    """从 QtCore.abi3.so / libQt6Core.so.6 / QtCore.framework 中提取 Core。"""
    m = re.match(r"^(?:lib)?Qt6?([A-Za-z0-9]+?)(?:\.abi3|\.so|\.framework|\.dylib|$)", name)
    return m.group(1) if m else None


def trim_stdlib(t: Trimmer, stdlib: Path) -> None:
    for name in STDLIB_REMOVE:
        t.remove(stdlib / name)
    for path in stdlib.glob("config-3.*"):
        t.remove(path)

    for path in (stdlib / "lib-dynload").iterdir():
        if DYNLOAD_REMOVE.match(path.name):
            t.remove(path)


def trim_site_packages(t: Trimmer, site: Path) -> None:
    for path in site.iterdir():
        if path.name in SITE_REMOVE or path.suffix in (".dist-info", ".egg-info") or path.name.endswith("-nspkg.pth"):
            t.remove(path)


def detect_platform(stdlib: Path) -> str:
    """根据 _sysconfigdata 判断运行时所属平台，便于在其他系统上预演。"""
    return "darwin" if any(stdlib.glob("_sysconfigdata__darwin*")) else "linux"


def trim_pyside6(t: Trimmer, site: Path, platform: str) -> None:
    pyside = site / "PySide6"
    if not pyside.is_dir():
        return

    for path in pyside.iterdir():
        if path.name in PYSIDE6_KEEP or path.name.startswith("libpyside6"):
            continue
        if path.name.startswith("Qt") and path.suffix == ".so" and qt_module_name(path.name) in QT_MODULES:
            continue
        t.remove(path)

    qt = pyside / "Qt"
    for path in qt.iterdir():
        if path.name not in PYSIDE6_QT_KEEP:
            t.remove(path)

    keep_libs = QT_MODULES | (LINUX_QT_LIB_EXTRA if platform == "linux" else set())
    for path in (qt / "lib").iterdir():
        if path.name.startswith("libicu"):
            continue
        if qt_module_name(path.name) not in keep_libs:
            t.remove(path)

    for path in (qt / "plugins").iterdir():
        if path.name not in PLUGINS_KEEP[platform]:
            t.remove(path)


def find_dangling_imports(site: Path, removed: set[str]) -> list[str]:
    """静态扫描保留下来的代码，看是否还有对被删模块的 import。"""
    problems = []
    for d in site.iterdir():
        if d.name in removed:
            continue
        files = d.rglob("*.py") if d.is_dir() else [d] if d.suffix == ".py" else []
        for f in files:
            try:
                text = f.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for name in set(IMPORT_RE.findall(text)) & removed:
                problems.append(f"{f.relative_to(site)} -> {name}")
    return problems


def trim_pyobjc(t: Trimmer, site: Path) -> None:
    if not (site / "objc").is_dir():
        return

    missing = sorted(k for k in PYOBJC_KEEP if not (site / k).is_dir())
    if missing:
        raise SystemExit(f"[错误] 缺少必需的 PyObjC 模块: {', '.join(missing)}")

    targets = sorted(
        d
        for d in site.iterdir()
        if d.is_dir() and d.name not in PYOBJC_KEEP and ((d / "_metadata.py").is_file() or d.name in PYOBJC_EXTRA_REMOVE)
    )

    dangling = find_dangling_imports(site, {d.name for d in targets})
    if dangling:
        print("[错误] 仍有代码引用待删除的 PyObjC 模块，已中止：")
        for line in dangling:
            print(f"    {line}")
        raise SystemExit(1)

    for d in targets:
        t.remove(d)


def trim_bytecode(t: Trimmer, root: Path) -> None:
    for path in list(root.rglob("__pycache__")):
        t.remove(path)
    for path in list(root.rglob("*.pyc")):
        t.remove(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("runtime", type=Path, help="runtime 目录（包含 lib/python3.x）")
    parser.add_argument("--dry-run", action="store_true", help="仅预演，不删除文件")
    args = parser.parse_args()

    stdlib = find_stdlib(args.runtime)
    site = stdlib / "site-packages"
    t = Trimmer(args.dry_run)

    steps = [
        ("标准库", lambda: trim_stdlib(t, stdlib)),
        ("打包元数据", lambda: trim_site_packages(t, site)),
        ("PySide6", lambda: trim_pyside6(t, site, detect_platform(stdlib))),
        ("PyObjC", lambda: trim_pyobjc(t, site)),
        ("字节码缓存", lambda: trim_bytecode(t, args.runtime)),
    ]

    for name, step in steps:
        before = t.freed
        step()
        print(f"  {name}: {(t.freed - before) / 1024 / 1024:.1f} MB")

    action = "预计释放" if args.dry_run else "已释放"
    print(f"{action}合计 {t.freed / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
