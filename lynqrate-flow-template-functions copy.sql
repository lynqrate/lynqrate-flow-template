create or replace function update_submission_tables(
  p_user_pass_id uuid,
  p_entry_id uuid
)
returns void
language plpgsql
security definer
as $$
begin
  -- submission_state 업데이트
  update submission_state
     set emotion_entry_id = p_entry_id,
         updated_at = now()
   where user_pass_id = p_user_pass_id;

  -- submission_history 업데이트
  update submission_history
     set emotion_entry_id = p_entry_id
   where user_pass_id = p_user_pass_id;
end;
$$;

grant execute on function update_submission_tables(uuid,uuid) to service_role;




create or replace function public.upsert_pass_rollup_digest(
  p_user_pass_id uuid,
  p_digest_text  text
)
returns table (
  id uuid,
  user_pass_id uuid,
  digest_text text,
  last_entry_no integer,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
as $$
begin
  return query
  insert into public.pass_rollup_digests as d (user_pass_id, digest_text, last_entry_no)
  values (p_user_pass_id, p_digest_text, 1)
  on conflict (user_pass_id) do update
    set digest_text   = excluded.digest_text,
        last_entry_no = d.last_entry_no + 1,
        updated_at    = now()
  returning d.id, d.user_pass_id, d.digest_text, d.last_entry_no, d.created_at, d.updated_at;
end;
$$;




-- emotion_entries.id 와 submission_state.sid 를 함께 받아서
-- 피드백 생성 플래그 + 제출 상태(done) 를 한 번에 업데이트
create or replace function public.mark_feedback_and_done(
  p_entry_id uuid,
  p_sid text
)
returns table (
  entry_id uuid,
  entry_flag_before boolean,
  entry_flag_after  boolean,
  sid text,
  state_before text,
  state_after  text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flag_before boolean;
  v_state_before text;
begin
  -- 현재 상태 스냅샷
  select is_feedback_generated into v_flag_before
  from public.emotion_entries
  where id = p_entry_id
  for update;  -- 동시성 방지

  select submit_status into v_state_before
  from public.submission_state
  where sid = p_sid
  for update;

  -- 1) entry 플래그 true (멱등)
  update public.emotion_entries
     set is_feedback_generated = true,
         feedback_generated_at = coalesce(feedback_generated_at, now())
   where id = p_entry_id;

  -- 2) submission_state 를 done 으로 (멱등)
  update public.submission_state
     set submit_status = 'done',
         updated_at    = now()
   where sid = p_sid
     and submit_status <> 'done';

  -- 결과 반환
  return query
  select
    e.id as entry_id,
    v_flag_before as entry_flag_before,
    e.is_feedback_generated as entry_flag_after,
    s.sid,
    v_state_before as state_before,
    s.submit_status as state_after,
    s.updated_at
  from public.emotion_entries e
  join public.submission_state s on s.sid = p_sid
  where e.id = p_entry_id;
end;
$$;




create or replace function bind_user_to_pass_simple(
  p_sid text, p_uuid text, p_email text
) returns table (ok boolean, reason text, user_pass_id uuid, user_id uuid)
language plpgsql security definer as $$
declare v_pass_id uuid; v_user_id uuid;
begin
  select id, user_id 
  into v_pass_id, v_user_id
  from user_passes 
  where uuid_code=p_uuid 
  for update;

  if v_pass_id is null then 
    return query select false,'not_found',null,null; 
    return; 
  end if;
  
  if v_user_id is not null then 
    return query select true,null,v_pass_id,v_user_id; 
    return; 
  end if;

  insert into users(is_guest) 
  values(true) returning id 
  into v_user_id;

  update user_passes 
  set user_id=v_user_id, updated_at=now() 
  where id=v_pass_id;
  
  return query select true,null,v_pass_id,v_user_id;
exception when others then return query select false,'exception',null,null; end;
$$;




create or replace function mark_feedback_and_done_simple(
  p_sid text, p_entry uuid
) returns table (ok boolean, reason text)
language plpgsql security definer as $$
declare v_up uuid;
begin
  select user_pass_id into v_up from submission_state where sid=p_sid for update;
  if v_up is null then return query select false,'not_found'; return; end if;

  update emotion_entries
     set is_feedback_generated=true, updated_at=now()
   where id=p_entry;

  update user_passes
     set remaining_uses = remaining_uses - 1, updated_at=now()
   where id=v_up and remaining_uses>0;
  if not found then return query select false,'no_uses'; return; end if;

  update submission_state
     set submit_status='done', emotion_entry_id=p_entry, updated_at=now()
   where sid=p_sid;

  return query select true,null;
exception when others then return query select false,'exception'; end;
$$;





-- 개시 + 상태/히스토리 기록 + 시드 주입을 원자적으로 수행
create or replace function seed_and_record_submission(
  p_sid text,
  p_uuid_code text,
  p_user_pass_id uuid,
  p_reason text,
  p_ip inet default null,
  p_user_agent text default null,
  p_latency_ms int default null,
  p_set_first_used_at boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_user_id uuid;
  v_first_used timestamptz;
  v_digest_exists boolean;
  v_prev_pass_id uuid;
  v_seed text := '';
  v_seed_source text := 'empty';
  v_status text := 'seeded';
  v_reason text := p_reason;
begin
  --------------------------------------------------------------------
  -- 0) 기본 검증: uuid_code ↔ user_pass 매칭
  --------------------------------------------------------------------
  perform 1 from user_passes up
   where up.id = p_user_pass_id and up.uuid_code = p_uuid_code and up.is_active = true;
  if not found then
    v_status := 'error'; v_reason := 'mismatch_or_inactive';
  end if;

  select user_id, first_used_at
    into v_user_id, v_first_used
  from user_passes where id = p_user_pass_id
  for share;

  if v_user_id is null then
    v_status := 'error'; v_reason := coalesce(v_reason,'user_id_null');
  end if;

  --------------------------------------------------------------------
  -- 1) submissions 테이블 처리 (업서트 + 히스토리)
  --------------------------------------------------------------------
  -- submission_state: ready로 업서트(이미 있으면 업데이트)
  insert into submission_state(sid, user_pass_id, uuid_code, submit_status, status_reason, updated_at)
  values (p_sid, p_user_pass_id, p_uuid_code, 'ready', 'validation_success', v_now)
  on conflict (sid) do update
     set user_pass_id = excluded.user_pass_id,
         uuid_code    = excluded.uuid_code,
         submit_status= 'ready',
         status_reason= 'validation_success',
         updated_at   = v_now;

  -- submission_history: 한 행 기록 (통과 시 pass, 오류면 fail)
  insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
  values (
    p_user_pass_id,
    p_uuid_code,
    case when v_status='error' then 'fail' else 'pass' end,
    COALESCE(v_reason, p_reason),
    p_ip, p_user_agent, p_latency_ms, v_now
  );

  if v_status = 'error' then
    -- 상태 로그만 남기고 에러 리턴
    update submission_state
       set status_reason = v_reason,
           status_log    = concat_ws(' | ', coalesce(status_log,''), format('8.5 rpc_status=%s reason=%s ts=%s', v_status, v_reason, to_char(v_now,'YYYY-MM-DD HH24:MI:SS'))),
           updated_at    = v_now
     where sid = p_sid;
    return jsonb_build_object('status', v_status, 'reason', v_reason);
  end if;

  --------------------------------------------------------------------
  -- 2) 시드 주입(멱등)
  --------------------------------------------------------------------
  select exists(select 1 from pass_rollup_digests where user_pass_id = p_user_pass_id)
    into v_digest_exists;

  if v_digest_exists or v_first_used is not null then
    v_status := 'skipped';
    v_reason := CASE
                WHEN v_digest_exists THEN 'digest_exists'
                ELSE 'already_used'
              END;
  else
    -- 직전 pass 찾기
    select up.id
      into v_prev_pass_id
    from user_passes up
    where up.user_id = v_user_id
      and up.id <> p_user_pass_id
    order by up.created_at desc
    limit 1;

    if v_prev_pass_id is not null then
      -- 1순위: carryover_digest
      select ar.stats_json->>'carryover_digest' into v_seed
      from analysis_requests ar
      where ar.user_pass_id = v_prev_pass_id and ar.scope='pass' and ar.status='done'
      order by ar.created_at desc limit 1;

      if v_seed is not null and length(v_seed)>0 then
        v_seed_source := 'carryover_digest';
      else
        -- 2순위: 직전 pass digest
        select prd.digest_text into v_seed
        from pass_rollup_digests prd
        where prd.user_pass_id = v_prev_pass_id;

        if v_seed is not null and length(v_seed)>0 then
          v_seed_source := 'prev_pass_digest';
        else
          v_seed := ''; v_seed_source := 'empty';
        end if;
      end if;
    end if;

    -- 새 pass digest 초기화
    insert into pass_rollup_digests(user_pass_id, digest_text, last_entry_no)
    values (p_user_pass_id, coalesce(v_seed,''), 0)
    on conflict (user_pass_id) do nothing;

    -- 첫 사용 시각(옵션)
    if p_set_first_used_at then
      update user_passes
         set first_used_at = v_now
       where id = p_user_pass_id and first_used_at is null;
    end if;
  end if;

  --------------------------------------------------------------------
  -- 3) 상태 로그 append
  --------------------------------------------------------------------
  UPDATE submission_state
  SET status_log = concat_ws(
      ' | ',
      NULLIF(status_log, ''),
      format('8.5 rpc_status=%s seed_source=%s prev_pass_id=%s ts=%s',
             v_status, v_seed_source, COALESCE(v_prev_pass_id::text,'-'), to_char(v_now,'YYYY-MM-DD HH24:MI:SS'))
    ),
    updated_at = v_now
  WHERE sid = p_sid;

  -- ✅ 로그 캡핑 추가
  update submission_state
   set status_log = right(status_log, 4000),
       updated_at = v_now
  where sid = p_sid;

  return jsonb_build_object(
    'status', v_status,
    'seed_source', v_seed_source,
    'prev_pass_id', v_prev_pass_id,
    'seed_len', coalesce(length(v_seed),0)
  );
end $$;





create or replace function get_rollup_context(
  p_user_pass_id uuid,
  p_limit int default 5
) returns jsonb
language sql
stable
set search_path = public
as $$
with pass_info as (
  select
    up.user_id,
    up.remaining_uses,
    p.total_uses,
    (p.total_uses - up.remaining_uses + 1) as entry_no_next
  from user_passes up
  join passes p on p.id = up.pass_id
  where up.id = p_user_pass_id
),
prd as (
  select digest_text, last_entry_no
  from pass_rollup_digests
  where user_pass_id = p_user_pass_id
),
-- 전체 개수
cnt as (
  select count(*)::int as total_cnt
  from emotion_entries
  where user_pass_id = p_user_pass_id
),
-- 최근 N개(감정명 조인)
lastn as (
  select
    e.id,
    e.situation_summary_text,
    e.journal_summary_text,
    e.created_at,
    e.standard_emotion_id,
    se.name as standard_emotion_name
  from emotion_entries e
  left join standard_emotions se
    on se.id = e.standard_emotion_id
  where e.user_pass_id = p_user_pass_id
  order by e.created_at desc
  limit p_limit
),
lastn_json as (
  select coalesce(
           (select jsonb_agg(to_jsonb(lastn) order by lastn.created_at desc) from lastn),
           '[]'::jsonb
         ) as arr
)
select jsonb_build_object(
  'user_id',        (select user_id from pass_info),
  'digest',         coalesce((select digest_text   from prd), ''),
  'last_entry_no',  coalesce((select last_entry_no from prd), 0),
  'digest_len',     coalesce(length((select digest_text from prd)), 0),
  'has_digest',     (select exists(select 1 from prd)),
  'remaining_uses', (select remaining_uses from pass_info),
  'total_uses',     (select total_uses     from pass_info),
  'entry_no_next',  (select entry_no_next  from pass_info),
  'recent_summaries', (select arr from lastn_json),
  'recent_count',   (select total_cnt from cnt),
  'has_recent',     ((select total_cnt from cnt) > 0)
);
$$;





create or replace function normalize_whitespace(p_text text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             coalesce(p_text,''), 
             E'[\\u00A0\\u200B\\uFEFF]', -- non-breaking space, zero-width, BOM
             '', 'g'
           ),
           E'[\\s]+',  -- 일반 공백, 탭, 엔터 포함
           '', 'g'
         );
$$;





create or replace function normalize_and_validate_email(
  p_email text
) returns text
language plpgsql
as $$
declare
  v_email  text := lower(btrim(p_email));
  v_local  text;
  v_domain text;
begin
  if v_email is null or v_email = '' then
    return null; -- 빈 입력은 상위 로직에서 허용/불허 결정
  end if;

  -- 숨은 공백/제로폭/비정상 문자 빠르게 차단
  if v_email ~ '[\s\u00A0\u200B\uFEFF<>\(\)\{\}\[\];:"''\\|,`]' then
    return null;
  end if;

  -- 기본 포맷
  if v_email !~ '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$' then
    return null;
  end if;

  v_local  := split_part(v_email, '@', 1);
  v_domain := split_part(v_email, '@', 2);

  -- 길이 제한
  if length(v_email) > 320 or length(v_local) > 64 or length(v_domain) > 255 then
    return null;
  end if;

  -- 로컬파트 규칙
  if v_local like '.%' or v_local like '%.'
     or v_local like '%..%' then
    return null;
  end if;

  -- 도메인 규칙
  if v_domain like '-%' or v_domain like '%-' or v_domain like '%..%' then
    return null;
  end if;

  -- ① 플러스 제거(모든 도메인)
  if position('+' in v_local) > 0 then
    v_local := split_part(v_local, '+', 1);
  end if;

  -- ② Gmail 점 제거(도메인 한정)
  if v_domain in ('gmail.com','googlemail.com') then
    v_local := replace(v_local, '.', '');
  end if;

  return v_local || '@' || v_domain;
end;
$$;




create or replace function init_validate_and_attach_user(
  p_sid text,
  p_uuid_code text,
  p_required jsonb,            -- 예: {"raw_emotion":"...", "situation_raw":"...", "journal_raw":"..."}
  p_email text default null,   -- 비어있으면 통과, 값이 있으면 검증
  p_ip inet default null,
  p_user_agent text default null,
  p_latency_ms int default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_pass record;
  v_reason text := null;
  v_missing_key text;
  v_norm text;
  v_user_id uuid;
begin
  -- 1) submission_state: pending 업서트
  insert into submission_state(sid, uuid_code, submit_status, status_reason, updated_at)
  values (p_sid, p_uuid_code, 'pending', 'received', v_now)
  on conflict (sid) do update
    set uuid_code     = excluded.uuid_code,
        submit_status = 'pending',
        status_reason = 'received',
        updated_at    = v_now;

  -- 2) 필수입력 누락 검사
  select key
  into v_missing_key
  from jsonb_each_text(p_required)
  where normalize_whitespace(value) = ''
  limit 1;

  if v_missing_key is not null then
    v_reason := 'missing_field_'||v_missing_key;
  end if;

  -- 3) pass 조회/유효성 (잠금까지 한 번에 처리)
  if v_reason is null then
    select up.* into v_pass
    from user_passes up
    where up.uuid_code = p_uuid_code
    for update;  -- ✅ 조회+잠금 한번에

    if v_pass is null then
      v_reason := 'not_found';
    elsif v_pass.is_active is not true then
      v_reason := 'inactive';
    elsif v_pass.expires_at is not null and v_pass.expires_at <= v_now then
      v_reason := 'expired';
    elsif coalesce(v_pass.remaining_uses,0) <= 0 then
      v_reason := 'no_uses';
    end if;
  end if;

  -- 이메일 검사 (비어있으면 그냥 통과)
  if v_reason is null and coalesce(btrim(p_email),'') <> '' then
    v_norm := normalize_and_validate_email(p_email);  -- 검증+정규화

    if v_norm is null then
      v_reason := 'invalid_email';
      -- 여기서 바로 fail 기록/리턴하는 로직이 있으면 그 흐름대로 진행
    else
      p_email := v_norm;  -- ✅ 정규화된 이메일로 교체 후 이후 로직 사용/저장
    end if;
  end if;

  -- 5) 실패 처리 공용 루틴
  if v_reason is not null then
    update submission_state
       set user_pass_id = case when v_pass is null then null else v_pass.id end,
           uuid_code = p_uuid_code,
           submit_status = 'fail',
           status_reason = v_reason,
           updated_at    = v_now,
           status_log    = concat_ws(' | ', nullif(status_log,''), format('init fail reason=%s ts=%s', v_reason, to_char(v_now,'YYYY-MM-DD HH24:MI:SS')))
     where sid = p_sid;

     -- 로그 append 후 바로 4000자 유지
     update submission_state
        set status_log = right(status_log, 4000),
            updated_at = v_now
      where sid = p_sid;

    insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
    values (case when v_pass is null then null else v_pass.id end, p_uuid_code, 'fail', v_reason, p_ip, p_user_agent, p_latency_ms, v_now);

    return jsonb_build_object('status','fail','reason',v_reason);
  end if;

  -- 6) user 매핑(심플 & 안전): NULL일 때만 1회 매핑
  --    - 이메일은 있으면 email_pending에만 넣음
  --    - 기존 user_id 있으면 절대 덮어쓰지 않음

  if v_pass.user_id is null then
    -- 새 게스트 생성 (이메일 있으면 pending으로 기록)
    insert into users (is_guest, email_pending)
    values (true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end)
    returning id into v_user_id;

    -- NULL일 때만 매핑 (멱등 보장)
    update user_passes
       set user_id = v_user_id
     where uuid_code = p_uuid_code
       and user_id is null;

    -- 이후 로직에서 쓸 수 있게 v_pass.user_id 갱신
    v_pass.user_id := v_user_id;

  else
    -- 기존 유저ID 사용
    v_user_id := v_pass.user_id;

    -- 유저 레코드 보강(없을 수 있는 극소수 케이스 방지용)
    perform 1 from users where id = v_user_id;
    if not found then
      insert into users (id, is_guest, email_pending)
      values (v_user_id, true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end);
    else
      -- verified는 절대 건드리지 않음. 이메일 값이 있으면 pending만 (선택) 갱신
      if coalesce(btrim(p_email),'') <> '' then
        update users
           set email_pending = p_email,
               updated_at    = v_now
         where id = v_user_id;
      end if;
    end if;
  end if;

  -- 7) 성공 기록(원하면 여기서 validated로 올려도 됨)
  insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
  values (v_pass.id, p_uuid_code, 'pass', 'ok', p_ip, p_user_agent, p_latency_ms, v_now);

  -- 성공 케이스여도, 마지막에 한 번 더 캡핑
  update submission_state
     set user_pass_id = v_pass.id,
         uuid_code    = p_uuid_code,
         status_log = right(coalesce(status_log,''), 4000),
         updated_at   = v_now
   where sid = p_sid;
   
  -- state에는 pending 유지(바로 seed 단계로 넘어가니까). validated로 바꾸고 싶으면 아래 주석 해제
  -- update submission_state set submit_status='validated', updated_at=v_now where sid=p_sid;

  return jsonb_build_object(
    'status','ok',
    'user_pass_id', v_pass.id,
    'user_id', v_user_id,
    'remaining_uses', v_pass.remaining_uses,
    'expires_at', v_pass.expires_at,
    'is_active', v_pass.is_active,
    'normalized_email', nullif(p_email,'')
  );
end $$;




-- 엔트리 생성 + submissions 링크(멱등)
create or replace function create_entry_and_link(
  p_sid text,                 -- 제출 건 ID(멱등 키)
  p_user_pass_id uuid,        -- 현재 패스
  p_entry jsonb               -- 오늘 입력/요약/라벨 묶음 JSON
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_user_id uuid;
  v_existing_entry uuid;
  v_entry_id uuid;
begin
  -- 0) 필수값 체크
  if p_sid is null or p_user_pass_id is null then
    return jsonb_build_object('status','error','reason','missing_sid_or_pass');
  end if;

  -- 1) 이미 링크된 경우(멱등 스킵)
  select emotion_entry_id into v_existing_entry
  from submission_state
  where sid = p_sid;

  if v_existing_entry is not null then
    return jsonb_build_object('status','skipped','entry_id', v_existing_entry);
  end if;

  -- 2) user_id 해석(트리거 없이 로직으로 보장)
  select user_id into v_user_id
  from user_passes
  where id = p_user_pass_id
  for share;

  if v_user_id is null then
    return jsonb_build_object('status','error','reason','user_id_null');
  end if;

  -- 3) 필수 필드 검증(원문 3종 + 라벨 3종)
  if coalesce(p_entry->>'raw_emotion','') = '' or
     coalesce(p_entry->>'situation_raw','') = '' or
     coalesce(p_entry->>'journal_raw','') = '' or
     coalesce(p_entry#>>'{labels,level}','') = '' or
     coalesce(p_entry#>>'{labels,feedback_type}','') = '' or
     coalesce(p_entry#>>'{labels,speech}','') = '' then
    return jsonb_build_object('status','error','reason','missing_required_fields');
  end if;

  -- 4) 엔트리 INSERT
  insert into emotion_entries (
    user_pass_id, 
    user_id,
    raw_emotion_text,
    supposed_emotion_text,
    standard_emotion_id,
    standard_emotion_reasoning,
    situation_raw_text, situation_summary_text,
    journal_raw_text,   journal_summary_text,
    emotion_level_label_snapshot,
    feedback_type_label_snapshot,
    feedback_speech_label_snapshot
  ) values (
    p_user_pass_id, v_user_id,
    p_entry->>'raw_emotion',
    nullif(p_entry->>'supposed_emotion',''),
    nullif((p_entry->>'standard_emotion_id')::uuid, null),
    nullif(p_entry->>'standard_emotion_reasoning',''),
    p_entry->>'situation_raw', nullif(p_entry->>'situation_summary',''),
    p_entry->>'journal_raw',   nullif(p_entry->>'journal_summary',''),
    p_entry#>>'{labels,level}',
    p_entry#>>'{labels,feedback_type}',
    p_entry#>>'{labels,speech}'
  )
  returning id into v_entry_id;

  -- 5) submissions 링크 + 로그
  update submission_state
     set emotion_entry_id = v_entry_id,
         status_log = concat_ws(
           ' | ',
           nullif(status_log,''),
           format('entry_linked=%s ts=%s', v_entry_id, to_char(v_now,'YYYY-MM-DD HH24:MI:SS'))
         ),
         updated_at = v_now
   where sid = p_sid;

  -- 6) 로그 길이 캡(선택)
  update submission_state
     set status_log = right(status_log, 4000)
   where sid = p_sid;

  return jsonb_build_object('status','ok','entry_id', v_entry_id);
end $$;





















create or replace function public.decrement_pass(_code text)
returns boolean
language plpgsql
security definer
as $$
begin
  update user_passes
  set remaining_uses = remaining_uses - 1
  where uuid_code = _code
    and remaining_uses > 0;

  return found; -- 차감 성공시 true, 아니면 false
end;
$$;

grant execute on function public.decrement_pass(text) to service_role;




create or replace function public.resolve_standard_emotion(_name text)
returns uuid
language sql
stable
as $$
  select id
  from public.standard_emotions
  where lower(trim(name)) = lower(trim(_name))
  limit 1;
$$;

-- 3) 실행 권한 (Make에서 service_role 키로 호출)
grant execute on function public.resolve_standard_emotion(text) to service_role;




-- 1) 필요한 확장/스키마 확인(일반적으로 기본값이라 생략 가능)
-- create schema if not exists public;

-- 2) 조인 결과를 뷰로 노출
create or replace view public.user_passes_with_passes
-- 호출자 권한으로 RLS 평가(권장)
with (security_invoker = on)
as
select
  up.id            as user_pass_id,
  up.user_id,
  u.created_at as user_created_at,   -- users.created_at 추가
  up.remaining_uses,
  up.purchased_at,
  up.expires_at,
  up.uuid_code,
  up.first_used_at,
  up.source,
  up.source_order_id,
  up.buyer_handle,
  p.id             as pass_id,
  p.name,
  p.total_uses,
  p.price,
  p.description,
  p.is_active,
  p.expires_after_days
from public.user_passes up
join public.passes p
  on p.id = up.pass_id
join users u 
  on u.id = up.user_id;

  --혹은
drop view if exists public.user_passes_with_passes cascade;

create view public.user_passes_with_passes
with (security_invoker = on)
as
select
  up.id            as user_pass_id,
  up.user_id,
  u.created_at     as user_created_at,
  up.remaining_uses,
  up.purchased_at,
  up.expires_at,
  up.uuid_code,
  up.first_used_at,
  up.source,
  up.source_order_id,
  up.buyer_handle,
  p.id             as pass_id,
  p.name,
  p.total_uses,
  p.price,
  p.description,
  p.is_active,
  p.expires_after_days
from public.user_passes up
join public.passes p on p.id = up.pass_id
left join public.users u on u.id = up.user_id;





-- 필요한 값만 받아서 INSERT하고, 생성된 id만 돌려준다
create or replace function api_insert_emotion_entry(
  in_user_pass_id uuid,
  in_user_id uuid,
  in_raw_emotion_text text,
  in_situation_raw_text text,
  in_journal_raw_text text,
  in_emotion_level_label_snapshot text,
  in_feedback_type_label_snapshot text,
  in_feedback_speech_label_snapshot text
) returns uuid
language sql
security definer
set search_path = public
as $$
  insert into emotion_entries (
    user_pass_id, user_id, raw_emotion_text, situation_raw_text, journal_raw_text, emotion_level_label_snapshot, feedback_type_label_snapshot, feedback_speech_label_snapshot
  )
  values (
    in_user_pass_id, in_user_id, in_raw_emotion_text, in_situation_raw_text, in_journal_raw_text, in_emotion_level_label_snapshot, in_feedback_type_label_snapshot, in_feedback_speech_label_snapshot
  )
  returning id;
$$;

-- (선택) 프론트에서도 쓸 계획이면 권한 부여, Make가 service_role이면 생략 가능
grant execute on function api_insert_emotion_entry(uuid, text, text, text, text) to anon, authenticated;


