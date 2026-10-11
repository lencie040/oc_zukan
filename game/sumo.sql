-- 番付戦の共有データ（1行だけの表）
create table if not exists public.sumo (
  id int primary key default 1 check (id = 1),
  ver bigint not null default 0,
  state jsonb,
  runner text,
  runner_name text,
  lock_until timestamptz not null default to_timestamp(0),
  updated_at timestamptz not null default now()
);
insert into public.sumo (id) values (1) on conflict (id) do nothing;

-- 読むのは誰でもOK、書き込みは下の関数からだけ
alter table public.sumo enable row level security;
drop policy if exists "sumo read" on public.sumo;
create policy "sumo read" on public.sumo for select to anon, authenticated using (true);
grant select on public.sumo to anon, authenticated;

-- 進める権利（同時に1人だけ・60秒ごとに更新）
create or replace function public.sumo_claim(p_who text, p_name text, p_sec int default 60)
returns table(ok boolean, ver bigint, runner_name text, lock_until timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  update public.sumo
     set runner = p_who, runner_name = left(p_name, 24),
         lock_until = now() + make_interval(secs => least(greatest(p_sec, 5), 120))
   where id = 1 and (sumo.runner = p_who or sumo.lock_until < now());
  return query select (s.runner = p_who and s.lock_until > now()), s.ver, s.runner_name, s.lock_until
                 from public.sumo s where s.id = 1;
end $$;

create or replace function public.sumo_release(p_who text)
returns void language sql security definer set search_path = public as $$
  update public.sumo set lock_until = to_timestamp(0) where id = 1 and runner = p_who;
$$;

-- 結果の書き込み（権利を持っていて、版が合っているときだけ）
create or replace function public.sumo_push(p_who text, p_ver bigint, p_state jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if octet_length(p_state::text) > 3000000 then raise exception 'state too large'; end if;
  update public.sumo
     set state = p_state, ver = sumo.ver + 1, updated_at = now(),
         lock_until = greatest(sumo.lock_until, now() + interval '60 seconds')
   where id = 1 and sumo.runner = p_who and sumo.lock_until > now() and sumo.ver = p_ver
  returning sumo.ver into v;
  return coalesce(v, -1);
end $$;

grant execute on function public.sumo_claim(text, text, int), public.sumo_release(text), public.sumo_push(text, bigint, jsonb) to anon, authenticated;
