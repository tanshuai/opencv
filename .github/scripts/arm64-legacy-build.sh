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
# Cheap provenance preflight occurs before configure/compile.
mkdir -p /work/build/arm64-results
source_sha=$(git -c safe.directory=/work -C /work rev-parse HEAD)
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
contrib_sha=$(git -C /opencv_contrib rev-parse HEAD)
[[ "$contrib_sha" == d5317d6297a8129b66dba1a1f7cc784e94639da9 ]]
printf '%s\n%s\n' "$source_sha" "$contrib_sha" > /work/build/arm64-results/SOURCE-COMMITS.txt
printf '%s\n' 'ubuntu@sha256:dca176c9663a7ba4c1f0e710986f5a25e672842963d95b960191e2d9f7185ebe; original Python2.7/Python3.6 sysroot; no generated code executed' > /work/build/arm64-results/BUILD-CONTRACT.txt
collector=/work/.github/scripts/arm64-artifact-manifest.py
collect_outputs() {
  python3 "$collector" collect --libdir /work/build/lib --output /work/build/arm64-results \
    --sysroot /usr/lib/aarch64-linux-gnu --sysroot /lib/aarch64-linux-gnu --sysroot /usr/aarch64-linux-gnu/lib
}
finish() {
  original_status=$?
  trap - EXIT
  # Diagnostic preservation does not change the original real compiler/validation exit code.
  collect_outputs || true
  exit "$original_status"
}
trap finish EXIT
cd /work/build
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
# Always preserve raw OpenCV/Python/system library bytes before strict output validation.
collect_outputs
python3 "$collector" verify --output /work/build/arm64-results
mkdir -p /work/build/arm64-results/licenses
find /usr/share/doc -maxdepth 2 -name copyright -type f -exec cp --parents '{}' /work/build/arm64-results/licenses/ \;
