SHELL := /bin/bash

SUPABASE ?= supabase
DENO ?= deno
FUNCTIONS_ENV ?= supabase/functions/.env.local
CHECK_BACKEND = SUPABASE_BIN="$(SUPABASE)" ./scripts/check-backend-prerequisites.sh
FUNCTION_ENTRIES = \
	supabase/functions/delete-account/index.ts \
	supabase/functions/send-invitation/index.ts \
	supabase/functions/ocr-receipt/index.ts \
	supabase/functions/parse-receipt/index.ts \
	supabase/functions/suggest-itinerary/index.ts

.PHONY: help backend-up backend-status backend-reset backend-test functions-check functions-unit-test functions-serve functions-test backend-down

help:
	@echo "TripSplit local backend commands:"
	@echo "  make backend-up       Start local Supabase"
	@echo "  make backend-status   Show local service URLs and health"
	@echo "  make backend-reset    Rebuild the local database from migrations"
	@echo "  make backend-test     Run PostgreSQL security tests"
	@echo "  make functions-check  Type-check every Edge Function with Deno"
	@echo "  make functions-unit-test  Test request timing without providers"
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

functions-check:
	@command -v "$(DENO)" >/dev/null 2>&1 || { echo "error: Deno is unavailable. Install it or set DENO=/path/to/deno." >&2; exit 1; }
	$(DENO) check $(FUNCTION_ENTRIES)

functions-unit-test:
	$(DENO) test supabase/functions/_shared/request-timing_test.ts

functions-serve:
	@$(CHECK_BACKEND)
	@test -f "$(FUNCTIONS_ENV)" || { echo "error: missing $(FUNCTIONS_ENV)" >&2; exit 1; }
	$(SUPABASE) functions serve --env-file "$(FUNCTIONS_ENV)"

functions-test:
	@SUPABASE_BIN="$(SUPABASE)" FUNCTIONS_ENV="$(FUNCTIONS_ENV)" ./scripts/test-edge-functions.sh

backend-down:
	@$(CHECK_BACKEND)
	$(SUPABASE) stop
