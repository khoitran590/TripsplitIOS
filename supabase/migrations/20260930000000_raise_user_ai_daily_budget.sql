-- A single planner draft reserves 150 cents per Claude turn (up to two with a resumed
-- web search), so the 500-cent per-user cap allowed about one draft a day and then
-- denied every planner request until midnight UTC. Global caps are unchanged.
alter table public.ai_budget_settings alter column user_daily_cents set default 2000;
update public.ai_budget_settings set user_daily_cents = 2000 where id and user_daily_cents < 2000;
