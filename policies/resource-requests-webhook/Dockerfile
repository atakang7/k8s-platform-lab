FROM golang:1.27.1@sha256:512690a5660563b57d37ecc31129e7f136e831db2aed24a1dbeb8ad7380dc0fa AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ ./cmd/
RUN go test ./... \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /app/webhook ./cmd/webhook

FROM gcr.io/distroless/static:nonroot@sha256:1c2c046bc09ed40fad370b599a0b1ae7987f55b01e247cf27a7c27cd97e5bbc7
ARG SOURCE_REPOSITORY=unknown
ARG SOURCE_REVISION=unknown

LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"

WORKDIR /
COPY --from=builder --chown=65532:65532 /app/webhook /webhook
USER 65532:65532
EXPOSE 8443
ENTRYPOINT ["/webhook"]
