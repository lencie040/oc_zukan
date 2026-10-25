-- 全界戦記をみんなで遊ぶための表（Supabase の SQL Editor で1回だけ実行）
create table if not exists public.rts (
  id int primary key check (id in (1, 2)),   -- 1: 世界の状態  2: 資源と魔物（重いので別）
  ver bigint not null default 0,
  state jsonb,
  host text,
  host_name text,
  lock_until timestamptz not null default to_timestamp(0),
  updated_at timestamptz not null default now()
);
insert into public.rts (id) values (1), (2) on conflict (id) do nothing;

-- 命令の受付箱（だれでも入れられる。進行役が処理して消す）
create table if not exists public.rts_cmd (
  id bigserial primary key,
  at timestamptz not null default now(),
  who text not null,
  name text,
  cmd jsonb not null
);

alter table public.rts enable row level security;
alter table public.rts_cmd enable row level security;
drop policy if exists "rts read" on public.rts;
create policy "rts read" on public.rts for select to anon, authenticated using (true);
drop policy if exists "rts_cmd read" on public.rts_cmd;
create policy "rts_cmd read" on public.rts_cmd for select to anon, authenticated using (true);
grant select on public.rts, public.rts_cmd to anon, authenticated;

-- 進行役になる（同時に1人だけ。30秒ごとに更新しないと次の人に交代）
create or replace function public.rts_claim(p_who text, p_name text, p_sec int default 30)
returns table(ok boolean, ver bigint, host_name text, lock_until timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  update public.rts
     set host = p_who, host_name = left(p_name, 24),
         lock_until = now() + make_interval(secs => least(greatest(p_sec, 5), 120))
   where id = 1 and (rts.host = p_who or rts.lock_until < now());
  return query select (s.host = p_who and s.lock_until > now()), s.ver, s.host_name, s.lock_until
                 from public.rts s where s.id = 1;
end $$;

-- 状態を書き込む（進行役だけ）。p_upto までの命令は処理済みとして消す
create or replace function public.rts_push(p_who text, p_ver bigint, p_state jsonb, p_upto bigint, p_id int)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if octet_length(p_state::text) > 4000000 then raise exception 'state too large'; end if;
  if not exists (select 1 from public.rts where id = 1 and host = p_who and lock_until > now()) then return -1; end if;
  update public.rts
     set state = p_state, ver = rts.ver + 1, updated_at = now()
   where id = p_id and (p_id = 2 or rts.ver = p_ver)
  returning rts.ver into v;
  if p_upto > 0 then delete from public.rts_cmd where id <= p_upto; end if;
  delete from public.rts_cmd where at < now() - interval '1 hour';
  return coalesce(v, -1);
end $$;

-- 命令を送る（だれでも）
create or replace function public.rts_cmd_add(p_who text, p_name text, p_cmd jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if octet_length(p_cmd::text) > 4000 then raise exception 'command too large'; end if;
  insert into public.rts_cmd (who, name, cmd) values (left(p_who, 64), left(p_name, 24), p_cmd) returning id into v;
  return v;
end $$;

grant execute on function public.rts_claim(text, text, int), public.rts_push(text, bigint, jsonb, bigint, int), public.rts_cmd_add(text, text, jsonb) to anon, authenticated;
