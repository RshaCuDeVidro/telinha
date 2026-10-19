# Servidor dedicado do telinha. Imagem final: só o binário estático (FROM scratch).
#   docker build -t telinha-server .
#   docker run -p 7777:7777 -e TELINHA_SENHA=... telinha-server
FROM --platform=$BUILDPLATFORM alpine:3.20 AS build
ARG ZIG_VERSION=0.16.0
ARG BUILDARCH
ARG TARGETARCH
RUN apk add --no-cache curl xz \
 && case "$BUILDARCH" in arm64) ZA=aarch64 ;; *) ZA=x86_64 ;; esac \
 && curl -sSfL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZA}-linux-${ZIG_VERSION}.tar.xz" | tar xJ -C /opt \
 && ln -s /opt/zig-*/zig /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY tools ./tools
COPY assets ./assets
# -Dserver-only: não baixa as dependências do app (openh264, imgui...)
RUN zig build server -Dserver-only=true -Doptimize=ReleaseSafe \
 && case "$TARGETARCH" in arm64) A=aarch64 ;; *) A=x86_64 ;; esac \
 && cp "zig-out/bin/telinha-server-$A" /telinha-server

FROM scratch
COPY --from=build /telinha-server /telinha-server
EXPOSE 7777
ENTRYPOINT ["/telinha-server"]
