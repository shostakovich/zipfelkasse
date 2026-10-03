# syntax=docker/dockerfile:1

FROM crystallang/crystal:1.21.1-alpine AS build
RUN apk add --no-cache sqlite-static sqlite-dev ca-certificates tzdata
WORKDIR /src
COPY shard.yml shard.lock ./
RUN shards install --production
COPY . .
RUN mkdir -p /out/data /out/tmp && chmod 1777 /out/tmp \
 && crystal build --release --static --no-debug -o /out/zipfelkasse src/zipfelkasse.cr

FROM scratch
# The static OpenSSL looks for its CA bundle here.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
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
