# Pinned to keep CI on hare 0.26.0 until we explicitly bump it.
#
# The base image is pinned by digest because alpine:edge is a rolling
# tag. The hare/hare-json package versions are also pinned because
# `apk add` resolves against alpine's current edge repository index at
# build time, not against a snapshot tied to the base image — so
# without the version constraints we'd pick up new hare releases the
# moment alpine publishes them.
#
# To bump: pull a fresh alpine:edge, read the new digest from
# `docker inspect`, and update both the digest below and the hare /
# hare-json versions in the apk line.
FROM alpine:edge@sha256:9a341ff2287c54b86425cbee0141114d811ae69d88a36019087be6d896cef241

RUN apk add --no-cache \
    git \
    make \
    musl-dev \
    gcc \
    bash \
    hare=0.26.0.1-r0 \
    hare-json=0.26.0.0-r0
