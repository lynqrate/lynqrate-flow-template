begin;

-- user_passes.updated_at 컬럼 추가
alter table public.user_passes
  add column if not exists updated_at timestamptz;

-- 기본값 채우기
update public.user_passes
   set updated_at = now()
 where updated_at is null;

commit;