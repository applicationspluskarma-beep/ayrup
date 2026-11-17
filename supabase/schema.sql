-- ayrup prototype — Supabase schema
-- Run once in Supabase: SQL Editor → New query → paste → Run.
-- Tables are closed to the public (RLS on, no policies). The page talks to the
-- database only through the functions below, which check secret tokens.

create extension if not exists pgcrypto;

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null,
  email text not null,
  org text,
  consent boolean not null,
  source text not null check (source in ('pilot','crew')),
  token uuid not null default gen_random_uuid() unique,
  wants_expert boolean not null default false,
  expert_note text
);

create table if not exists public.flights (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  pilot_id uuid not null references public.leads(id) on delete cascade,
  project text not null,
  profile text not null check (profile in ('A','B','V','G')),
  orgtype text not null check (orgtype in ('ngo','biz','init')),
  crew_size int not null check (crew_size between 1 and 20),
  deadline timestamptz not null,
  closed boolean not null default false
);

create table if not exists public.members (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  flight_id uuid not null references public.flights(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete set null,
  name text not null,
  role text not null,
  is_pilot boolean not null default false,
  token uuid not null default gen_random_uuid() unique,
  answers jsonb,
  finished_at timestamptz
);

alter table public.leads enable row level security;
alter table public.flights enable row level security;
alter table public.members enable row level security;

-- Helpful view for you in the dashboard (not exposed to the page)
create or replace view public.leads_export as
  select l.created_at, l.name, l.email, l.org, l.source, l.wants_expert, l.expert_note,
         f.project, f.profile, f.orgtype
  from public.leads l
  left join public.members m on m.lead_id = l.id
  left join public.flights f on f.id = m.flight_id;
revoke all on public.leads_export from anon, authenticated;

-- Registration of a pilot
create or replace function public.ayrup_register(p_name text, p_email text, p_org text, p_consent boolean)
returns json language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if not p_consent then raise exception 'Потрібна згода на обробку даних'; end if;
  if length(trim(p_name)) = 0 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Перевірте ім''я та пошту'; end if;
  insert into leads(name,email,org,consent,source) values (left(trim(p_name),120), lower(left(trim(p_email),200)), left(p_org,200), true, 'pilot')
  returning token into t;
  return json_build_object('token', t);
end $$;

create or replace function public.ayrup_create_flight(p_token uuid, p_project text, p_profile text, p_orgtype text, p_role text, p_window int, p_crew_size int)
returns json language plpgsql security definer set search_path = public as $$
declare l leads; fid uuid; mt uuid;
begin
  select * into l from leads where token = p_token and source = 'pilot';
  if l.id is null then raise exception 'Сесію не знайдено, зареєструйтесь ще раз'; end if;
  insert into flights(pilot_id,project,profile,orgtype,crew_size,deadline)
  values (l.id, left(trim(p_project),160), p_profile, p_orgtype, p_crew_size, now() + make_interval(hours => least(greatest(p_window,1),168)))
  returning id into fid;
  insert into members(flight_id,lead_id,name,role,is_pilot) values (fid, l.id, l.name, p_role, true) returning token into mt;
  return json_build_object('flightId', fid, 'memberToken', mt);
end $$;

create or replace function public._ayrup_pub(p_flight uuid)
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'id', f.id, 'project', f.project, 'profile', f.profile, 'orgtype', f.orgtype,
    'crewSize', f.crew_size, 'deadline', (extract(epoch from f.deadline)*1000)::bigint, 'closed', f.closed,
    'pilotName', (select name from leads where id = f.pilot_id),
    'members', coalesce((select json_agg(json_build_object('name', m.name, 'role', m.role, 'pilot', m.is_pilot, 'finished', m.finished_at is not null) order by m.created_at)
                from members m where m.flight_id = f.id), '[]'::json))
  from flights f where f.id = p_flight;
$$;

create or replace function public.ayrup_flight_public(p_flight uuid)
returns json language sql security definer set search_path = public as $$ select public._ayrup_pub(p_flight) $$;

create or replace function public.ayrup_list_flights(p_token uuid)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(public._ayrup_pub(f.id) order by f.created_at desc), '[]'::json)
  from flights f join leads l on l.id = f.pilot_id where l.token = p_token;
$$;

create or replace function public.ayrup_join(p_flight uuid, p_name text, p_email text, p_role text, p_consent boolean)
returns json language plpgsql security definer set search_path = public as $$
declare lid uuid; mt uuid;
begin
  if not p_consent then raise exception 'Потрібна згода на обробку даних'; end if;
  if not exists (select 1 from flights where id = p_flight) then raise exception 'Рейс не знайдено. Перевірте посилання.'; end if;
  insert into leads(name,email,consent,source) values (left(trim(p_name),120), lower(left(trim(p_email),200)), true, 'crew') returning id into lid;
  insert into members(flight_id,lead_id,name,role) values (p_flight, lid, left(trim(p_name),120), p_role) returning token into mt;
  return json_build_object('memberToken', mt);
end $$;

create or replace function public.ayrup_submit(p_member_token uuid, p_answers jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update members set answers = p_answers, finished_at = now() where token = p_member_token and finished_at is null;
  if not found then raise exception 'Учасника не знайдено або відповіді вже надіслано'; end if;
  return true;
end $$;

create or replace function public.ayrup_close_flight(p_token uuid, p_flight uuid)
returns boolean language sql security definer set search_path = public as $$
  update flights f set closed = true from leads l where f.id = p_flight and l.id = f.pilot_id and l.token = p_token returning true;
$$;

create or replace function public.ayrup_results(p_flight uuid, p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare f flights; ok boolean; done int; unlocked boolean;
begin
  select * into f from flights where id = p_flight;
  if f.id is null then raise exception 'Рейс не знайдено'; end if;
  ok := exists (select 1 from leads where id = f.pilot_id and token = p_token)
     or exists (select 1 from members where flight_id = p_flight and token = p_token);
  if not ok then raise exception 'Немає доступу до результатів цього рейсу'; end if;
  select count(*) into done from members where flight_id = p_flight and finished_at is not null;
  unlocked := f.closed or now() > f.deadline or done >= f.crew_size;
  return json_build_object('flight', public._ayrup_pub(p_flight), 'unlocked', unlocked,
    'members', case when unlocked then coalesce((select json_agg(json_build_object('name', name, 'role', role, 'pilot', is_pilot, 'answers', answers) order by created_at)
                 from members where flight_id = p_flight and finished_at is not null), '[]'::json) else '[]'::json end);
end $$;

create or replace function public.ayrup_request_expert(p_token uuid, p_flight uuid, p_message text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update leads set wants_expert = true, expert_note = left(coalesce(p_message,''),500)
  where token = p_token
     or id = (select lead_id from members where token = p_token and flight_id = p_flight);
  return true;
end $$;

revoke all on function public._ayrup_pub(uuid) from public, anon, authenticated;
grant execute on function public.ayrup_register(text,text,text,boolean) to anon;
grant execute on function public.ayrup_create_flight(uuid,text,text,text,text,int,int) to anon;
grant execute on function public.ayrup_flight_public(uuid) to anon;
grant execute on function public.ayrup_list_flights(uuid) to anon;
grant execute on function public.ayrup_join(uuid,text,text,text,boolean) to anon;
grant execute on function public.ayrup_submit(uuid,jsonb) to anon;
grant execute on function public.ayrup_close_flight(uuid,uuid) to anon;
grant execute on function public.ayrup_results(uuid,uuid) to anon;
grant execute on function public.ayrup_request_expert(uuid,uuid,text) to anon;
