FROM golang:1.21 AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ ./cmd/
RUN CGO_ENABLED=0 GOOS=linux go build -o webhook ./cmd/webhook

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /app/webhook .
USER 65532:65532

ENTRYPOINT ["/webhook"]
