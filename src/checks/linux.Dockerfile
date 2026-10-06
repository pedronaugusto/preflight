# The Linux image `zig build ci-linux --` runs a package's suite in, unless the
# package keeps its own ci/linux.Dockerfile.
#
# Debian for the glibc most Linux users have, plus the Zig release the gate
# pins, fetched by version so the image is reproducible from this file alone.
# The architecture is the host's. A package that needs more, such as a tool
# its tests drive, keeps its own image; a musl image is always the package's.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.16.0
RUN set -e; arch=$(uname -m); \
    for name in "zig-${arch}-linux-${ZIG}" "zig-linux-${arch}-${ZIG}"; do \
      if curl -fsSL "https://ziglang.org/download/${ZIG}/${name}.tar.xz" -o /tmp/zig.tar.xz; then break; fi; done; \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
