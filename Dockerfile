####### Base #######
FROM node:lts-alpine AS base

# Necessary
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# Because telemetry messages are annoying
ENV TURBO_TELEMETRY_DISABLED=1
ENV NEXT_TELEMETRY_DISABLED=1

# Instal Bash, OpenSSL and PNPM, as well as Turborepo globally
RUN apk add --no-cache bash openssl \
    && corepack enable \
    && corepack prepare pnpm@10.33.0 --activate \
    && pnpm add turbo --global


####### Prune #######
FROM base AS prune
WORKDIR /usr/src/app
ARG APP

COPY . .

RUN turbo prune --scope=$APP --docker


####### Install and Build #######
FROM base AS builder
WORKDIR /usr/src/app
ARG APP

COPY --from=prune /usr/src/app/out/json/ .

RUN \
    --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

# Use this RUN command instead of the above if you have dependencies that use native libraries which need dat node-gyp voodoo
#RUN \
#    --mount=type=cache,id=pnpm,target=/pnpm/store \
#      apk add --no-cache --virtual .gyp python3 make gcc g++ libc6-compat \
#      && pnpm add node-gyp --global \
#      && pnpm install --frozen-lockfile \
#      && apk del .gyp

COPY --from=prune /usr/src/app/out/full/ .

# --filter=${APP}^... is the secret sauce.
# It builds packages that $APP (i.e, /apps/web) depends on but NOT /apps/web itself. Obviously, we don't need to
# build nextjs / vite / whatever apps here, since we're using dev server functionality for local development.
# With very large typescript monorepo projects this can save a huge amount of time when rebuilding is necessary
RUN turbo run build --no-cache --filter=${APP}^...