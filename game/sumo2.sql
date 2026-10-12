-- 全員番付（2つ目の番付）を共有できるようにする
alter table public.sumo drop constraint if exists sumo_id_check;
alter table public.sumo add constraint sumo_id_check check (id in (1, 2));
insert into public.sumo (id) values (2) on conflict (id) do nothing;

create or replace function public.sumo_claim(p_who text, p_name text, p_sec int, p_id int)
returns table(ok boolean, ver bigint, runner_name text, lock_until timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  update public.sumo
     set runner = p_who, runner_name = left(p_name, 24),
         lock_until = now() + make_interval(secs => least(greatest(p_sec, 5), 120))
   where id = p_id and (sumo.runner = p_who or sumo.lock_until < now());
  return query select (s.runner = p_who and s.lock_until > now()), s.ver, s.runner_name, s.lock_until
                 from public.sumo s where s.id = p_id;
end $$;

create or replace function public.sumo_release(p_who text, p_id int)
returns void language sql security definer set search_path = public as $$
  update public.sumo set lock_until = to_timestamp(0) where id = p_id and runner = p_who;
$$;

create or replace function public.sumo_push(p_who text, p_ver bigint, p_state jsonb, p_id int)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if octet_length(p_state::text) > 3000000 then raise exception 'state too large'; end if;
  update public.sumo
     set state = p_state, ver = sumo.ver + 1, updated_at = now(),
         lock_until = greatest(sumo.lock_until, now() + interval '60 seconds')
   where id = p_id and sumo.runner = p_who and sumo.lock_until > now() and sumo.ver = p_ver
  returning sumo.ver into v;
  return coalesce(v, -1);
end $$;

grant execute on function public.sumo_claim(text, text, int, int), public.sumo_release(text, int), public.sumo_push(text, bigint, jsonb, int) to anon, authenticated;
notify pgrst, 'reload schema';
