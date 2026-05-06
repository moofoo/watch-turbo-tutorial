#!/bin/bash

# Install dependencies
pnpm up -r --workspace

# Wipe out the compose project
docker compose down -v --remove-orphans

# Build the compose project
docker compose build --no-cache

# Start the database service, detached
docker compose up --wait -d -y --no-build db
sleep 1

# Build the prisma client and seed the database
turbo run db:reset

# Shut it down
docker compose stop