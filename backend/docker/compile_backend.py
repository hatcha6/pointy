"""Compile the backend to native extensions for the release image.

Runs inside the Docker build (see ``backend/Dockerfile``). Every module under
``apps/`` and ``pointy/`` becomes a stripped ``.so`` and its ``.py`` is deleted,
so the shipped image carries no readable source. Set ``POINTY_COMPILE=0`` to skip
the whole thing and ship plain Python — the escape hatch for the day a Cython
regression lands the week of a release.

Four things here are load-bearing; each was found the hard way (see
CYTHON_FEASIBILITY.md):

* ``annotation_typing=False`` — Cython otherwise reads PEP 484 annotations as C
  type declarations, which turns ``Decimal`` money into binary floats and makes
  ``name: str`` reject ``None``. Silent, and in the money path.
* Migrations are NOT compiled — a module name may not start with a digit and
  every Django migration does. They become sourceless ``.pyc`` instead.
* ``__init__.py`` is NOT compiled — ``unittest`` treats a directory as a package
  only when a literal ``__init__.py`` is on disk, so compiling them makes the
  suite discover zero tests *and exit 0*.
* No ``-march``. Baking the build runner's CPU features into the binary would
  crash older shop hardware with SIGILL while passing every test in CI.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import sysconfig
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CYTHON_VERSION = "3.2.4"

# Kept as readable source in the shipped image, deliberately:
#   __init__.py  - unittest discovery needs it on disk (see module docstring)
#   manage.py    - operational entrypoint, wanted readable for support
#   docker/*.py  - entrypoint/healthcheck, referenced by absolute path
SKIP_DIR_PARTS = {"__pycache__", "docker", ".venv", "node_modules", "migrations_backup"}


def is_test(path: Path) -> bool:
    """Test modules, precisely.

    NOT ``startswith("test")``: that also matches ``apps/catalog/testing.py``, a
    shared test *helper* that is ordinary source. Skipping it left one readable
    module in the shipped image — and because the leftover guard below used this
    same predicate, the guard could not see its own blind spot.
    """
    return (
        path.name == "tests.py"
        or path.name.startswith("test_")
        or "tests" in path.parts
    )


def enabled() -> bool:
    return os.environ.get("POINTY_COMPILE", "1").strip().lower() not in {"0", "false", "no", "off"}


def collect() -> tuple[list[str], list[str]]:
    """Return (modules to cythonize, migration files to byte-compile)."""
    modules: list[str] = []
    migrations: list[str] = []
    for base in ("apps", "pointy"):
        for path in sorted((ROOT / base).rglob("*.py")):
            rel = path.relative_to(ROOT)
            if any(part in SKIP_DIR_PARTS for part in rel.parts):
                continue
            if is_test(rel):
                continue
            if rel.name == "__init__.py":
                continue
            if rel.name[0].isdigit():
                migrations.append(str(rel))
                continue
            modules.append(str(rel))
    return modules, migrations


def assert_no_march() -> None:
    cflags = " ".join(
        filter(None, (sysconfig.get_config_var("CFLAGS"), os.environ.get("CFLAGS", "")))
    )
    if "-march" in cflags or "-mtune" in cflags:
        sys.exit(
            f"REFUSING TO BUILD: CFLAGS pins the CPU ({cflags!r}).\n"
            "A -march/-mtune build crashes older shop hardware with SIGILL while\n"
            "passing every test on the newer CI runner. Remove it."
        )


def cythonize_all(modules: list[str], jobs: int) -> None:
    from Cython.Build import cythonize
    from Cython.Compiler import Options as CyOptions
    from setuptools import setup

    # Strip prose from the binary. GLOBAL options, not compiler directives —
    # passing them as directives raises "unknown compiler directive".
    CyOptions.docstrings = False
    if hasattr(CyOptions, "emit_code_comments"):
        CyOptions.emit_code_comments = False

    ext_modules = cythonize(
        modules,
        nthreads=jobs,
        quiet=True,
        compiler_directives={
            "language_level": "3",
            "annotation_typing": False,
        },
    )
    setup(
        name="pointy-compiled",
        script_args=["build_ext", "--inplace", "-j", str(jobs)],
        ext_modules=ext_modules,
    )


def main() -> None:
    if not enabled():
        print("==> POINTY_COMPILE=0 — shipping plain Python source (escape hatch).", flush=True)
        return

    import Cython

    if Cython.__version__ != CYTHON_VERSION:
        sys.exit(
            f"REFUSING TO BUILD: Cython {Cython.__version__} != pinned {CYTHON_VERSION}.\n"
            "3.3.0 crashes its own code generator on filter(**{f'{field}__gte': x}),\n"
            "the Django dynamic-filter idiom. Pin deliberately, then re-test."
        )
    assert_no_march()

    os.chdir(ROOT)
    modules, migrations = collect()
    jobs = max(1, os.cpu_count() or 1)
    print(
        f"==> compiling {len(modules)} modules (-j{jobs}); "
        f"{len(migrations)} migrations -> bytecode",
        flush=True,
    )

    started = time.time()
    cythonize_all(modules, jobs)

    # Every module must have produced an extension; a silent miss would leave a
    # readable .py in the image (or a missing module at runtime).
    missing = [m for m in modules if not list(Path(m).parent.glob(Path(m).stem + ".cpython-*.so"))]
    if missing:
        sys.exit(f"REFUSING TO BUILD: no .so produced for {len(missing)} modules: {missing[:5]}")

    for module in modules:
        Path(module).unlink()
        c_file = Path(module).with_suffix(".c")
        if c_file.exists():
            c_file.unlink()  # the .c is MORE readable than the .so

    # Migrations: sourceless bytecode in the legacy location (next to where the
    # source was), which importlib and Django's MigrationLoader both resolve.
    if migrations:
        subprocess.check_call([sys.executable, "-m", "compileall", "-q", "-b", *migrations])
        for migration in migrations:
            Path(migration).unlink()

    shutil.rmtree(ROOT / "build", ignore_errors=True)  # .o objects + duplicate .so

    # Symbol tables make reversing materially easier and are ~5x the payload.
    subprocess.check_call(
        "find . -name '*.so' -print0 | xargs -0 -r strip -s", shell=True, cwd=ROOT
    )

    leftover = [
        str(p.relative_to(ROOT))
        for p in ROOT.rglob("*.py")
        if not is_test(p.relative_to(ROOT))
        and "docker" not in p.relative_to(ROOT).parts
        and p.name not in {"__init__.py", "manage.py"}
    ]
    if leftover:
        sys.exit(f"REFUSING TO BUILD: readable source survived: {leftover[:10]}")

    so_bytes = sum(p.stat().st_size for p in ROOT.rglob("*.so"))
    print(
        f"==> compiled in {time.time() - started:.0f}s; "
        f"{so_bytes / 1024 / 1024:.0f} MB of stripped extensions, 0 modules of source",
        flush=True,
    )


if __name__ == "__main__":
    main()
