#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define PROGRAM_CMDLINE(filename)                                              \
  { "fuzzershell", (filename) }

// Patched `main` function in the original program
int old_main(int argc, char *argv[argc + 1]);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  char filename[256];
  snprintf(filename, sizeof(filename), "/tmp/libfuzzer.%d", getpid());

  FILE *fp = fopen(filename, "wb");
  if (!fp) {
    return 0;
  }

  fwrite(data, size, 1, fp);
  fclose(fp);

  char *argv[] = PROGRAM_CMDLINE(filename);
  int argc = sizeof(argv) / sizeof(argv[0]);
  old_main(argc, argv);

  unlink(filename);

  return 0;
}

// `main` function in FUZZER_LIB
int __real_main(int argc, char *argv[argc + 1]);

// Real entry point of the executable
int __wrap_main(int argc, char *argv[argc + 1]) {
  if (!getenv("FUZZBENCH_SKIP_WRAPPER")) {
    return __real_main(argc, argv);
  }

  if (argc != 2) {
    fprintf(stderr, "usage: %s TEST_CASE\n", argv[0]);
    exit(1);
  }

  fprintf(stderr, "FuzzBench: running without wrapper.\n");

  char *new_argv[] = PROGRAM_CMDLINE(argv[1]);
  int new_argc = sizeof(new_argv) / sizeof(new_argv[0]);
  return old_main(new_argc, new_argv);
}
