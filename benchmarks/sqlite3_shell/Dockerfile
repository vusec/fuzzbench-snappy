FROM gcr.io/oss-fuzz-base/base-builder@sha256:1b6a6993690fa947df74ceabbf6a1f89a46d7e4277492addcd45a8525e34be5a
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
        make \
        autoconf \
        automake \
        libtool \
        curl \
        tcl \
        zlib1g-dev

RUN mkdir $SRC/sqlite3 && \
    cd $SRC/sqlite3 && \
    curl 'https://sqlite.org/src/tarball/sqlite.tar.gz?r=c78cbf2e86850cc6' -o sqlite3.tar.gz && \
        tar xzf sqlite3.tar.gz --strip-components 1

RUN find $SRC/sqlite3 -name "*.test" \
        | xargs zip $SRC/sqlite3_fuzz_target_seed_corpus.zip

COPY * $SRC
