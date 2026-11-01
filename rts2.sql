-- 「リア友なし版」の世界を、みんなで遊べるようにする追加SQL（Supabase の SQL Editor で1回だけ実行。rts.sql のあとに）
alter table public.rts drop constraint if exists rts_id_check;
alter table public.rts add constraint rts_id_check check (id in (1, 2, 3, 4));  -- 3: リア友なし版の状態  4: 資源と魔物
insert into public.rts (id) values (3), (4) on conflict (id) do nothing;
alter table public.rts_cmd add column if not exists w int not null default 1;

create or replace function public.rts_claim_w(p_who text, p_name text, p_sec int, p_w int)
returns table(ok boolean, ver bigint, host_name text, lock_until timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare rid int := case when p_w = 2 then 3 else 1 end;
begin
  update public.rts
     set host = p_who, host_name = left(p_name, 24),
         lock_until = now() + make_interval(secs => least(greatest(p_sec, 5), 120))
   where id = rid and (rts.host = p_who or rts.lock_until < now());
  return query select (s.host = p_who and s.lock_until > now()), s.ver, s.host_name, s.lock_until
                 from public.rts s where s.id = rid;
end $$;

create or replace function public.rts_push_w(p_who text, p_ver bigint, p_state jsonb, p_upto bigint, p_id int, p_w int)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint; lk int := case when p_w = 2 then 3 else 1 end;
begin
  if octet_length(p_state::text) > 4000000 then raise exception 'state too large'; end if;
  if p_id not in (3, 4) then return -1; end if;
  if not exists (select 1 from public.rts where id = lk and host = p_who and lock_until > now()) then return -1; end if;
  update public.rts
     set state = p_state, ver = rts.ver + 1, updated_at = now()
   where id = p_id and (p_id = 4 or rts.ver = p_ver)
  returning rts.ver into v;
  if p_upto > 0 then delete from public.rts_cmd where id <= p_upto and w = p_w; end if;
  delete from public.rts_cmd where at < now() - interval '1 hour';
  return coalesce(v, -1);
end $$;

create or replace function public.rts_cmd_add_w(p_who text, p_name text, p_cmd jsonb, p_w int)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if octet_length(p_cmd::text) > 4000 then raise exception 'command too large'; end if;
  insert into public.rts_cmd (who, name, cmd, w) values (left(p_who, 64), left(p_name, 24), p_cmd, p_w) returning id into v;
  return v;
end $$;

-- 通常版の命令だけを消すように直す（リア友なし版の命令を巻き込まない）
create or replace function public.rts_push(p_who text, p_ver bigint, p_state jsonb, p_upto bigint, p_id int)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if octet_length(p_state::text) > 4000000 then raise exception 'state too large'; end if;
  if p_id not in (1, 2) then return -1; end if;
  if not exists (select 1 from public.rts where id = 1 and host = p_who and lock_until > now()) then return -1; end if;
  update public.rts
     set state = p_state, ver = rts.ver + 1, updated_at = now()
   where id = p_id and (p_id = 2 or rts.ver = p_ver)
  returning rts.ver into v;
  if p_upto > 0 then delete from public.rts_cmd where id <= p_upto and w = 1; end if;
  delete from public.rts_cmd where at < now() - interval '1 hour';
  return coalesce(v, -1);
end $$;

grant execute on function public.rts_claim_w(text, text, int, int), public.rts_push_w(text, bigint, jsonb, bigint, int, int), public.rts_cmd_add_w(text, text, jsonb, int) to anon, authenticated;
