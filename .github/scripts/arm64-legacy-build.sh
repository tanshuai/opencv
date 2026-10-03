#!/usr/bin/env bash
set -euo pipefail
# Preserve the original ARM64 Python 2.7/3.6 sysroot; host runner and checkout use supported runtimes.
sed -i -E 's|^deb ([^ ]+) (.*)$|deb [arch=amd64] \1 \2\ndeb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ \2|' /etc/apt/sources.list
dpkg --add-architecture arm64
apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 update
DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 install -y --no-install-recommends \
  crossbuild-essential-arm64 git cmake libpython-dev:arm64 libpython3-dev:arm64 python-numpy python3-numpy
# A rolling opencv_contrib HEAD is incompatible with this reviewed OpenCV 4.5.3-dev source.
git init /opencv_contrib
git -C /opencv_contrib fetch --depth 1 https://github.com/opencv/opencv_contrib.git d5317d6297a8129b66dba1a1f7cc784e94639da9
git -C /opencv_contrib checkout --detach FETCH_HEAD
test "$(git -C /opencv_contrib rev-parse HEAD)" = d5317d6297a8129b66dba1a1f7cc784e94639da9
mkdir -p build
cd build
cmake -DPYTHON2_INCLUDE_PATH=/usr/include/python2.7/ \
  -DPYTHON2_LIBRARIES=/usr/lib/aarch64-linux-gnu/libpython2.7.so \
  -DPYTHON2_NUMPY_INCLUDE_DIRS=/usr/lib/python2.7/dist-packages/numpy/core/include \
  -DPYTHON3_INCLUDE_PATH=/usr/include/python3.6m/ \
  -DPYTHON3_LIBRARIES=/usr/lib/aarch64-linux-gnu/libpython3.6m.so \
  -DPYTHON3_NUMPY_INCLUDE_DIRS=/usr/lib/python3/dist-packages/numpy/core/include \
  -DCMAKE_TOOLCHAIN_FILE=../platforms/linux/aarch64-gnu.toolchain.cmake \
  -DOPENCV_EXTRA_MODULES_PATH=/opencv_contrib/modules ../
make -j2
# A green build must contain a real ARM64 core library, not merely exit without expected output.
core_library=$(find lib -maxdepth 1 -type f -name 'libopencv_core.so.*' -print -quit)
test -n "$core_library"
aarch64-linux-gnu-readelf -h "$core_library" | grep -q 'Machine:.*AArch64'
