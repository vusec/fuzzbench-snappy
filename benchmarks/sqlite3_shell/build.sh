#!/bin/bash

set -euxo pipefail

cd sqlite3
patch -u -p1 < "$SRC/fuzzershell.c.patch"
cd ..

mkdir build
cd build
../sqlite3/configure
make sqlite3.h sqlite3.c

# Limit max length of data blobs and sql queries to prevent irrelevant OOMs.
# Also limit max memory page count to avoid creating large databases.
# Add all flags suggested by sqlite3 authors for fuzzing
export CFLAGS="$CFLAGS -DSQLITE_MAX_LENGTH=128000000 \
               -DSQLITE_MAX_SQL_LENGTH=128000000 \
               -DSQLITE_MAX_MEMORY=25000000 \
               -DSQLITE_PRINTF_PRECISION_LIMIT=1048576 \
               -DSQLITE_MAX_PAGE_COUNT=16384
               -DSQLITE_THREADSAFE=0 \
               -DSQLITE_ENABLE_LOAD_EXTENSION=0 \
               -DSQLITE_NO_SYNC \
               -DSQLITE_DEBUG \
               -DSQLITE_ENABLE_FTS4 \
               -DSQLITE_ENABLE_RTREE \
               -DSQLITE_OMIT_RANDOMNESS"

$CC $CFLAGS -c -o $SRC/fuzz_target.o $SRC/fuzz_target.c
$CC $CFLAGS -c -I. -o $SRC/fuzzershell.o $SRC/sqlite3/tool/fuzzershell.c
$CC $CFLAGS -c -I. -o $SRC/sqlite3.o sqlite3.c

$CXX $CXXFLAGS -Wl,--wrap=main -o $OUT/sqlite3_fuzz_target \
    $SRC/fuzz_target.o $SRC/fuzzershell.o $SRC/sqlite3.o $FUZZER_LIB -ldl

cp $SRC/*.zip $OUT/
