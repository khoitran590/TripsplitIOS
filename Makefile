SHELL := /bin/bash

SUPABASE ?= supabase
FUNCTIONS_ENV ?= supabase/functions/.env.local
CHECK_BACKEND = SUPABASE_BIN="$(SUPABASE)" ./scripts/check-backend-prerequisites.sh

.PHONY: help backend-up backend-status backend-reset backend-test functions-serve functions-test backend-down

help:
	@echo "TripSplit local backend commands:"
	@echo "  make backend-up       Start local Supabase"
	@echo "  make backend-status   Show local service URLs and health"
	@echo "  make backend-reset    Rebuild the local database from migrations"
	@echo "  make backend-test     Run PostgreSQL security tests"
	@echo "  make functions-serve  Serve Edge Functions with the ignored local env file"
	@echo "  make functions-test   Run authenticated, non-paid Edge Function smoke tests"
	@echo "  make backend-down     Stop local Supabase"

backend-up:
	@$(CHECK_BACKEND)
	$(SUPABASE) start

backend-status:
	@$(CHECK_BACKEND)
	$(SUPABASE) status

backend-reset:
	@$(CHECK_BACKEND)
	$(SUPABASE) db reset

backend-test:
	@$(CHECK_BACKEND)
	$(SUPABASE) test db

functions-serve:
	@$(CHECK_BACKEND)
	@test -f "$(FUNCTIONS_ENV)" || { echo "error: missing $(FUNCTIONS_ENV)" >&2; exit 1; }
	$(SUPABASE) functions serve --env-file "$(FUNCTIONS_ENV)"

functions-test:
	@SUPABASE_BIN="$(SUPABASE)" ./scripts/test-edge-functions.sh

backend-down:
	@$(CHECK_BACKEND)
	$(SUPABASE) stop
