# Build stage
FROM elixir:1.16-alpine AS builder

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY assets assets
COPY priv priv

WORKDIR /app/assets
RUN npm install

WORKDIR /app
RUN mix assets.deploy
RUN mix compile
RUN mix phx.digest
RUN mix release

# Runtime stage
FROM alpine:3.19 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/chat_service ./

ENV HOME=/app
ENV MIX_ENV=prod
ENV PORT=8888
ENV PHX_HOST=localhost
ENV SECRET_KEY_BASE=default_secret_key_base_change_in_production_for_security

EXPOSE 8888

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8888/api/health || exit 1

CMD ["bin/chat_service", "start"]
