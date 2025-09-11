alter table "public"."ai_task_runs" alter column "completion_tokens" drop not null;

alter table "public"."ai_task_runs" alter column "prompt_tokens" drop not null;

alter table "public"."emotion_entries" add column "rollup_digest_snapshot" text;

set check_function_bodies = off;

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
    created_at, status, error_reason,
    rollup_digest_snapshot
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
    v_now, 'ready', null,
    coalesce(p_new_digest,'')
  )
  returning id into v_entry_id;

  -- === GPT 응답 로그(배열이면 첫 요소만, 아니면 그대로) ===
  declare
    v_cls jsonb;
    v_sum jsonb;
    v_roll jsonb;
  begin
    -- 키가 없거나 null일 수 있으니 안전하게 꺼냄
    v_cls  := case when p_gpt_responses ? 'emotion_standardization'
                    then p_gpt_responses->'emotion_standardization' else null end;
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

  -- 4) submission_state에 링크만 갱신(상태는 그대로 'ready')
  update public.submission_state
     set emotion_entry_id = v_entry_id,
         user_pass_id     = coalesce(user_pass_id, p_user_pass_id),
         updated_at       = v_now
   where sid = p_sid;

  -- 5) 감사 로그
  perform public.append_submission_log(
    p_sid,
    format('ingest ok entry=%s', v_entry_id)
  );

  return jsonb_build_object('status','ok','entry_id', v_entry_id);
end;$function$
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
  bump_rollup as (
    -- 3) 최초 피드백 생성일 때만 롤업 카운트 +1 (멱등)
    insert into public.pass_rollup_digests as d
      (user_pass_id, digest_text, last_entry_no, created_at, updated_at)
    select le.user_pass_id,
          coalesce(e.rollup_digest_snapshot, ''),  -- ingest에서 저장해둔 스냅샷 사용
          1, v_now, v_now
    from lock_entry le
    join public.emotion_entries e on e.id = p_entry_id
    where le.already_generated = false
    on conflict (user_pass_id)
    do update set
      digest_text   = case
                        when coalesce(excluded.digest_text,'') = '' then d.digest_text
                        else excluded.digest_text
                      end,
      last_entry_no = greatest(d.last_entry_no,0) + 1,
      updated_at    = v_now
    returning 1
  ),
  dec_pass as (
    -- 4) "처음 생성"인 경우에만 회차 차감
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


