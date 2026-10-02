# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/zipfelkasse . \
 && mkdir -p /out/data /out/tmp && chmod 1777 /out/tmp

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/zipfelkasse /zipfelkasse
COPY --from=build /out/tmp /tmp
COPY --from=build --chown=65532:65532 /out/data /data
ENV ZIPFELKASSE_ADDR=:8080 \
    ZIPFELKASSE_DB=/data/zipfelkasse.db \
    TZ=Europe/Berlin
USER 65532:65532
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/zipfelkasse", "healthcheck"]
ENTRYPOINT ["/zipfelkasse"]
CMD ["serve"]
