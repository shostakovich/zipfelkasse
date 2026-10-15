# syntax=docker/dockerfile:1
# check=error=true

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.7
ARG DEBIAN_VERSION=trixie-20261005-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# Assets are architecture-independent, so they build natively on the build host.
FROM --platform=$BUILDPLATFORM ${BUILDER_IMAGE} AS assets

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config/config.exs config/${MIX_ENV}.exs config/
COPY assets assets
COPY priv priv
COPY lib lib

RUN mix assets.setup && mix assets.deploy

FROM ${BUILDER_IMAGE} AS build

# The JIT's dual-mapped code pages crash the BEAM under emulation (cross-arch builds).
ENV ERL_FLAGS="+JMsingle true"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config first, so a change to runtime.exs does not recompile the deps.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY --from=assets /app/priv/static priv/static
# ZipfelkasseWeb.Icons compiles these SVGs in; without them mix compile fails.
COPY assets/vendor/lucide assets/vendor/lucide

RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libstdc++6 openssl libncurses6 ca-certificates tzdata curl sqlite3 && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    MIX_ENV="prod" \
    PORT=4000 \
    TZ=Europe/Berlin \
    DATABASE_PATH=/app/data/zipfelkasse.sqlite3

WORKDIR /app

RUN groupadd --system --gid 1000 zipfelkasse && \
    useradd zipfelkasse --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /app/data && chown zipfelkasse:zipfelkasse /app/data && chmod 700 /app/data

COPY --from=build --chown=zipfelkasse:zipfelkasse /app/_build/prod/rel/zipfelkasse ./

USER zipfelkasse

VOLUME /app/data
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=2m \
  CMD curl -fsS -o /dev/null "http://localhost:${PORT}/up" || exit 1

# The database and its backups hold YNAB tokens.
CMD ["/bin/sh", "-c", "umask 077 && /app/bin/migrate && exec /app/bin/server"]
