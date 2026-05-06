#!/bin/bash

clear

sleep 1

SERVICE=$1

COMPOSE_PROJECT="$(docker compose ls -a --format json | jq -r '.[0].Name')"

echo "Waiting for $1 to be running..."
while [ "$(docker inspect -f '{{.State.Status}}' $COMPOSE_PROJECT-$SERVICE-1 2>/dev/null)" != "running" ]; do
  echo -n '.'
  sleep 2;
done

sleep 1

clear