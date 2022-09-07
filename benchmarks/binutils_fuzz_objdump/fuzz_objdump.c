/* Copyright 2021 Google LLC
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

/*
 * We convert objdump.c into a header file to make convenient for fuzzing.
 * We do this for several of the binutils applications when creating
 * the binutils fuzzers.
 */
#include "fuzz_objdump.h"

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>

int old_main32(int argc, char* argv[argc + 1]);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  char filename[256];

  sprintf(filename, "/tmp/libfuzzer.%d", getpid());

  FILE *fp = fopen(filename, "wb");
  if (!fp) {
    return 0;
  }

  fwrite(data, size, 1, fp);
  fclose(fp);

  char *argv[] = {
    [0] = "objdump",
    [1] = "-x",
    [2] = filename,
  };
  int argc = sizeof(argv) / sizeof(argv[0]);
  old_main32(argc, argv);

  unlink(filename);

  return 0;
}

int __real_main(int argc, char* argv[argc + 1]);

int __wrap_main(int argc, char* argv[argc + 1]) {
  if (getenv("FUZZBENCH_SKIP_WRAPPER")) {
    if (argc != 2) {
      fprintf(stderr, "usage: %s TEST_CASE\n", argv[0]);
      exit(1);
    }

    fprintf(stderr, "FuzzBench: running without wrapper.\n");

    char *new_argv[] = {
      [0] = "objdump",
      [1] = "-x",
      [2] = argv[1],
    };
    int argc = sizeof(new_argv) / sizeof(new_argv[0]);

    // Call `main` in objdump.c
    return old_main32(argc, new_argv);
  }

  // Call `main` in FUZZER_LIB
  return __real_main(argc, argv);
}
