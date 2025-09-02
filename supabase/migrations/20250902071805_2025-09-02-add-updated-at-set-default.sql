begin;

alter table public.user_passes
  add column if not exists updated_at timestamptz not null default now();

-- 기존 null 보정 (혹시 모르니까)
update public.user_passes
   set updated_at = now()
 where updated_at is null;

commit;