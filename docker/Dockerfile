# Host image: rdma_gen + libsoftmetaroce (software MetaRoCE over UDP).
# Built with Meta's getdeps (folly / fbthrift / wangle ...). The first build takes a long time.
ARG UBUNTU=ubuntu:24.04

FROM ${UBUNTU} AS build
ARG METAROCE_REPO=https://github.com/facebookincubator/metaroce.git
ARG METAROCE_REF=6c5a3a4
ARG JOBS=6
ENV DEBIAN_FRONTEND=noninteractive PIP_BREAK_SYSTEM_PACKAGES=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-pip sudo gcc g++ make && rm -rf /var/lib/apt/lists/*
RUN git clone ${METAROCE_REPO} /src && git -C /src checkout ${METAROCE_REF}
WORKDIR /src
RUN apt-get update && python3 build/fbcode_builder/getdeps.py --allow-system-packages \
      install-system-deps --recursive rdma_gen && rm -rf /var/lib/apt/lists/*
RUN python3 build/fbcode_builder/getdeps.py --allow-system-packages build rdma_gen \
      --src-dir . --no-tests --free-up-disk --num-jobs ${JOBS} \
      --scratch-path /scratch --install-prefix /opt/metaroce

# rdma_gen links folly/fbthrift statically; strip debug info to keep the image small
# (function names stay, so stack traces remain readable).
RUN strip --strip-debug -o /rdma_gen /opt/metaroce/rdma_gen/bin/rdma_gen

FROM ${UBUNTU}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libre2-10 libssl3t64 libxxhash0 zlib1g libsodium23 libevent-2.1-7t64 libbz2-1.0 \
      liblz4-1 libzstd1 libsnappy1v5 libgflags2.2 libibverbs1 libnl-route-3-200 \
      iproute2 iputils-ping tcpdump ethtool procps python3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /rdma_gen /usr/local/bin/rdma_gen
CMD ["sleep", "infinity"]
