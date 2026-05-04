#!/usr/bin/env bash
# Build a Lambda deployment zip targeting Python 3.12 on arm64.
#
# Wheels are pinned to manylinux2014_aarch64 + cp312 so we don't accidentally
# ship an x86_64 binary or pull a sdist that compiles for the host. This is
# the wheel-platform footgun referenced in CLAUDE.md and the prompt's
# "hard lessons I've already paid for."
#
# Outputs:
#   app/build/lambda_package/   (staging dir, deps + source)
#   app/build/lambda.zip        (Lambda upload artifact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$APP_DIR/build"
PKG_DIR="$BUILD_DIR/lambda_package"
ZIP_OUT="$BUILD_DIR/lambda.zip"

LAMBDA_PY_VERSION="${LAMBDA_PY_VERSION:-3.12}"
LAMBDA_PLATFORM="${LAMBDA_PLATFORM:-manylinux2014_aarch64}"
PYTHON="${PYTHON_BIN:-$APP_DIR/.venv/bin/python}"

if [ ! -x "$PYTHON" ]; then
  echo "ERROR: $PYTHON not found." >&2
  echo "       Run: uv venv --python $LAMBDA_PY_VERSION $APP_DIR/.venv && uv pip install -e $APP_DIR[dev]" >&2
  exit 1
fi

ACTUAL_PY=$("$PYTHON" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
if [ "$ACTUAL_PY" != "$LAMBDA_PY_VERSION" ]; then
  echo "ERROR: $PYTHON is Python $ACTUAL_PY but Lambda runtime is $LAMBDA_PY_VERSION." >&2
  echo "       Build host's interpreter and Lambda runtime should match." >&2
  exit 1
fi

echo "==> cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

echo "==> resolving runtime deps from pyproject.toml"
DEPS=$("$PYTHON" -c "
import tomllib, pathlib
data = tomllib.loads(pathlib.Path('$APP_DIR/pyproject.toml').read_text())
print('\n'.join(data['project']['dependencies']))
")

if [ -z "$DEPS" ]; then
  echo "ERROR: no [project].dependencies found in $APP_DIR/pyproject.toml" >&2
  exit 1
fi

echo "==> installing wheels for $LAMBDA_PLATFORM cp${LAMBDA_PY_VERSION//./}"
echo "$DEPS" | tr '\n' '\0' | xargs -0 "$PYTHON" -m pip install \
  --target "$PKG_DIR" \
  --platform "$LAMBDA_PLATFORM" \
  --implementation cp \
  --python-version "$LAMBDA_PY_VERSION" \
  --only-binary=:all: \
  --upgrade \
  --quiet

echo "==> copying ngx_workload_lab source"
cp -R "$APP_DIR/src/ngx_workload_lab" "$PKG_DIR/ngx_workload_lab"

echo "==> stripping bytecode caches and bundled tests"
find "$PKG_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$PKG_DIR" -type d \( -name "tests" -o -name "test" \) -exec rm -rf {} + 2>/dev/null || true
find "$PKG_DIR" -type f -name "*.pyc" -delete

# Belt-and-suspenders: refuse to ship an x86_64 .so by accident.
if find "$PKG_DIR" -name "*.so" -print0 | xargs -0 file 2>/dev/null | grep -E 'x86[-_ ]64|i386' >/dev/null; then
  echo "ERROR: x86_64 binary detected in package — would crash on arm64 Lambda." >&2
  find "$PKG_DIR" -name "*.so" -print0 | xargs -0 file | grep -E 'x86[-_ ]64|i386' >&2 || true
  exit 1
fi

echo "==> zipping → $ZIP_OUT"
( cd "$PKG_DIR" && zip -qr9 "$ZIP_OUT" . )

echo
echo "==> done"
echo "    zip:  $(du -h "$ZIP_OUT" | cut -f1)  $ZIP_OUT"
echo "    dir:  $(du -sh "$PKG_DIR" | cut -f1)  $PKG_DIR"
