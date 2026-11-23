-- The Wrong Number Job: live stats backend (Supabase / Postgres).
-- Paste this whole file into Supabase: SQL Editor -> New query -> Run.
--
-- Design:
--   * One append-only table of anonymous game events.
--   * The public (the "anon" role behind the publishable key) may INSERT events and nothing else:
--     it cannot read, change or delete rows.
--   * Three read-only functions return totals only (never raw rows), for the game and the public dashboard.
--   * No personal data: no names, no job titles as typed (only the mission type), no IP addresses.

create table if not exists public.events (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  session_id    uuid        not null,
  event         text        not null check (event in ('visit', 'start', 'finish', 'copy_post', 'open_linkedin', 'suggest_trap', 'star_click', 'open_stats')),
  source        text        check (source ~ '^[a-z0-9_-]{1,40}$'),
  mission       text        check (mission ~ '^[a-z-]{1,30}$'),
  score         integer     check (score between -100000 and 100000),
  caught        smallint    check (caught between 0 and 500),
  leaked        smallint    check (leaked between 0 and 5),
  false_blocks  smallint    check (false_blocks between 0 and 500),
  answered      smallint    check (answered between 0 and 500),
  busted        boolean,
  misses        text[]      check (cardinality(misses) <= 60),
  constraint finish_has_result check (event <> 'finish' or (
    mission is not null and busted is not null and score is not null
    and caught is not null and leaked is not null and false_blocks is not null and answered is not null)),
  -- A finished game's score must add up from its own counts (+100 block wrong, +50 ship right,
  -- -150 ship wrong, -50 block right), so a hand-made fake score is rejected.
  constraint finish_score_adds_up check (event <> 'finish' or (
    answered >= caught + leaked + false_blocks
    and score = 100 * caught + 50 * (answered - caught - leaked - false_blocks) - 150 * leaked - 50 * false_blocks))
);


create index if not exists events_event_created_idx on public.events (event, created_at);

alter table public.events enable row level security;

-- Anyone may add an event; nobody outside the database owner may read or change rows.
drop policy if exists "public can add events" on public.events;
create policy "public can add events" on public.events for insert to anon, authenticated with check (true);

revoke all on table public.events from anon, authenticated;
grant insert (session_id, event, source, mission, score, caught, leaked, false_blocks, answered, busted, misses)
  on table public.events to anon, authenticated;

-- Small summary for the game screen.
create or replace function public.game_summary()
returns json
language sql stable security definer
set search_path = public
as $$
  with f as (select busted, misses from public.events where event = 'finish')
  select json_build_object(
    'players',    (select count(*) from f),
    'busted_pct', (select round(100.0 * avg(case when busted then 1 else 0 end)) from f),
    'top_miss',   (select m from f cross join lateral unnest(f.misses) as m group by m order by count(*) desc, m limit 1)
  );
$$;

-- Share of finished games with a lower score than p_score (null until 5 games exist).
create or replace function public.beat_pct(p_score integer)
returns integer
language sql stable security definer
set search_path = public
as $$
  select case when count(*) < 5 then null
              else round(100.0 * count(*) filter (where score < p_score) / count(*))::integer end
  from public.events where event = 'finish';
$$;

-- Everything the public dashboard shows, as one JSON document.
-- People are counted as distinct sessions (one browser tab visit); games are counted one per finished game.
create or replace function public.dashboard()
returns json
language sql stable security definer
set search_path = public
as $$
  select json_build_object(
    'updated_at', now(),
    'since', (select min(created_at) from public.events),
    'funnel', (
      select json_build_object(
        'visits',    count(distinct session_id) filter (where event = 'visit'),
        'starts',    count(distinct session_id) filter (where event = 'start'),
        'finishers', count(distinct session_id) filter (where event = 'finish'),
        'shares',    count(distinct session_id) filter (where event in ('copy_post', 'open_linkedin')),
        'games',     count(*)                   filter (where event = 'finish')
      ) from public.events),
    'outcomes', (
      select json_build_object(
        'busted',       count(*) filter (where busted),
        'passed',       count(*) filter (where not busted),
        'avg_score',    round(avg(score)),
        'median_score', percentile_cont(0.5) within group (order by score),
        'avg_answered', round(avg(answered), 1)
      ) from public.events where event = 'finish'),
    'sources', (
      select coalesce(json_agg(s order by s.visits desc, s.source), '[]'::json) from (
        select coalesce(source, 'direct') as source,
               count(distinct session_id) filter (where event = 'visit') as visits,
               count(distinct session_id) filter (where event = 'finish') as players,
               count(distinct session_id) filter (where event in ('copy_post', 'open_linkedin')) as shares,
               count(*) filter (where event = 'finish') as games
        from public.events group by 1
      ) s),
    'hourly', (
      select coalesce(json_agg(h order by h.hour), '[]'::json) from (
        select date_trunc('hour', created_at) as hour,
               count(distinct session_id) filter (where event = 'visit') as visits,
               count(*) filter (where event = 'finish') as games
        from public.events
        where created_at > now() - interval '7 days'
        group by 1
      ) h),
    'misses', (
      select coalesce(json_agg(x order by x.n desc, x.card), '[]'::json) from (
        select m as card, count(*) as n
        from public.events e cross join lateral unnest(e.misses) as m
        where e.event = 'finish'
        group by m
        order by count(*) desc, m
        limit 10
      ) x),
    'missions', (
      select coalesce(json_agg(y order by y.n desc, y.mission), '[]'::json) from (
        select mission, count(*) as n, round(avg(score)) as avg_score
        from public.events where event = 'finish' group by mission
      ) y)
  );
$$;

revoke all on function public.game_summary(), public.beat_pct(integer), public.dashboard() from public;
grant execute on function public.game_summary(), public.beat_pct(integer), public.dashboard() to anon, authenticated;
