# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG parent_image

# Using multi-stage build to copy latest Python 3.
FROM gcr.io/fuzzbench/base-image AS base-image

FROM ubuntu:xenial AS libunwind-builder

RUN apt-get update && \
    apt-get install -y \
        git \
        build-essential \
        autoconf \
        libtool

# Build libunwind from `master`.
# Commit debb6128d17b782552d53efa8869a392d1f40a83 required.
RUN git clone https://github.com/libunwind/libunwind.git /libunwind && \
    cd /libunwind && \
    git checkout v1.6.2 && \
    autoreconf --install && \
    ./configure --enable-static --enable-shared --enable-setjmp=no && \
    make -j && \
    make install DESTDIR=/tmp/libunwind_prefix && \
    mkdir /libunwind_build && \
    cd /libunwind_build && \
    tar --directory=/tmp/libunwind_prefix -cf libunwind.tar.gz usr && \
    rm -rf /libunwind /tmp/libunwind_prefix

FROM ubuntu:xenial AS llvm-builder-deps

# Avoid complaints from apt while installing packages
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        git

RUN mkdir -p /llvm-project && \
    cd /llvm-project && \
    git clone --depth 1 https://github.com/llvm/llvm-project.git \
        --branch release/11.x \
        source

RUN apt-get install -y \
        software-properties-common \
        apt-transport-https \
        wget

# Install CMake
RUN bash -c "$(wget -O - https://apt.kitware.com/kitware-archive.sh)" && \
    apt-get install -y cmake

# Copy latest python3 from base-image into local.
COPY --from=base-image /usr/local/bin/python3* /usr/local/bin/
COPY --from=base-image /usr/local/lib/python3.8 /usr/local/lib/python3.8
COPY --from=base-image /usr/local/include/python3.8 /usr/local/include/python3.8
COPY --from=base-image /usr/local/lib/python3.8/site-packages /usr/local/lib/python3.8/site-packages

ENV VIRTUAL_ENV=/venv
RUN python3.8 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Install deps always needed to build LLVM
RUN apt-get install -y \
        build-essential \
        ninja-build

# Apply patches for custom LLVM build
COPY 0001-Add-Custom-sanitizer.patch \
    /llvm-project/
COPY 0001-Ignore-STACKMAP-instruction-in-x87-stackifier.patch \
    /llvm-project/
COPY 0001-XRay-compiler-rt-x86_64-Fix-CFI-directives-in-assemb.patch \
    /llvm-project/
COPY 0001-DFSan-Fix-call-to-__dfsan_mem_transfer_callback.patch \
    /llvm-project/
RUN cd /llvm-project/source && \
    git apply ../*.patch

FROM llvm-builder-deps AS llvm-builder

RUN cd /llvm-project && \
    cmake -Ssource/llvm -Bbuild-assert \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS='clang;compiler-rt;lld' \
        -DLLVM_TARGETS_TO_BUILD='X86' \
        -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_ENABLE_ASSERTIONS=ON && \
    cmake --build build-assert && \
    cd build-assert && \
    cpack -G "STGZ" && \
    cd /llvm-project && \
    mv build-assert/LLVM-11.1.0-Linux.sh . && \
    rm -rf build-assert

FROM llvm-builder-deps AS fuzzer-builder

# Avoid complaints from apt while installing packages
ARG DEBIAN_FRONTEND=noninteractive

# - `libc++` is needed to rebuild `libc++` itself with instrumentation.
# - The `ssh-keyscan` trick is necessary to avoid complaints when using
#   `git clone` on private repos.
RUN apt-get update && \
    apt-get install -y \
        libc++-dev \
        libc++abi-dev \
        curl \
        lsb-release \
        ca-certificates \
        gnupg \
        apt-utils \
        zlib1g-dev \
        libgcrypt-dev \
        libmount-dev \
        pkg-config \
    && \
    mkdir -p ~/.ssh && \
    ssh-keyscan github.com >> ~/.ssh/known_hosts && \
    ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        > /tmp/rustup-init.sh && \
    sh /tmp/rustup-init.sh -y --default-toolchain nightly && \
    rm /tmp/rustup-init.sh

# Install Corrosion
RUN mkdir -p /corrosion && \
    cd /corrosion && \
    git clone https://github.com/AndrewGaspar/corrosion.git source && \
    cd source && git checkout v0.1.0 && cd .. && \
    cmake -Ssource -Bbuild \
        -DCMAKE_BUILD_TYPE=Release \
        -DCORROSION_BUILD_TESTS=OFF && \
    cmake --build build -- -j && \
    cd build && \
    make install && \
    rm -rf /corrosion

# Generate the DFSan ABI lists for external libraries
RUN mkdir /extra_abilists && \
    nm --dynamic /usr/lib/x86_64-linux-gnu/libz.so \
        | awk '{ if ($2 == "T") print "fun:" $3 "=uninstrumented" }' \
        > /extra_abilists/libz_abilist.txt && \
    nm --dynamic /usr/lib/x86_64-linux-gnu/libgcrypt.so \
        | awk '{ if ($2 == "T") print "fun:" $3 "=uninstrumented" }' \
        > /extra_abilists/libgcrypt_abilist.txt && \
    nm --dynamic /usr/lib/x86_64-linux-gnu/libmount.so \
        | awk '{ if ($2 == "T") print "fun:" $3 "=uninstrumented" }' \
        > /extra_abilists/libmount_abilist.txt

COPY --from=libunwind-builder /libunwind_build/libunwind.tar.gz /tmp/
RUN cd / && \
    tar xf /tmp/libunwind.tar.gz && \
    ldconfig

COPY --from=llvm-builder /llvm-project/LLVM-11.1.0-Linux.sh /llvm-project
RUN /llvm-project/LLVM-11.1.0-Linux.sh --skip-license --prefix=/usr/local

# Build fuzzer
RUN mkdir -p /snapshot_fuzzer && \
    cd /snapshot_fuzzer && \
    git clone \
        --branch main \
        --recursive \
        https://github.com/vusec/snappy.git \
        source && \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    cmake -Ssource -Bbuild \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ && \
    cmake --build build -- -j && \
    cd build && \
    make install && \
    cpack -G "STGZ" && \
    cd /snapshot_fuzzer && \
    mv build/AngoraSnapshot-0.0.1-Linux.sh . && \
    rm -rf build

# Build plain libcxx
RUN cd /llvm-project && \
    cmake -Ssource/llvm -Bbuild-plain \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/plain-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-plain -- cxx cxxabi && \
    cd build-plain && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-plain

RUN cd /llvm-project && \
    angora-clang -c \
        source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o StandaloneFuzzTargetMainAngoraFast.o && \
    ar rc libStandaloneFuzzTargetAngoraFast.a \
        StandaloneFuzzTargetMainAngoraFast.o && \
    rm StandaloneFuzzTargetMainAngoraFast.o

# Build Angora track libcxx
RUN cd /llvm-project && \
    INSTR_FLAGS="$(FLAGS_MODE=1 USE_DFSAN=1 angora-clang++ --compiler)"; \
    cmake -Ssource/llvm -Bbuild-track \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/track-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLLVM_USE_SANITIZER='Custom' \
        -DLLVM_CUSTOM_SANITIZER_FLAGS="$INSTR_FLAGS" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-track -- cxx cxxabi && \
    cd build-track && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-track

RUN cd /llvm-project && \
    USE_TRACK=1 angora-clang -c \
        source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o StandaloneFuzzTargetMainAngoraTrack.o && \
    ar rc libStandaloneFuzzTargetAngoraTrack.a \
        StandaloneFuzzTargetMainAngoraTrack.o && \
    rm StandaloneFuzzTargetMainAngoraTrack.o

# Build SnapshotPlacement libcxx
RUN cd /llvm-project && \
    INSTR_CXX_FLAGS="$(clang_snapshot_placement --flags --compiler \
                       | sed 's/-fsanitize=dataflow//')"; \
    cmake -Ssource/llvm -Bbuild-snapshot-placement \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/snapshot-placement-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLLVM_USE_SANITIZER='DataFlow' \
        -DCMAKE_CXX_FLAGS="$INSTR_CXX_FLAGS" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-snapshot-placement -- cxx cxxabi && \
    cd build-snapshot-placement && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-snapshot-placement

RUN cd /llvm-project && \
    clang_snapshot_placement -c \
        source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o StandaloneFuzzTargetMainSnapshotPlacement.o && \
    ar rc libStandaloneFuzzTargetSnapshotPlacement.a \
        StandaloneFuzzTargetMainSnapshotPlacement.o && \
    rm StandaloneFuzzTargetMainSnapshotPlacement.o

# Build DFSanSnapshot libcxx
RUN cd /llvm-project && \
    INSTR_CXX_FLAGS="$(clang_dfsan_snapshot --flags --compiler \
                       | sed 's/-fsanitize=dataflow//')"; \
    cmake -Ssource/llvm -Bbuild-dfsan-snapshot \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/dfsan-snapshot-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLLVM_USE_SANITIZER='DataFlow' \
        -DCMAKE_CXX_FLAGS="$INSTR_CXX_FLAGS" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-dfsan-snapshot -- cxx cxxabi && \
    cd build-dfsan-snapshot && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-dfsan-snapshot

RUN cd /llvm-project && \
    clang_dfsan_snapshot -c \
        source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o StandaloneFuzzTargetMainDFSanSnapshot.o && \
    ar rc libStandaloneFuzzTargetDFSanSnapshot.a \
        StandaloneFuzzTargetMainDFSanSnapshot.o && \
    rm StandaloneFuzzTargetMainDFSanSnapshot.o

# Build XRaySnapshot libcxx
RUN cd /llvm-project && \
    INSTR_CXX_FLAGS="$(clang_xray_snapshot --flags --compiler --no-runtime)"; \
    cmake -Ssource/llvm -Bbuild-xray-snapshot \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/xray-snapshot-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DCMAKE_CXX_FLAGS="$INSTR_CXX_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS='-lpthread -ldl' \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-xray-snapshot -- cxx cxxabi && \
    cd build-xray-snapshot && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-xray-snapshot

RUN cd /llvm-project && \
    clang_xray_snapshot -c \
        source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o StandaloneFuzzTargetMainXRaySnapshot.o && \
    ar rc libStandaloneFuzzTargetXRaySnapshot.a \
        StandaloneFuzzTargetMainXRaySnapshot.o && \
    rm StandaloneFuzzTargetMainXRaySnapshot.o

FROM $parent_image AS benchmark-with-fuzzer

RUN apt-get update && \
    apt-get install -y \
        pkg-config

COPY --from=llvm-builder /llvm-project/LLVM-11.1.0-Linux.sh /tmp/
RUN /tmp/LLVM-11.1.0-Linux.sh --skip-license --prefix=/usr/local && \
    mkdir -p $OUT/fuzzer_prefix/bin && \
    cp /usr/local/bin/llvm-xray $OUT/fuzzer_prefix/bin

COPY --from=libunwind-builder /libunwind_build/libunwind.tar.gz /tmp/
RUN cd / && \
    tar xf /tmp/libunwind.tar.gz && \
    ldconfig && \
    mkdir -p $OUT/fuzzer_prefix/lib && \
    cp /usr/local/lib/libunwind* $OUT/fuzzer_prefix/lib

COPY --from=fuzzer-builder \
    /snapshot_fuzzer/AngoraSnapshot-0.0.1-Linux.sh /tmp/
RUN /tmp/AngoraSnapshot-0.0.1-Linux.sh --skip-license --prefix=/usr/local && \
    mkdir -p $OUT/fuzzer_prefix/bin && \
    cp /usr/local/bin/fuzzer $OUT/fuzzer_prefix/bin

COPY --from=fuzzer-builder /extra_abilists /extra_abilists

COPY --from=fuzzer-builder \
    /llvm-project/libStandaloneFuzzTarget* /llvm-project/

COPY --from=fuzzer-builder \
    /llvm-project/plain-prefix/ /llvm-project/plain-prefix/
ENV ANGORA_LIBCXX_FAST_PREFIX=/llvm-project/plain-prefix/

COPY --from=fuzzer-builder \
    /llvm-project/track-prefix/ /llvm-project/track-prefix/
ENV ANGORA_LIBCXX_TRACK_PREFIX=/llvm-project/track-prefix/

COPY --from=fuzzer-builder \
    /llvm-project/snapshot-placement-prefix/ \
    /llvm-project/snapshot-placement-prefix/
ENV SNAPSHOT_PLACEMENT_LIBCXX_PREFIX=/llvm-project/snapshot-placement-prefix/

COPY --from=fuzzer-builder \
    /llvm-project/dfsan-snapshot-prefix/ \
    /llvm-project/dfsan-snapshot-prefix/
ENV DFSAN_SNAPSHOT_LIBCXX_PREFIX=/llvm-project/dfsan-snapshot-prefix/

COPY --from=fuzzer-builder \
    /llvm-project/xray-snapshot-prefix/ \
    /llvm-project/xray-snapshot-prefix/
ENV XRAY_SNAPSHOT_LIBCXX_PREFIX=/llvm-project/xray-snapshot-prefix/
