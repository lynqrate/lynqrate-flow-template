begin;

-- A) 기존 데이터 NULL 보정
update public.analysis_requests set analysis_text = coalesce(analysis_text, '');
update public.analysis_requests set model        = coalesce(model, 'gpt-3.5-turbo');
update public.analysis_requests set token_used   = coalesce(token_used, 0);

-- B) 기본값/NOT NULL 보장
alter table public.analysis_requests
  alter column analysis_text set default '',
  alter column analysis_text set not null,
  alter column model set not null,
  alter column token_used set default 0,
  alter column token_used set not null,
  alter column created_at set default now(),
  alter column updated_at set default now();

-- C) status 허용값 체크
do $$
begin
  if not exists (select 1 from pg_constraint where conname='chk_analysis_requests_status_allowed') then
    alter table public.analysis_requests
      add constraint chk_analysis_requests_status_allowed
      check (status in ('pending','done'));
  end if;
end$$;

-- D) scope XOR 규칙 (pass/user_all 상호배타)
do $$
begin
  if exists (select 1 from pg_constraint where conname='analysis_requests_scope_xor') then
    alter table public.analysis_requests drop constraint analysis_requests_scope_xor;
  end if;

  alter table public.analysis_requests
    add constraint analysis_requests_scope_xor
    check (
      (scope='pass'     and user_pass_id is not null and user_id is null) or
      (scope='user_all' and user_id      is not null and user_pass_id is null)
    );
end$$;

-- E) FK 보강 (ON DELETE SET NULL)
do $$
begin
  if not exists (select 1 from pg_constraint where conname='fk_ar_user_id_users') then
    alter table public.analysis_requests
      add constraint fk_ar_user_id_users
      foreign key (user_id) references public.users(id)
      on delete set null;
  end if;

  if not exists (select 1 from pg_constraint where conname='fk_ar_user_pass_id_user_passes') then
    alter table public.analysis_requests
      add constraint fk_ar_user_pass_id_user_passes
      foreign key (user_pass_id) references public.user_passes(id)
      on delete set null;
  end if;
end$$;

-- F) 부분 유니크: 같은 패스에 pending 1개, done 1개
create unique index if not exists uq_ar_pass_done
  on public.analysis_requests(user_pass_id)
  where scope='pass' and status='done';

create unique index if not exists uq_ar_pass_pending
  on public.analysis_requests(user_pass_id)
  where scope='pass' and status='pending';

-- G) 함수 보강: 패스 종료 시 done 티켓 1건 멱등 생성(+carryover_digest)
create or replace function public.upsert_entry_decrement_and_link(
  p_sid            text,
  p_user_pass_id   uuid,
  p_entry          jsonb,
  p_ip             inet  default null,
  p_user_agent     text  default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now             timestamptz := now();
  v_state           text;
  v_linked_id       uuid;
  v_user_id         uuid;
  v_remaining       int;
  v_entry_id        uuid;
  v_std_id          uuid;
  v_remaining_after int;
  v_digest          text;
  v_created_done    boolean := false;
  v_rows int;
begin
  -- 필수 파라미터
  if p_sid is null or p_user_pass_id is null then
    return jsonb_build_object('status','error','reason','missing_sid_or_pass');
  end if;

  -- 제출 상태 확인/잠금
  select submit_status, emotion_entry_id
    into v_state, v_linked_id
  from public.submission_state
  where sid = p_sid
  for update;

  if v_state is null then
    return jsonb_build_object('status','error','reason','sid_not_found');
  end if;
  if v_linked_id is not null then
    return jsonb_build_object('status','skipped','entry_id', v_linked_id);
  end if;
  if v_state <> 'ready' then
    return jsonb_build_object('status','error','reason','bad_state');
  end if;

  -- 패스 잔여 잠금 로드
  select up.user_id, coalesce(up.remaining_uses,0)
    into v_user_id, v_remaining
  from public.user_passes up
  where up.id = p_user_pass_id
  for update;

  if v_user_id is null then
    return jsonb_build_object('status','error','reason','user_id_null');
  end if;
  if v_remaining <= 0 then
    return jsonb_build_object('status','error','reason','no_remaining');
  end if;

  -- 필수 입력 검증
  if coalesce(p_entry->>'raw_emotion','')='' or
     coalesce(p_entry->>'situation_raw','')='' or
     coalesce(p_entry->>'journal_raw','')='' or
     coalesce(p_entry#>>'{labels,level}','')='' or
     coalesce(p_entry#>>'{labels,feedback_type}','')='' or
     coalesce(p_entry#>>'{labels,speech}','')='' then
    return jsonb_build_object('status','error','reason','missing_required_fields');
  end if;

  -- standard_emotion_id UUID 캐스팅
  if (p_entry ? 'standard_emotion_id')
     and jsonb_typeof(p_entry->'standard_emotion_id')='string'
     and nullif(p_entry->>'standard_emotion_id','') is not null then
    v_std_id := (p_entry->>'standard_emotion_id')::uuid;
  else
    v_std_id := null;
  end if;

  -- 엔트리 INSERT
  insert into public.emotion_entries(
    id, user_pass_id, user_id,
    raw_emotion_text,
    supposed_emotion_text,
    standard_emotion_id,
    standard_emotion_reasoning,
    situation_raw_text, situation_summary_text,
    journal_raw_text,   journal_summary_text,
    emotion_level_label_snapshot,
    feedback_type_label_snapshot,
    feedback_speech_label_snapshot,
    is_feedback_generated,
    created_at
  ) values (
    gen_random_uuid(),
    p_user_pass_id, v_user_id,
    p_entry->>'raw_emotion',
    nullif(p_entry->>'supposed_emotion',''),
    v_std_id,
    nullif(p_entry->>'standard_emotion_reasoning',''),
    p_entry->>'situation_raw', nullif(p_entry->>'situation_summary',''),
    p_entry->>'journal_raw',   nullif(p_entry->>'journal_summary',''),
    p_entry#>>'{labels,level}',
    p_entry#>>'{labels,feedback_type}',
    p_entry#>>'{labels,speech}',
    false,
    v_now
  )
  returning id into v_entry_id;

  -- 회차 차감 + 최초 사용 시각
  update public.user_passes
     set remaining_uses = v_remaining - 1,
         first_used_at  = coalesce(first_used_at, v_now),
         updated_at     = v_now
   where id = p_user_pass_id
  returning remaining_uses into v_remaining_after;

  -- 패스 종료 → analysis_requests(scope='pass', status='done') 멱등 생성
  if v_remaining_after = 0 then
    select digest_text into v_digest
    from public.pass_rollup_digests
    where user_pass_id = p_user_pass_id;

    insert into public.analysis_requests(
      user_pass_id, scope, status, reason,
      analysis_text, stats_json, model, token_used
    ) values (
      p_user_pass_id, 'pass', 'done', null,
      '',
      case when coalesce(v_digest,'')<>'' 
        then jsonb_build_object('carryover_digest', v_digest) 
        else null end,
      'gpt-3.5-turbo', 0
    )
    on conflict on constraint uq_ar_pass_done do nothing;

    get diagnostics v_rows = row_count;
    v_created_done := (v_rows > 0);
  end if;

  -- 링크 + 로그 캡
  update public.submission_state
     set emotion_entry_id = v_entry_id,
         status_log = concat_ws(' | ', nullif(status_log,''),
                  format('entry_linked=%s ts=%s', v_entry_id, to_char(v_now,'YYYY-MM-DD HH24:MI:SS'))),
         updated_at = v_now
   where sid = p_sid;

  update public.submission_state
     set status_log = right(status_log, 4000)
   where sid = p_sid;

  return jsonb_build_object(
    'status','ok',
    'entry_id', v_entry_id,
    'remaining_uses_after', v_remaining_after,
    'pass_done_created', coalesce(v_created_done,false)
  );
end;
$$;

commit;