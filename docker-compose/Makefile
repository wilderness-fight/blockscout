# Variables
COMPOSE_FILE=no-services.yml

# Targets
.PHONY: up down

up:
	docker compose -f $(COMPOSE_FILE) up -d

down:
	docker compose -f $(COMPOSE_FILE) down && rm -rf services/logs services/redis-data \
	services/blockscout-db-data services/dets
