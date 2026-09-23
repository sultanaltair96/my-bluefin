# Name: my-bluefin
#
# Thin personal derivative: Bluefin owns the desktop, kernel, NVIDIA, Brew and
# runtime integration. The identity contract in tests/contract/identity_test.bats
# keeps this comment, ARG IMAGE_NAME, the Justfile default and
# artifacthub-repo.yml in agreement.
FROM scratch AS ctx
COPY build /build
COPY custom /custom

FROM ghcr.io/ublue-os/bluefin-nvidia-open:stable@sha256:3b4a36dc0cc2337ebbafcd9926f35614447f2fdee4b028d2e3a720e49254b4a5

ARG IMAGE_NAME="my-bluefin"
ARG IMAGE_VENDOR="sultanaltair96"
ARG UBLUE_IMAGE_TAG="stable"
# Supplied by `just build` from the base image's FROM line.
ARG BASE_IMAGE_NAME=""
ARG VERSION=""

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build/00-image-info.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build/25-personal-overlay.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build/35-signing-policy.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/40-gnome-extensions.sh

### IMAGE METADATA
## The Containerfile owns the metadata schema baked into every image. Local
## builds and CI supply the dynamic values through `just build`; keeping these
## ARGs late prevents a new version or timestamp from invalidating package and
## overlay layers above.
ARG IMAGE_DESC="Taanis's reproducible GNOME image with NVIDIA support"
ARG IMAGE_CREATED=""
ARG IMAGE_LOGO_URL="https://avatars.githubusercontent.com/u/120078124?s=200&v=4"
ARG IMAGE_KEYWORDS="bootc,ublue,universal-blue"
ARG IMAGE_REF="main"
## The commit the image was built from. It is declared here, with the other
## volatile metadata, so a new commit only invalidates the label layer.
## Declaring it before 00-image-info.sh would invalidate the package and overlay
## layers on every commit, which is why os-release does not carry it.
ARG SHA_HEAD_SHORT=""

LABEL org.opencontainers.image.title="${IMAGE_NAME}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${SHA_HEAD_SHORT}" \
      org.opencontainers.image.description="${IMAGE_DESC}" \
      org.opencontainers.image.source="https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}/blob/${IMAGE_REF}/Containerfile" \
      org.opencontainers.image.url="https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}" \
      org.opencontainers.image.vendor="${IMAGE_VENDOR}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      io.artifacthub.package.readme-url="https://raw.githubusercontent.com/${IMAGE_VENDOR}/${IMAGE_NAME}/refs/heads/main/README.md" \
      io.artifacthub.package.logo-url="${IMAGE_LOGO_URL}" \
      io.artifacthub.package.keywords="${IMAGE_KEYWORDS}" \
      io.artifacthub.package.license="Apache-2.0" \
      io.artifacthub.package.deprecated="false" \
      containers.bootc="1"

### INIT
## Required for bootc images
CMD ["/sbin/init"]

### LINTING
## Verify final image and contents are correct. --fatal-warnings catches issues.
RUN bootc container lint --fatal-warnings
