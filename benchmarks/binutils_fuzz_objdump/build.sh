#!/bin/bash -eu
# Copyright 2019 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

export AFL_LLVM_INSTRUMENT=CLASSIC,CTX-2
export AFL_ENABLE_CMPLOG=0
export AFL_LAF_CHANCE=30

# build project
if [ "$SANITIZER" = undefined ]; then
    export CFLAGS="$CFLAGS -fno-sanitize=unsigned-integer-overflow"
    export CXXFLAGS="$CXXFLAGS -fno-sanitize=unsigned-integer-overflow"
fi
cd binutils-gdb

# Comment out the lines of logging to stderror from elfcomm.c
# This is to make it nicer to read the output of libfuzzer.
cd binutils
sed -i 's/vfprintf (stderr/\/\//' elfcomm.c
sed -i 's/fprintf (stderr/\/\//' elfcomm.c
cd ../

./configure --disable-gdb --disable-gdbserver --disable-gdbsupport \
	    --disable-libdecnumber --disable-readline --disable-sim \
	    --disable-libbacktrace --disable-gas --disable-ld --disable-werror \
      --enable-targets=all
make clean
make -j MAKEINFO=true && true

# Due to a bug in AFLPP that occurs *sometimes* we continue only if we have the
# libraries that we need
if ([ -f ./libctf/.libs/libctf.a ]); then
  # Make fuzzer directory
  mkdir fuzz
  cp ../fuzz_*.c fuzz/
  cd fuzz

  LIBS="../opcodes/libopcodes.a ../libctf/.libs/libctf.a ../bfd/libbfd.a ../zlib/libz.a ../libiberty/libiberty.a"

  # TODO build corpuses

  # Now compile the src/binutils fuzzers
  cd ../binutils

  # Compile the fuzzers.
  # The general strategy is to remove main functions such that the fuzzer (which has its own main)
  # can link against the code.

  cp ../../fuzz_*.c .

  # Patching
  for i in objdump; do
      sed -i 's/strip_main/strip_mian/g' $i.c
      sed -i 's/copy_main/copy_mian/g' $i.c
      sed 's/main (int argc/old_main32 (int argc, char **argv);\nint old_main32 (int argc/' $i.c > fuzz_$i.h
      sed -i 's/copy_mian/copy_main/g' fuzz_$i.h
  done

  # Compile all fuzzers
  for i in objdump; do
      $CC $CFLAGS -DHAVE_CONFIG_H -DOBJDUMP_PRIVATE_VECTORS="" -I. -I../bfd -I./../bfd -I./../include \
        -I./../zlib -DLOCALEDIR="\"/usr/local/share/locale\"" \
        -Dbin_dummy_emulation=bin_vanilla_emulation -W -Wall -MT \
        fuzz_$i.o -MD -MP -c -o fuzz_$i.o fuzz_$i.c
  done

  # Link the files, but only if everything went well, which we verify by checking
  # the presence of some object files.
  if ([ -f dwarf.o ] && [ -f elfcomm.o ] && [ -f version.o ]); then
    LINK_LIBS="-Wl,--start-group ${LIBS} -Wl,--end-group"

    # Link objdump fuzzer
    OBJS="dwarf.o prdbg.o rddbg.o unwind-ia64.o debug.o stabs.o rdcoff.o bucomm.o version.o filemode.o elfcomm.o od-xcoff.o"
    $CXX $CXXFLAGS -I./../zlib -o $OUT/fuzz_objdump -Wl,--wrap=main \
      -Wl,--start-group $LIB_FUZZING_ENGINE fuzz_objdump.o -Wl,--end-group \
      ${OBJS} ${LINK_LIBS}
  fi 

  # BUILD SEEDS
  # Set up seed corpus for readelf in the form of a single ELF file.
  # Assuming all went well then we can simply create a fuzzer based on
  # the object files in the binutils directory.
  cd $SRC/
  mkdir corp
  cp $SRC/binutils-gdb/binutils/filemode.o ./corp/

  git clone https://github.com/DavidKorczynski/binary-samples $SRC/binary-samples
  cp $SRC/binary-samples/elf-NetBSD-x86_64-echo $SRC/corp
  cp $SRC/binary-samples/elf-simple_elf $SRC/corp
  cp $SRC/binary-samples/MachO-iOS-armv7s-Helloworld $SRC/corp
  cp $SRC/binary-samples/pe-Windows-ARMv7-Thumb2LE-HelloWorld $SRC/corp
  cp $SRC/binary-samples/libSystem.B.dylib $SRC/corp

  # Create a simple archive
  mkdir $SRC/tmp_archive
  cp $SRC/binutils-gdb/binutils/rename.o $SRC/tmp_archive/
  cp $SRC/binutils-gdb/binutils/is-ranlib.o $SRC/tmp_archive/
  cp $SRC/binutils-gdb/binutils/not-strip.o $SRC/tmp_archive/
  ar cr $SRC/seed_archive.a $SRC/tmp_archive/*.o
  mv $SRC/seed_archive.a ./corp/seed_archive.a

  # Zip the folder together as OSS-Fuzz expects the seed corpus as ZIP, and
  # then copy the folder around to various fuzzers.
  zip -r -j $OUT/fuzz_objdump_seed_corpus.zip $SRC/corp

  # Copy options files
  for ft in objdump; do
    echo "[libfuzzer]" > $OUT/fuzz_${ft}.options
    echo "detect_leaks=0" >> $OUT/fuzz_${ft}.options
  done
fi
