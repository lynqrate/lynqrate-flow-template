alter table "public"."ai_task_runs" drop constraint "ai_task_runs_summarize_mode_ck";

drop function if exists "public"."init_validate_and_attach_user"(p_sid text, p_uuid_code text, p_required jsonb, p_ip inet, p_user_agent text, p_latency_ms integer);

alter table "public"."ai_task_runs" drop column "summarize_mode";

alter table "public"."ai_task_runs" alter column "completion_tokens" set not null;

alter table "public"."ai_task_runs" alter column "prompt_tokens" set not null;

alter table "public"."emotion_entries" drop column "rollup_digest_snapshot";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.init_validate_and_attach_user(p_sid text, p_uuid_code text, p_required jsonb, p_email text DEFAULT NULL::text, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_latency_ms integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
  v_now timestamptz := now();
  v_pass record;
  v_reason text := null;
  v_missing_key text;
  v_norm text;
  v_user_id uuid;
  v_history_id  bigint;
begin
  -- pending 업서트
  insert into submission_state(sid, uuid_code, submit_status, status_reason, updated_at)
  values (p_sid, p_uuid_code, 'pending', 'received', v_now)
  on conflict (sid) do update
    set uuid_code     = excluded.uuid_code,
        submit_status = 'pending',
        status_reason = 'received',
        updated_at    = v_now;

  -- 필수값 비어있음 체크
  select key into v_missing_key
  from jsonb_each_text(p_required)
  where normalize_whitespace(value) = ''
  limit 1;

  if v_missing_key is not null then
    v_reason := 'missing_field_'||v_missing_key;
  end if;

  -- pass 유효성 + 잠금
  if v_reason is null then
    select up.* into v_pass
    from user_passes up
    where up.uuid_code = p_uuid_code
    for update;

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

  -- 이메일 정규화/검증
  if v_reason is null and coalesce(btrim(p_email),'') <> '' then
    v_norm := normalize_and_validate_email(p_email);
    if v_norm is null then
      v_reason := 'invalid_email';
    else
      p_email := v_norm;
    end if;
  end if;

  -- 실패 공용 처리
  if v_reason is not null then
    update submission_state
       set user_pass_id = case when v_pass is null then null else v_pass.id end,
           uuid_code = p_uuid_code,
           submit_status = 'fail',
           status_reason = v_reason,
           updated_at    = v_now
     where sid = p_sid;

    perform public.append_submission_log(p_sid, format('init fail reason=%s', v_reason));

    insert into submission_history(
      user_pass_id, uuid_code, result_status, result_reason,
      ip, user_agent, latency_ms, created_at, updated_at
    )
    values (
      case when v_pass is null then null else v_pass.id end,
      p_uuid_code, 'fail', v_reason,
      p_ip, p_user_agent, p_latency_ms, v_now, v_now
    )
    returning id into v_history_id;

    return jsonb_build_object(
      'status','fail',
      'reason', v_reason,
      'history_id', v_history_id  -- ★ 다음 단계에서 업데이트용
    );
  end if;

  -- 사용자 매핑(UPSERT 스타일)
  if v_pass.user_id is null then
    -- 1) 이메일로 사용자 우선 탐색
    if p_email is not null and btrim(p_email) <> '' then
      select id into v_user_id
      from users
      where email_verified = p_email
      order by updated_at desc
      limit 1;

      -- 2) 없으면 pending 으로 생성/재사용
      if v_user_id is null then
        select id into v_user_id
        from users
        where is_guest = true
          and email_pending = p_email
        order by updated_at desc
        limit 1;
      end if;
    end if;

    -- 3) 그래도 없으면 새 guest 생성
    if v_user_id is null then
      insert into users(is_guest, email_pending)
      values (true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end)
      returning id into v_user_id;
    end if;

    update user_passes
       set user_id = v_user_id
     where uuid_code = p_uuid_code
       and user_id is null;

    v_pass.user_id := v_user_id;
  else
    v_user_id := v_pass.user_id;
    insert into users (id, is_guest, email_pending, updated_at)
    values (v_user_id, true, nullif(p_email,''), v_now)
    on conflict (id) do update
      set email_pending = coalesce(excluded.email_pending, users.email_pending),
          updated_at    = v_now;
  end if;

  -- prev_pass_id 세팅 (같은 user + 같은 pass_id에서 가장 최근 과거 1건)
  update public.user_passes cur
     set prev_pass_id = sub.prev_id,
         updated_at   = v_now
    from (
      select up.id as prev_id
      from public.user_passes up
      where up.user_id = v_user_id
        and up.id <> v_pass.id
        and up.pass_id = v_pass.pass_id
        and up.purchased_at <= v_pass.purchased_at
      order by up.purchased_at desc, up.created_at desc
      limit 1
    ) sub
   where cur.id = v_pass.id
     and (cur.prev_pass_id is distinct from sub.prev_id);

  perform public.append_submission_log(
    p_sid,
    format('prev_linked=%s', coalesce((select prev_pass_id::text from public.user_passes where id=v_pass.id), '-'))
  );

  -- 성공 히스토리(이 시점의 검증 성공 기록)
  insert into submission_history(
    user_pass_id, uuid_code, result_status, result_reason,
    ip, user_agent, latency_ms, created_at, updated_at
  )
  values (
    v_pass.id, p_uuid_code, 'pass', 'ok',
    p_ip, p_user_agent, p_latency_ms, v_now, v_now
  )
  returning id into v_history_id;  -- ★ 이 id로 나중에 GPT 실패 업데이트

  -- submission_state: ready 전환
  update submission_state
     set user_pass_id = v_pass.id,
         uuid_code    = p_uuid_code,
         submit_status= 'ready',
         status_reason= 'validation_success',
         updated_at   = v_now
   where sid = p_sid;

  perform public.append_submission_log(p_sid, 'init ok');

  return jsonb_build_object(
    'status','ok',
    'history_id', v_history_id,
    'user_pass_id', v_pass.id,
    'user_id', v_user_id,
    'uuid_code', p_uuid_code,
    'remaining_uses', v_pass.remaining_uses,
    'expires_at', v_pass.expires_at,
    'is_active', v_pass.is_active,
    'normalized_email', nullif(p_email,''),
    'normalized_emotion', normalize_whitespace(p_required->>'raw_emotion'),
    'situation_trimmed',  clean_visible_text(p_required->>'situation_raw'),
    'journal_trimmed',    clean_visible_text(p_required->>'journal_raw')
  );
end;$function$
;

CREATE OR REPLACE FUNCTION public.clean_visible_text(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select
    trim(  -- 앞/뒤 공백, 탭, 개행 정리
      regexp_replace(
        regexp_replace(
          coalesce(p_text,''),
          E'[\\u200B\\u200C\\u200D\\uFEFF]',  -- 제로폭/ BOM 제거
          '', 'g'
        ),
        E'\\u00A0',                           -- NBSP → 일반 공백
        ' ', 'g'
      )
    )
$function$
;

CREATE OR REPLACE FUNCTION public.get_rollup_context(p_user_pass_id uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
with pass_info as (
  -- 패스 메타 정보 (진행도 계산용)
  select
    up.user_id,
    coalesce(up.remaining_uses, 0) as remaining_uses,    -- NULL일 경우 0으로
    p.total_uses,
    -- 다음 엔트리 번호 (최소 1, 최대 total_uses 범위로 보정)
    greatest(1, least(p.total_uses,
      (p.total_uses - coalesce(up.remaining_uses, 0) + 1)
    )) as entry_no_next
  from user_passes up
  join passes p on p.id = up.pass_id
  where up.id = p_user_pass_id
),
prd as (
  -- 롤업 요약(digest)
  select
    coalesce(digest_text, '') as digest_text,      -- NULL일 경우 빈 문자열
    coalesce(last_entry_no, 0) as last_entry_no    -- NULL일 경우 0
  from pass_rollup_digests
  where user_pass_id = p_user_pass_id
),
cnt as (
  -- 전체 엔트리 개수
  select count(*)::int as total_cnt
  from emotion_entries
  where user_pass_id = p_user_pass_id
),
lastn as (
  -- 최근 N개의 엔트리 요약 (표준 감정명까지 조인)
  select
    e.id,
    e.situation_summary_text,
    e.journal_summary_text,
    e.created_at,
    e.standard_emotion_id,
    se.name as standard_emotion_name
  from emotion_entries e
  left join standard_emotions se on se.id = e.standard_emotion_id
  where e.user_pass_id = p_user_pass_id
  order by e.created_at desc
  limit p_limit
),
lastn_json as (
  -- 최근 N개를 JSON 배열로 변환 (없으면 [] 반환)
  select coalesce(
           (select jsonb_agg(to_jsonb(lastn) order by lastn.created_at desc) from lastn),
           '[]'::jsonb
         ) as arr
)
-- 최종 JSON 반환
select jsonb_build_object(
  -- 진행도 관련
  'user_id',        (select user_id from pass_info),
  'remaining_uses', (select remaining_uses from pass_info),
  'total_uses',     (select total_uses     from pass_info),
  'entry_no_next',  (select entry_no_next  from pass_info),

  -- 요약(digest)
  'digest',         (select digest_text   from prd),
  'last_entry_no',  (select last_entry_no from prd),
  'digest_len',     coalesce(length((select digest_text from prd)), 0),
  'has_digest',     (select exists(select 1 from prd)),

  -- 최근 엔트리
  'recent_summaries', (select arr from lastn_json),
  'recent_count',   coalesce((select total_cnt from cnt), 0),
  'has_recent',     coalesce(((select total_cnt from cnt) > 0), false)
);
$function$
;

CREATE OR REPLACE FUNCTION public.ingest_entry_and_rollup(p_sid text, p_user_pass_id uuid, p_user_id uuid, p_entry jsonb, p_gpt_responses jsonb, p_new_digest text, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
  v_now           timestamptz := now();
  v_state         text;
  v_linked_id     uuid;
  v_state_pass_id uuid;
  v_entry_id      uuid;
  v_std_id        uuid;
begin
  -- 0) 인자 검증(빠른 실패)
  if p_sid is null or p_user_pass_id is null or p_user_id is null then
    return jsonb_build_object('status','error','reason','missing_sid_or_ids');
  end if;

  -- 1) submission_state 잠금 및 최소 검증 (단 1회 SELECT)
  select submit_status, emotion_entry_id, user_pass_id
    into v_state, v_linked_id, v_state_pass_id
  from public.submission_state
  where sid = p_sid
  for update;

  if v_state is null then
    return jsonb_build_object('status','error','reason','sid_not_found');
  end if;
  if v_linked_id is not null then
    -- 이미 링크되어 있으면 멱등 처리
    return jsonb_build_object('status','skipped','entry_id', v_linked_id);
  end if;
  if v_state <> 'ready' then
    return jsonb_build_object('status','error','reason','bad_state');
  end if;
  if v_state_pass_id is not null and v_state_pass_id <> p_user_pass_id then
    return jsonb_build_object('status','error','reason','pass_mismatch');
  end if;

  -- 2) standard_emotion_id 안전 파싱(실패해도 null 처리)
  if (p_entry ? 'standard_emotion_id')
     and jsonb_typeof(p_entry->'standard_emotion_id')='string'
     and nullif(p_entry->>'standard_emotion_id','') is not null then
    begin
      v_std_id := (p_entry->>'standard_emotion_id')::uuid;
    exception when others then
      v_std_id := null;
    end;
  else
    v_std_id := null;
  end if;

  -- 3) 엔트리 INSERT (status='ready')
  insert into public.emotion_entries(
    id, user_pass_id, user_id,
    raw_emotion_text, supposed_emotion_text,
    standard_emotion_id, standard_emotion_reasoning,
    situation_raw_text, situation_summary_text,
    journal_raw_text,   journal_summary_text,
    emotion_level_label_snapshot,
    feedback_type_label_snapshot,
    feedback_speech_label_snapshot,
    is_feedback_generated,
    created_at, status, error_reason
  )
  values (
    gen_random_uuid(),
    p_user_pass_id, p_user_id,
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
    v_now, 'ready', null
  )
  returning id into v_entry_id;

  -- === GPT 응답 로그(배열이면 첫 요소만, 아니면 그대로) ===
  declare
    v_cls jsonb;
    v_sum jsonb;
    v_roll jsonb;
  begin
    -- 키가 없거나 null일 수 있으니 안전하게 꺼냄
    v_cls  := case when p_gpt_responses ? 'emotion_standadization'
                    then p_gpt_responses->'emotion_standadization' else null end;
    v_sum  := case when p_gpt_responses ? 'situation_and_journal_summary'
                    then p_gpt_responses->'situation_and_journal_summary' else null end;
    v_roll := case when p_gpt_responses ? 'new_rollup_digest'
                    then p_gpt_responses->'new_rollup_digest' else null end;

    -- 배열이면 0번 요소만 사용해 단일 객체로 표준화
    if v_cls  is not null and jsonb_typeof(v_cls)  = 'array' then v_cls  := v_cls->0;  end if;
    if v_sum  is not null and jsonb_typeof(v_sum)  = 'array' then v_sum  := v_sum->0;  end if;
    if v_roll is not null and jsonb_typeof(v_roll) = 'array' then v_roll := v_roll->0; end if;

    -- 1) 표준단어판단(classify_standard_emotion)
    if v_cls is not null and jsonb_typeof(v_cls) = 'object' then
      insert into ai_task_runs(
        emotion_entry_id, task_type, provider, model,
        request_id, prompt_tokens, completion_tokens, temperature, status
      )
      values (
        v_entry_id,
        'classify_standard_emotion',
        'openai',
        coalesce(nullif(v_cls->>'model',''), 'unknown'),
        v_cls->>'request_id',
        coalesce(nullif(v_cls->>'prompt_tokens','')::int, 0),
        coalesce(nullif(v_cls->>'completion_tokens','')::int, 0),
        nullif(v_cls->>'temperature','')::numeric,
        case lower(coalesce(v_cls->>'status','ok'))
          when 'ok' then 'ok' when 'fail' then 'fail' when 'timeout' then 'timeout' else 'ok'
        end
      );
    end if;

    -- 2) 상황+일기 요약(summarize_situation_and_journal)
    if v_sum is not null and jsonb_typeof(v_sum) = 'object' then
      insert into ai_task_runs(
        emotion_entry_id, task_type, provider, model,
        request_id, prompt_tokens, completion_tokens, temperature, status
      )
      values (
        v_entry_id,
        'summarize_situation_and_journal',
        'openai',
        coalesce(nullif(v_sum->>'model',''), 'unknown'),
        v_sum->>'request_id',
        coalesce(nullif(v_sum->>'prompt_tokens','')::int, 0),
        coalesce(nullif(v_sum->>'completion_tokens','')::int, 0),
        nullif(v_sum->>'temperature','')::numeric,
        case lower(coalesce(v_sum->>'status','ok'))
          when 'ok' then 'ok' when 'fail' then 'fail' when 'timeout' then 'timeout' else 'ok'
        end
      );
    end if;

    -- 3) 롤링 요약(rolling_digest)
    if v_roll is not null and jsonb_typeof(v_roll) = 'object' then
      insert into ai_task_runs(
        emotion_entry_id, task_type, provider, model,
        request_id, prompt_tokens, completion_tokens, temperature, status
      )
      values (
        v_entry_id,
        'rolling_digest',
        'openai',
        coalesce(nullif(v_roll->>'model',''), 'unknown'),
        v_roll->>'request_id',
        coalesce(nullif(v_roll->>'prompt_tokens','')::int, 0),
        coalesce(nullif(v_roll->>'completion_tokens','')::int, 0),
        nullif(v_roll->>'temperature','')::numeric,
        case lower(coalesce(v_roll->>'status','ok'))
          when 'ok' then 'ok' when 'fail' then 'fail' when 'timeout' then 'timeout' else 'ok'
        end
      );
    end if;
  end;
  -- === /GPT 응답 로그 ===

  -- 4) 롤업 UPSERT (앞단 seed가 만들어둔 행이 있든 없든 멱등)
  --    기존 last_entry_no를 읽을 필요 없이, 충돌 시 +1 증가
  insert into public.pass_rollup_digests as d (user_pass_id, digest_text, last_entry_no, created_at, updated_at)
  values (p_user_pass_id, coalesce(p_new_digest,''), 1, v_now, v_now)
  on conflict (user_pass_id)
  do update set
     digest_text   = case
                       when coalesce(excluded.digest_text,'') = '' then d.digest_text
                       else excluded.digest_text
                     end,
     last_entry_no = greatest(d.last_entry_no,0) + 1,
     updated_at    = v_now;

  -- 5) submission_state에 링크만 갱신(상태는 그대로 'ready')
  update public.submission_state
     set emotion_entry_id = v_entry_id,
         user_pass_id     = coalesce(user_pass_id, p_user_pass_id),
         updated_at       = v_now
   where sid = p_sid;

  -- 6) 감사 로그
  perform public.append_submission_log(
    p_sid,
    format('ingest ok entry=%s', v_entry_id)
  );

  return jsonb_build_object('status','ok','entry_id', v_entry_id);
end;$function$
;

CREATE OR REPLACE FUNCTION public.mark_submission_fail(p_sid text, p_reason text, p_history_id bigint DEFAULT NULL::bigint, p_error_json jsonb DEFAULT NULL::jsonb, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_latency_ms integer DEFAULT NULL::integer, p_emotion_entry_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$declare
  v_now       timestamptz := now();
  v_user_pass uuid;
  v_uuid_code text;
begin
  -- 1) 현재 상태를 fail로 동기화
  update submission_state s
     set submit_status = 'fail',
         status_reason = p_reason,
         updated_at    = v_now
   where s.sid = p_sid;

  -- 2) 상태 로깅(선택 함수가 있다면)
  perform public.append_submission_log(p_sid, format('fail reason=%s', p_reason));

  -- 3) 보조 데이터 확보(새 히스토리 행 생성 시 사용)
  select s.user_pass_id, s.uuid_code
    into v_user_pass, v_uuid_code
  from submission_state s
  where s.sid = p_sid;

  -- 4) 히스토리 갱신
  if p_history_id is not null then
    -- 같은 행을 업데이트하여 "검증 OK → GPT 단계 error"로 승격
    update submission_history
       set result_status    = 'error',        -- 체크 제약: ('pass','fail','error')
           result_reason    = p_reason,
           emotion_entry_id = coalesce(p_emotion_entry_id, emotion_entry_id),
           updated_at       = v_now,
           error_json       = p_error_json
     where id = p_history_id;
  else
    -- init 단계에서 history_id를 못 받았거나 유실된 경우: 새 행을 남겨 복원
    insert into submission_history(
      user_pass_id, emotion_entry_id, uuid_code,
      result_status, result_reason, ip, user_agent, latency_ms, created_at, updated_at, error_json
    )
    values (
      v_user_pass, p_emotion_entry_id, v_uuid_code,
      'error', p_reason, p_ip, p_user_agent, p_latency_ms, v_now, v_now, p_error_json
    );
  end if;
end;$function$
;

CREATE OR REPLACE FUNCTION public.normalize_whitespace(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(
           regexp_replace(
             coalesce(p_text,''), 
             E'[\\u00A0\\u200B\\uFEFF]', -- non-breaking space, zero-width, BOM
             '', 'g'
           ),
           E'[\\s]+',  -- 일반 공백, 탭, 엔터 포함
           '', 'g'
         );
$function$
;

CREATE OR REPLACE FUNCTION public.save_feedback_and_finish(p_entry_id uuid, p_sid text, p_feedback_text text, p_gpt_responses jsonb, p_language text DEFAULT 'ko'::text)
 RETURNS TABLE(entry_id uuid, feedback_id uuid, sid text, state_after text, remaining_uses_after integer, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
  v_now     timestamptz := now();
  v_lang    text := coalesce(nullif(p_language,''), 'ko');
  v_text    text := left(coalesce(p_feedback_text,''), 4000);
  v_feedback_id uuid;
  v_rem_after int;
begin
  if length(v_text)=0 then
    raise exception 'feedback_text required';
  end if;

  with
  lock_entry as (
    -- 엔트리 잠금: 최초 생성 여부/패스 ID 확보
    select e.user_pass_id, coalesce(e.is_feedback_generated,false) as already_generated
    from public.emotion_entries e
    where e.id = p_entry_id
    for update
  ),
  upsert_feedback as (
    -- 1) 피드백 UPSERT
    insert into public.emotion_feedbacks(
      id, emotion_entry_id, feedback_text, language,
      created_at, updated_at
    )
    values (
      gen_random_uuid(), p_entry_id, v_text, v_lang,
      v_now, v_now
    )
    on conflict (emotion_entry_id) do update
      set feedback_text  = excluded.feedback_text,
          language       = excluded.language,
          updated_at     = v_now
    returning id
  ),
  mark_entry as (
    -- 2) 엔트리 플래그(최초 시각 보존)
    update public.emotion_entries e
       set is_feedback_generated = true,
           feedback_generated_at = coalesce(e.feedback_generated_at, v_now)
     where e.id = p_entry_id
    returning 1
  ),
  dec_pass as (
    -- 3) "처음 생성"인 경우에만 회차 차감
    update public.user_passes up
       set remaining_uses = up.remaining_uses - 1,
           first_used_at  = coalesce(first_used_at, v_now),
           updated_at     = v_now
     from lock_entry le
     where up.id = le.user_pass_id
       and le.already_generated = false
    returning up.id as user_pass_id, up.remaining_uses
  ),
  ar_insert as (
    -- 4) 남은 회차 0이면 완료 마커 멱등 생성
    insert into public.analysis_requests(
      user_pass_id, scope, status, reason, analysis_text,
      stats_json, created_at, updated_at
    )
    select d.user_pass_id, 'pass', 'done', null, '',
           case when coalesce(prd.digest_text,'') <> ''
                then jsonb_build_object('carryover_digest', prd.digest_text)
                else null end,
           v_now, v_now
    from dec_pass d
    left join public.pass_rollup_digests prd on prd.user_pass_id = d.user_pass_id
    where d.remaining_uses = 0
    on conflict (user_pass_id, scope, status) do nothing
    returning 1
  ),
  done_state as (
    -- 5) 상태 종결
    update public.submission_state s
       set submit_status = 'done',
           updated_at    = v_now
     where s.sid = p_sid
    returning 1
  )
  -- 최종 remaining_uses_after 계산: 차감이 없었으면 현재값 조회
  select
    (select id from upsert_feedback),
    coalesce(
      (select remaining_uses from dec_pass limit 1),
      (select up.remaining_uses from public.user_passes up
         join lock_entry le on up.id = le.user_pass_id)
    )
  into v_feedback_id, v_rem_after;

  -- === GPT 'feedbacks' 로그 적재 (단일 객체 기본, 배열이면 0번만 사용) ===
  begin
    if p_gpt_responses is not null and (p_gpt_responses ? 'feedbacks') then

      -- 배열이면 첫 요소만 꺼내 단일 객체처럼 변환
      if jsonb_typeof(p_gpt_responses->'feedbacks') = 'array' then
        p_gpt_responses := jsonb_set(
          p_gpt_responses,
          '{feedbacks}',
          (p_gpt_responses->'feedbacks')->0
        );
      end if;

      if jsonb_typeof(p_gpt_responses->'feedbacks') = 'object' then
        insert into ai_task_runs(
          emotion_entry_id, task_type, provider, model,
          request_id, prompt_tokens, completion_tokens, temperature, status
        )
        values (
          p_entry_id,
          'feedback',  -- 고정
          'openai',
          coalesce(nullif(p_gpt_responses->'feedbacks'->>'model',''), 'unknown'),
          p_gpt_responses->'feedbacks'->>'request_id',
          coalesce(nullif(p_gpt_responses->'feedbacks'->>'prompt_tokens','')::int, 0),
          coalesce(nullif(p_gpt_responses->'feedbacks'->>'completion_tokens','')::int, 0),
          nullif(p_gpt_responses->'feedbacks'->>'temperature','')::numeric,
          case lower(coalesce(p_gpt_responses->'feedbacks'->>'status','ok'))
            when 'ok' then 'ok'
            when 'fail' then 'fail'
            when 'timeout' then 'timeout'
            else 'ok'
          end
        );
      end if;

    end if;
  exception when others then
    -- 로그 적재 실패는 본 흐름에 영향 없게 흡수
    perform public.append_submission_log(p_sid, format('feedbacks log error=%s', SQLSTATE));
  end;
  -- === /GPT 'feedbacks' 로그 적재 ===

  perform public.append_submission_log(p_sid, format('feedback_saved entry=%s', p_entry_id));

  entry_id := p_entry_id;
  feedback_id := v_feedback_id;
  sid := p_sid;
  state_after := 'done';
  remaining_uses_after := v_rem_after;
  updated_at := v_now;
  return next;
end;$function$
;


