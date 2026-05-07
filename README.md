To get this project up and running, first run `bash scripts/init.sh` in the repo directory. Then, you can start the project with `docker compose up --wait` or `tmuxinator start`.

# Typescript Monorepo Development using Docker Compose Watch, Turborepo and PNPM

## Introduction

While developing web applications using [Docker Compose](https://docs.docker.com/compose/) has many positives, like portability and making it easy to add databases and other services like Redis to your environment, it's important to remember that Docker and containers generally were not originally meant to facilitate the sort of immediate-feedback development workflows which web developers expect.

The method of bind-mounting code into a Node image container and creating an anonymous volume for `node_modules` was always something of a hack, and brings with it little annoyances that can add up to a frustrating experience, like dependency de-sync between host and container, and packages that require building or code generation creating folders locally with root permissions because of the bind mount.

[In 2023](https://www.docker.com/blog/announcing-docker-compose-watch-ga-release/), Docker announced the GA relase of the Docker Compose Watch feature ([Spec](https://docs.docker.com/reference/compose-file/develop/), [Manual entry](https://docs.docker.com/compose/how-tos/file-watch/)). From the announcement,

> With containerized application development, there are more steps than Alt+Tab and hitting reload in your browser. Even with caching, rebuilding the image and re-creating the container — especially after waiting on stop and start time — can disrupt focus. We built Docker Compose Watch to smooth away these workflow papercuts. We have learned from many people using our open source Docker Compose project for local development. Now we are natively addressing common workflow friction we observe, like the use case of hot reload for frontend development.

This tutorial will show how to use [Turborepo](https://turborepo.dev/) and the [PNPM package manager](https://pnpm.io/) with the Docker Compose Watch feature to create a smooth development experience, and how to resolve some of the difficulties that arise when trying to deal with shared packages that require a build or code-generation step in a monorepo setup.



Here is the [Tutorial Repository](https://github.com/moofoo/watch-turbo-tutorial). To get this project up and running, first run [`bash scripts/init.sh`](https://github.com/moofoo/watch-turbo-tutorial/blob/main/scripts/init.sh) in the repo directory. Then, you can start the project with `docker compose up --wait` or [`tmuxinator start`](https://dev.to/moofoo/docker-basics-using-tmux-and-tmuxinator-for-a-better-docker-compose-experience-43ma).

## Required Packages

- You should have at least Node version > 20 installed (I recommend just using the LTS version)
- The [PNPM package manager](https://pnpm.io/installation)
- It's not required, but I would recommend [installing Turborepo globally](https://turborepo.dev/docs/getting-started/installation#global-installation) (`pnpm add turbo --global`)

## Project repo description and goals

This simple project runs a [Next.js](https://nextjs.org/) app which has the [Prisma ORM client](https://www.prisma.io/orm) as a shared package. Prisma was chosen specifically because the client requires [code-generation](https://www.prisma.io/docs/cli/generate) that must be run locally as well as in the container, and setting it up also demonstrates how to configure the environment so Prisma can talk to the Postgresql database from the host as well as when run in the container.

As far as goals, we want to be able to

- Work locally on source code and have those changes synced with the running container

- If we make changes to the [Prisma schema](https://www.prisma.io/docs/orm/prisma-schema/overview) and rebuild the client, have the client code generation also happen in the container (without needing to rebuild the whole project)

- Require rebuilding services ONLY when their dependencies change.

## Development Dockerfile

First, let's go over the Development Dockerfile. I say "development" Dockerfile because it makes use of Turborepo features that wouldn't make sense when building an image for production.

You can view the full Dockerfile [here](https://github.com/moofoo/watch-turbo-tutorial/blob/main/Dockerfile).

Let's go over what each layer does:

```yaml
####### Base #######
FROM node:lts-alpine AS base

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

ENV TURBO_TELEMETRY_DISABLED=1
ENV NEXT_TELEMETRY_DISABLED=1

RUN apk add --no-cache bash openssl \
  && corepack enable \
  && corepack prepare pnpm@10.33.0 --activate \
  && pnpm add turbo --global
```

This is our 'base' Node layer. First, it sets some environment variables that are needed so Corepack and PNPM work. Then, it adds some packages to the container (Prisma complains if OpenSSL is not installed) and installs PNPM. Finally, it adds Turborepo globally.

```yaml
####### Prune #######
FROM base AS prune
WORKDIR /usr/src/app
ARG APP

COPY . .

RUN turbo prune --scope=$APP --docker
```

This layer copes in the project files and then runs the turborepo [prune](https://turborepo.dev/docs/reference/prune) command with the [--docker flag](https://turborepo.dev/docs/guides/tools/docker) for a specific package in the monorepo, as determined by the $APP argument. $APP will be defined for the service in docker-compose.yml. This setup is useful, since if additional Apps are ever added to the project we can just reuse this Dockerfile and pass the right $APP value for the service in docker-compose.yml.

The directories/files turborepo creates here will be used in subsequent layers. From the Turborepo docs, the prune command will "Generate a partial monorepo for a target package.", and passing the `--docker` flag will create

- A folder named json with the pruned workspace's package.json files.
- A folder named full with the pruned workspace's full source code for the internal packages needed to build the target.
- A pruned lockfile containing the subset of the original lockfile needed to build the target.

```yaml
####### Install and Build #######
FROM base AS builder
WORKDIR /usr/src/app
ARG APP

COPY --from=prune /usr/src/app/out/json/ .

RUN \
  --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY --from=pruner /usr/src/app/out/full/ .

RUN turbo run build --no-cache --filter=${APP}^...
```

First, this layer copies the workspace's package.json files to the container before running `pnpm install --frozen-lockfile`. A [cache mount](https://docs.docker.com/build/cache/optimize/) is used for the RUN command here. Since only the package.json files are copied, this means that the `RUN` command will only re-execute on build if workspace dependencies have changed (vs re-running it if ANY source files have changed). Next, the workspace's source files are copied in and packages are built, if necessary. 

__The syntax of the filter flag (`--filter=${APP}^...`) here is significant:__ What this does is cause only the packages that $APP depends on to be built, but not $APP itself. This is what we want, because we don't need to build the Next.js app for local development purposes (we have the dev server), however we DO need Prisma to do it's code generation business, which the Next.js app depends on.

## The turbo.json file

Before looking at docker-compose.yml and the Docker Compose Watch setup, let's look at the [turbo.json file](https://github.com/moofoo/watch-turbo-tutorial/blob/main/turbo.json).

```json
{
  "$schema": "https://turborepo.dev/schema.json",
  "globalEnv": ["PORT", "DATABASE_URL"],
  "tasks": {
    "build": {
      "dependsOn": ["^build", "^db:generate"],
      "inputs": ["$TURBO_DEFAULT$", ".env*"],
      "outputs": [".next/**", "!.next/cache/**", "dist/**", "generated/**"]
    },
    "lint": {
      "dependsOn": ["^lint"]
    },
    "check-types": {
      "dependsOn": ["^check-types"]
    },
    "dev": {
      "dependsOn": ["^db:generate"],
      "cache": false
    },
    "db:generate": {
      "cache": false
    },
    "db:push": {
      "cache": false
    },
    "db:seed": {
      "cache": false
    },
    "db:reset": {
      "cache": false
    }
  }
}
```

The important configuration here is `dependsOn` for the `build` and `dev` tasks.

Here's the build task:

```json
"build": {
      "dependsOn": ["^build", "^db:generate"],
      "inputs": ["$TURBO_DEFAULT$", ".env*"],
      "outputs": [".next/**", "!.next/cache/**", "dist/**", "generated/**"]
    },
```

Here, the `dependsOn` config means that when you build a specific workspace app with `turbo run build --filter=AN_APP`, turbo repo will run the build script(s) for any packages that "AN_APP" depends on (as defined in their package.json file), as well as running `db:generate` in any packages with that script (Prisma, in our example), before executing the build script for the specified App.

__In other words, this means that when `turbo run build --no-cache --filter=${APP}^...` is run in the Dockerfile, the Prisma client will also be generated.__

And now the dev task:

```json
 "dev": {
      "dependsOn": ["^db:generate"],
      "cache": false
    },
```

This makes it so Prisma generates its client whenever `turbo run dev` is called for apps that depend on the shareed Prisma package. The reason for doing this for the dev command (in addition to build) will make more sense when we get to setting up Docker Compose Watch for the Next.js service.

## The docker-compose.yml file

I'm only going to talk about the `develop watch` config for the "web" Next.js service here. You can view the full docker-compose.yml file [here](https://github.com/moofoo/watch-turbo-tutorial/blob/main/docker-compose.yml).

```yaml
services:
  ...other services
  web:
    ...other config
    command: turbo run dev --filter=web
    develop:
      watch:
        - action: sync
          path: ./apps/web
          target: /usr/src/app/apps/web
          initial_sync: true

        - action: sync
          path: ./packages/database/prisma
          target: /usr/src/app/packages/database/prisma
          initial_sync: true

        - action: restart
          path: ./packages/database/generated

        - action: rebuild
          path: ./apps/web/package.json

        - action: rebuild
          path: ./packages/database/package.json

  ...rest
```

Let's go over each Watch action:

```yaml
- action: sync
  path: ./apps/web
  target: /usr/src/app/apps/web
  initial_sync: true
```

This synchronizes the Nest.js app's source files with those in the container when the compose project starts up and whenever they change. Files/directories we DON'T want to sync are listed in a [.dockerignore file](https://github.com/moofoo/watch-turbo-tutorial/blob/main/apps/web/.dockerignore).

```yaml
- action: sync
  path: ./packages/database/prisma
  target: /usr/src/app/packages/database/prisma
  initial_sync: true
```

This synchronizes the prisma schema file to the container on startup and whenever it changes, which is important for the next action...

```yaml
- action: restart
  path: ./packages/database/generated
```

This restarts the 'web' container when the prisma client is generated locally (when the generated client's code changes). In other words, if you make changes to the Prisma schema and then generate the client locally, this will cause the "web" service to restart.

**Here's the clever part**: Recall that in the `turbo.json` file, the dev task was configured to also run `db:generate` whenever it's called (per the app's dependencies). Consequently, when the 'web' service restarts and calls its command (`turbo run dev --filter=web`), thise will re-generate the Prisma client in the container based on the updated `schema.prisma` file, which are synchronized in the container by the previous watch action.

```yaml
- action: rebuild
  path: ./apps/web/package.json

- action: rebuild
  path: ./packages/database/package.json
```

These actions simply cause the service to rebuild if the package.json files change. This is unavoidable, but fortunately the multi-layer development Dockerfile has been optimized for local development to try and make this as painless as possible.

## An example workflow

To follow this example, you'll need to have cloned the [tutorial repo](https://github.com/moofoo/watch-turbo-tutorial), run `bash scripts/init.sh`, and have the project running in watch mode with `docker compose up --wait`. To make the changes to code listed below, you will of course also need the project open in your code editor.

With the project running, if you open http://localhost:3000 in your browser you should see:

![Localhost](https://github.com/moofoo/watch-turbo-tutorial/raw/refs/heads/main/localhost_screenshot.png)

Let's update the Prisma schema as well as the seed script to see those changes reflected in the running service.

First, open [`/packages/database/prisma/schema.prisma`](https://github.com/moofoo/watch-turbo-tutorial/blob/main/packages/database/prisma/schema.prisma) and add a nullable Int column named "age" to the User model. After doing that, the schema file should look like so:

```
generator client {
  provider = "prisma-client"
  output   = "../generated/prisma"
}

datasource db {
  provider = "postgresql"
}

enum Role {
  USER
  ADMIN
}

model User {
  id    Int     @id @default(autoincrement())
  email String  @unique
  name  String?
  age Int?
}

```

Next, open up [`/packages/database/prisma/seed.ts`](https://github.com/moofoo/watch-turbo-tutorial/blob/main/packages/database/prisma/seed.ts) and add ages for the two Users in the seed data. After making those changes, the file should look like this:

```ts
import { PrismaClient, Prisma } from "../generated/prisma/client";
import { PrismaPg } from "@prisma/adapter-pg";
import { Pool } from "pg";
import "dotenv/config";

const connectionString = `${process.env.DATABASE_URL}`;

const pool = new Pool({ connectionString });

const adapter = new PrismaPg(pool);

const prisma = new PrismaClient({ adapter });

const userData: Prisma.UserCreateInput[] = [
  {
    name: "Alice",
    email: "alice@prisma.io",
    age: 29,
  },
  {
    name: "Bob",
    email: "bob@prisma.io",
    age: 32,
  },
];

async function main() {
  for (const u of userData) {
    await prisma.user.create({ data: u });
  }
}

main()
  .then(async () => {
    await prisma.$disconnect();
    await pool.end();
  })
  .catch(async (e) => {
    console.error(e);
    await prisma.$disconnect();
    await pool.end();
    process.exit(1);
  });
```

Finally, we're going re-generate the client locally, update the Postgresql database to match the prisma schema, and then re-seed the database, all without having to stop docker compose or rebuild the service. I created a script entry for the Prisma package which does all that named `db:reset`, which just runs the following: `prisma generate && prisma db push --force-reset && prisma db seed`.

To call this, run `turbo run db:reset` in the project root.

After running that command, you should see the following when you refresh http://localhost:3000 in the browser:

![Localhost](https://github.com/moofoo/watch-turbo-tutorial/raw/refs/heads/main/localhost_changed_screenshot.png)
