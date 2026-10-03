#!/usr/bin/env bash
set -euo pipefail
# Preserve the original ARM64 Python 2.7/3.6 sysroot; host runner and checkout use supported runtimes.
sed -i -E 's|^deb ([^ ]+) (.*)$|deb [arch=amd64] \1 \2\ndeb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ \2|' /etc/apt/sources.list
dpkg --add-architecture arm64
apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 update
DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 install -y --no-install-recommends \
  crossbuild-essential-arm64 git ca-certificates cmake libpython-dev:arm64 libpython3-dev:arm64 python-numpy python3-numpy
# A rolling opencv_contrib HEAD is incompatible with this reviewed OpenCV 4.5.3-dev source.
git init /opencv_contrib
for attempt in 1 2; do
  if timeout 90 git -C /opencv_contrib fetch --depth 1 https://github.com/opencv/opencv_contrib.git d5317d6297a8129b66dba1a1f7cc784e94639da9; then break; fi
  [[ "$attempt" == 1 ]] || exit 1
  sleep 2
done
git -C /opencv_contrib checkout --detach FETCH_HEAD
test "$(git -C /opencv_contrib rev-parse HEAD)" = d5317d6297a8129b66dba1a1f7cc784e94639da9
mkdir -p build
cd build
cmake -DBUILD_opencv_python2=ON -DBUILD_opencv_python3=ON \
  -DPYTHON2_EXECUTABLE=/usr/bin/python2.7 -DPYTHON3_EXECUTABLE=/usr/bin/python3.6 \
  -DPYTHON2_INCLUDE_PATH=/usr/include/python2.7/ \
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
aarch64-linux-gnu-readelf -h "$core_library" | grep 'Machine:.*AArch64' > /dev/null
# Preserve readable original artifacts and architectural evidence; never execute the generated libraries.
mkdir -p arm64-results/core arm64-results/python2 arm64-results/python3
cp "$core_library" arm64-results/core/
for python in 2 3; do
  if [[ "$python" == 2 ]]; then symbol=initcv2; else symbol=PyInit_cv2; fi
  binding=''
  while IFS= read -r candidate; do
    if aarch64-linux-gnu-readelf --wide --symbols "$candidate" | awk -v symbol="$symbol" '$NF == symbol {found=1} END {exit !found}'; then
      binding="$candidate"
      break
    fi
  done < <(find lib -type f -name 'cv2*.so')
  test -n "$binding"
  aarch64-linux-gnu-readelf -h "$binding" | grep 'Machine:.*AArch64' > /dev/null
  cp "$binding" "arm64-results/python${python}/"
done
for library in arm64-results/{core,python2,python3}/*.so*; do
  aarch64-linux-gnu-readelf -h "$library"
  aarch64-linux-gnu-readelf --wide --symbols "$library" | grep -E 'initcv2|PyInit_cv2' || [[ "$library" == *'/core/'* ]]
done > arm64-results/ELF-AND-ABI.txt
sha256sum arm64-results/{core,python2,python3}/*.so* > arm64-results/SHA256SUMS
{ git -C /work rev-parse HEAD; git -C /opencv_contrib rev-parse HEAD; } > arm64-results/SOURCE-COMMITS.txt
printf '%s\n' 'Container: ubuntu@sha256:dca176c9663a7ba4c1f0e710986f5a25e672842963d95b960191e2d9f7185ebe' > arm64-results/BUILD-CONTRACT.txt
printf '%s\n' 'AArch64 core; Python2.7 initcv2; Python3.6 PyInit_cv2; binary consumers not executed.' >> arm64-results/BUILD-CONTRACT.txt
# Preserve OpenCV's linked library closure under each actual SONAME, without three duplicate aliases.
mkdir -p arm64-results/libraries
while IFS= read -r library; do
  soname=$(aarch64-linux-gnu-readelf --dynamic "$library" | sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/\1/p')
  test -n "$soname"
  cp "$library" "arm64-results/libraries/$soname"
done < <(find lib -maxdepth 1 -type f -name 'libopencv_*.so.*')
for library in arm64-results/{libraries,python2,python3}/*.so*; do
  aarch64-linux-gnu-readelf --dynamic "$library"
done > arm64-results/DEPENDENCIES.txt
sha256sum arm64-results/{core,libraries,python2,python3}/*.so* > arm64-results/SHA256SUMS
