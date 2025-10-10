# Makefile for Docker-based integration tests

.PHONY: help build test clean test-broker test-chat test-single

help:
	@echo "Zigcat Docker Integration Tests"
	@echo
	@echo "Usage:"
	@echo "  make build          - Build Docker image"
	@echo "  make test           - Run all integration tests"
	@echo "  make test-broker    - Run only broker mode tests"
	@echo "  make test-chat      - Run only chat mode tests"
	@echo "  make test-single    - Run single test (requires TEST=name)"
	@echo "  make clean          - Clean up Docker containers and results"
	@echo
	@echo "Examples:"
	@echo "  make test"
	@echo "  make test-broker"
	@echo "  make TEST=broker-2client test-single"

build:
	docker-compose -f docker-compose.yml build

test: build
	@chmod +x scripts/run-tests.sh
	@./scripts/run-tests.sh

test-broker: build
	@echo "Running broker mode tests..."
	@docker-compose up --abort-on-container-exit broker-2client-server broker-2client-client1 broker-2client-client2
	@docker-compose up --abort-on-container-exit broker-5client-server broker-5client-client1 broker-5client-client2 broker-5client-client3 broker-5client-client4 broker-5client-client5
	@docker-compose down

test-chat: build
	@echo "Running chat mode tests..."
	@docker-compose up --abort-on-container-exit chat-nickname-server chat-nickname-client1 chat-nickname-client2
	@docker-compose up --abort-on-container-exit chat-format-server chat-format-client1 chat-format-client2
	@docker-compose down

test-single: build
	@if [ -z "$(TEST)" ]; then \
		echo "Error: TEST variable not set"; \
		echo "Usage: make TEST=broker-2client test-single"; \
		exit 1; \
	fi
	@chmod +x scripts/run-single-test.sh
	@./scripts/run-single-test.sh $(TEST)

clean:
	docker-compose down --remove-orphans --volumes
	rm -rf results/*
	docker system prune -f
