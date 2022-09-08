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

import os
from pathlib import Path
import copy
import subprocess

from fuzzers import utils
from fuzzers.angora import fuzzer as angora_fuzzer


def build_snapshot_placement():
    build_env = copy.deepcopy(os.environ)

    build_env["CC"] = "clang_snapshot_placement"
    build_env["CXX"] = "clang_snapshot_placement++"

    compiler_flags = angora_fuzzer.get_blacklist_args(os.environ["BENCHMARK"])

    # The build.sh scripts do not use the LDFLAGS variable, so we are forced to
    # use CFLAGS and CXXFLAGS instead.
    utils.append_flags("CFLAGS", compiler_flags, build_env)
    utils.append_flags("CXXFLAGS", compiler_flags, build_env)

    build_env["FUZZER_LIB"] = str(
        angora_fuzzer.LLVM_PROJECT_PATH / "libStandaloneFuzzTargetSnapshotPlacement.a"
    )

    # These directories need to be restored to build multiple times, according
    # to the script from AFL++
    src = Path(build_env["SRC"])
    work = Path(build_env["WORK"])
    with utils.restore_directory(src), utils.restore_directory(work):
        utils.build_benchmark(build_env)

    out_path = Path(build_env["OUT"])
    fuzz_target_name = build_env["FUZZ_TARGET"]
    fuzz_target_path = out_path / fuzz_target_name
    fuzz_target_path.rename(out_path / (fuzz_target_name + "_snapshot_placement"))


def build_dfsan_snapshot():
    build_env = copy.deepcopy(os.environ)

    build_env["CC"] = "clang_dfsan_snapshot"
    build_env["CXX"] = "clang_dfsan_snapshot++"

    compiler_flags = angora_fuzzer.get_blacklist_args(os.environ["BENCHMARK"])

    # The build.sh scripts do not use the LDFLAGS variable, so we are forced to
    # use CFLAGS and CXXFLAGS instead.
    utils.append_flags("CFLAGS", compiler_flags, build_env)
    utils.append_flags("CXXFLAGS", compiler_flags, build_env)

    build_env["FUZZER_LIB"] = str(
        angora_fuzzer.LLVM_PROJECT_PATH / "libStandaloneFuzzTargetDFSanSnapshot.a"
    )

    # These directories need to be restored to build multiple times, according
    # to the script from AFL++
    src = Path(build_env["SRC"])
    work = Path(build_env["WORK"])
    with utils.restore_directory(src), utils.restore_directory(work):
        utils.build_benchmark(build_env)

    out_path = Path(build_env["OUT"])
    fuzz_target_name = build_env["FUZZ_TARGET"]
    fuzz_target_path = out_path / fuzz_target_name
    fuzz_target_path.rename(out_path / (fuzz_target_name + "_dfsan_snapshot"))


def build_xray_snapshot():
    build_env = copy.deepcopy(os.environ)

    build_env["CC"] = "clang_xray_snapshot"
    build_env["CXX"] = "clang_xray_snapshot++"

    build_env["FUZZER_LIB"] = str(
        angora_fuzzer.LLVM_PROJECT_PATH / "libStandaloneFuzzTargetXRaySnapshot.a"
    )

    # These directories need to be restored to build multiple times, according
    # to the script from AFL++
    src = Path(build_env["SRC"])
    work = Path(build_env["WORK"])
    with utils.restore_directory(src), utils.restore_directory(work):
        utils.build_benchmark(build_env)

    out_path = Path(build_env["OUT"])
    fuzz_target_name = build_env["FUZZ_TARGET"]
    fuzz_target_path = out_path / fuzz_target_name
    fuzz_target_path.rename(out_path / (fuzz_target_name + "_xray_snapshot"))


def build():
    angora_fuzzer.build()
    angora_fuzzer.remove_placeholder()

    print("Building with SnapshotPlacement instrumentation")
    build_snapshot_placement()
    print("Building with DFSanSnapshot instrumentation")
    build_dfsan_snapshot()
    print("Building with XRaySnapshot instrumentation")
    build_xray_snapshot()

    angora_fuzzer.build_placeholder()


def fuzz(input_corpus, output_corpus, target_binary):
    binaries_path = Path(target_binary).parent
    fuzz_target_name = os.environ["FUZZ_TARGET"]

    angora_fast_path = binaries_path / (fuzz_target_name + "_angora_fast")
    assert angora_fast_path.is_file()

    angora_track_path = binaries_path / (fuzz_target_name + "_angora_track")
    assert angora_track_path.is_file()

    snapshot_placement_path = binaries_path / (fuzz_target_name + "_snapshot_placement")
    assert snapshot_placement_path.is_file()

    dfsan_snapshot_path = binaries_path / (fuzz_target_name + "_dfsan_snapshot")
    assert dfsan_snapshot_path.is_file()

    xray_snapshot_path = binaries_path / (fuzz_target_name + "_xray_snapshot")
    assert xray_snapshot_path.is_file()

    # Angora needs at least one seed file
    input_corpus = Path(input_corpus)
    if not any(input_corpus.iterdir()):
        print(f"Using empty file as seed, no seeds provided in: {input_corpus}")
        empty_path = input_corpus / "empty"
        empty_path.touch()

    # Angora requires the output folder not to exist
    Path(output_corpus).rmdir()

    out_path = Path(os.environ["OUT"])
    os.environ["PATH"] += f":{out_path / 'fuzzer_prefix/bin' }"
    os.environ["LD_LIBRARY_PATH"] = str(out_path / "fuzzer_prefix/lib")
    os.environ["ANGORA_DISABLE_CPU_BINDING"] = "true"
    os.environ["FUZZBENCH_SKIP_WRAPPER"] = "1"
    os.environ["RUST_BACKTRACE"] = "1"
    os.environ["RUST_LOG"] = "warn"

    subprocess.run(
        [
            "fuzzer",
            "--memory_limit=2048",
            f"--input={input_corpus}",
            f"--output={output_corpus}",
            "--mode=llvm",
            f"--track={angora_track_path}",
            f"--snapshot-placement={snapshot_placement_path}",
            f"--dfsan-snapshot={dfsan_snapshot_path}",
            f"--xray-snapshot={xray_snapshot_path}",
            "--",
            str(angora_fast_path),
            "@@",
        ],
        check=True,
    )


def get_stats(output_corpus, fuzzer_log):  # pylint: disable=unused-argument
    """Gets fuzzer stats for Angora."""
    return angora_fuzzer.get_stats(output_corpus, fuzzer_log)
