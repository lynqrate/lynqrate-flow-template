

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."append_submission_log"("p_sid" "text", "p_msg" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_now text := to_char(now(),'YYYY-MM-DD HH24:MI:SS');
  v_line text := format('%s ts=%s', p_msg, v_now);
begin
  update public.submission_state
   set status_log = right(
                      case when coalesce(status_log,'') = '' then v_line
                           else status_log || ' | ' || v_line end,
                      4000),
       updated_at = now()
  where sid = p_sid;
end;
$$;


ALTER FUNCTION "public"."append_submission_log"("p_sid" "text", "p_msg" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clean_visible_text"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'pg_catalog'
    AS $$
  select trim(
           regexp_replace(
             regexp_replace(coalesce(p_text,''),
               E'[\\u200B\\u200C\\u200D\\uFEFF]', '', 'g'
             ),
             E'\\u00A0', ' ', 'g'
           )
         );
$$;


ALTER FUNCTION "public"."clean_visible_text"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finalize_carryover_digest"("p_user_pass_id" "uuid", "p_emotion_entry_id" "uuid", "p_carryover_digest" "text", "p_gpt_responses" "jsonb" DEFAULT NULL::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$begin
  insert into public.rpc_debug_log(func, phase, user_pass_id)
values ('finalize_carryover_digest', 'begin_finalize_carryover_digest', p_user_pass_id);

  -- 1) pending → done, stats_json에는 carryover_digest만 남김
  update public.analysis_requests
     set status     = 'done',
         updated_at = now(),
         stats_json = jsonb_build_object(
           'carryover_digest', left(coalesce(p_carryover_digest,''), 8000)
         )
   where user_pass_id = p_user_pass_id
     and scope = 'pass'
     and status = 'pending';

  -- 2) carryover 요약 실행 로그 적재
  insert into public.ai_task_runs(
    emotion_entry_id,
    task_type,
    provider,
    model,
    request_id,
    prompt_tokens,
    completion_tokens,
    temperature,
    status,
    created_at,
    updated_at
  )
  values (
    p_emotion_entry_id,
    'carryover_digest',
    coalesce(nullif(p_gpt_responses->>'provider',''), 'openai'),
    coalesce(nullif(p_gpt_responses->>'model',''), 'unknown'),
    nullif(p_gpt_responses->>'request_id',''),
    coalesce((p_gpt_responses->>'prompt_tokens')::int, null),
    coalesce((p_gpt_responses->>'completion_tokens')::int, null),
    coalesce((p_gpt_responses->>'temperature')::numeric, null),
    coalesce(nullif(p_gpt_responses->>'status',''), 'ok'),
    now(),
    now()
  );
end;$$;


ALTER FUNCTION "public"."finalize_carryover_digest"("p_user_pass_id" "uuid", "p_emotion_entry_id" "uuid", "p_carryover_digest" "text", "p_gpt_responses" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_prev_user_pass_id"("p_user_pass_id" "uuid", "p_same_kind" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with cur as (
    select id, user_id, pass_id, prev_pass_id
    from public.user_passes
    where id = p_user_pass_id
  ),
  calc as (
    -- 같은 user, 현재 pass 제외, (옵션) 같은 pass 종류만
    select up2.id
    from public.user_passes up2
    join cur on up2.user_id = cur.user_id
    where up2.id <> cur.id
      and (p_same_kind is false or up2.pass_id = cur.pass_id)
    order by
      coalesce(up2.first_used_at, up2.first_seen_at, up2.purchased_at, up2.created_at) desc,
      up2.id desc
    limit 1
  )
  -- 저장된 체인이 있으면 우선, 없으면 계산 결과 사용
  select coalesce(
    (select prev_pass_id from cur),
    (select id from calc)
  );
$$;


ALTER FUNCTION "public"."get_prev_user_pass_id"("p_user_pass_id" "uuid", "p_same_kind" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_rollup_context"("p_user_pass_id" "uuid", "p_limit" integer DEFAULT 5) RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
WITH pass_info AS (
  SELECT
    up.user_id,
    COALESCE(up.remaining_uses, 0) AS remaining_uses,
    p.total_uses,
    GREATEST(
      1,
      LEAST(
        p.total_uses,
        (p.total_uses - COALESCE(up.remaining_uses, 0) + 1)
      )
    ) AS entry_no_next
  FROM public.user_passes up
  JOIN public.passes p ON p.id = up.pass_id
  WHERE up.id = p_user_pass_id
),
prev AS (
  SELECT public.get_prev_user_pass_id(p_user_pass_id, FALSE) AS prev_id
),
prev_carry AS (
  SELECT ar.stats_json->>'carryover_digest' AS carryover_digest
  FROM public.analysis_requests ar
  JOIN prev ON TRUE
  WHERE ar.user_pass_id = prev.prev_id
    AND ar.scope = 'pass'
    AND ar.status = 'done'
  ORDER BY ar.updated_at DESC NULLS LAST, ar.created_at DESC
  LIMIT 1
),
prev_prd AS (
  SELECT prd.digest_text
  FROM public.pass_rollup_digests prd
  JOIN prev ON prd.user_pass_id = prev.prev_id
  ORDER BY prd.entry_no DESC NULLS LAST, prd.created_at DESC NULLS LAST
  LIMIT 1
),
curr_prd AS (
  SELECT
    COALESCE(digest_text,'') AS digest_text,
    COALESCE(entry_no, 0)    AS entry_no
  FROM public.pass_rollup_digests
  WHERE user_pass_id = p_user_pass_id
  ORDER BY entry_no DESC NULLS LAST, created_at DESC NULLS LAST
  LIMIT 1
),
cnt AS (
  SELECT COUNT(*)::int AS total_cnt
  FROM public.emotion_entries
  WHERE user_pass_id = p_user_pass_id
    AND is_feedback_generated IS TRUE
),
lastn AS (
  SELECT
    e.id,
    e.situation_summary_text,
    e.journal_summary_text,
    e.created_at,
    e.standard_emotion_id,
    se.name AS standard_emotion_name
  FROM public.emotion_entries e
  LEFT JOIN public.standard_emotions se ON se.id = e.standard_emotion_id
  WHERE e.user_pass_id = p_user_pass_id
    AND e.is_feedback_generated IS TRUE
  ORDER BY e.created_at DESC
  LIMIT p_limit
),
lastn_json AS (
  SELECT COALESCE(
           (SELECT jsonb_agg(to_jsonb(lastn) ORDER BY lastn.created_at DESC) FROM lastn),
           '[]'::jsonb
         ) AS arr
)
SELECT jsonb_build_object(
  -- 진행도
  'user_id',        (SELECT user_id        FROM pass_info),
  'remaining_uses', (SELECT remaining_uses FROM pass_info),
  'total_uses',     (SELECT total_uses     FROM pass_info),
  'entry_no_next',  (SELECT entry_no_next  FROM pass_info),

  -- prev_digest 규칙:
  -- 1) 첫 사용(entry_no_next=1): 직전 carryover → 직전 롤업 → ''
  -- 2) 그 외(entry_no_next>=2):  이번 패스 최신 롤업 → ''
  'prev_digest',
    CASE
      WHEN (SELECT entry_no_next FROM pass_info) = 1 THEN
        COALESCE(
          NULLIF((SELECT carryover_digest FROM prev_carry), ''),
          (SELECT digest_text FROM prev_prd),
          ''
        )
      ELSE
        COALESCE((SELECT digest_text FROM curr_prd), '')
    END,

  -- 현재 패스 롤업 메타(최신본 기준)
  'last_entry_no',  COALESCE((SELECT entry_no    FROM curr_prd), 0),
  'digest_len',     COALESCE(LENGTH((SELECT digest_text FROM curr_prd)), 0),
  'has_digest',     EXISTS(SELECT 1 FROM curr_prd),

  -- 최근 엔트리
  'recent_summaries', (SELECT arr FROM lastn_json),
  'recent_count',     COALESCE((SELECT total_cnt FROM cnt), 0),
  'has_recent',       COALESCE(((SELECT total_cnt FROM cnt) > 0), FALSE)
);
$$;


ALTER FUNCTION "public"."get_rollup_context"("p_user_pass_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_rollup_context"("p_user_pass_id" "uuid", "p_limit" integer DEFAULT 5, "p_debug" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  -- 기본 메타
  v_user_id          uuid;
  v_total_uses       int;
  v_remaining_uses   int;
  v_entry_no_next    int;

  -- prev / curr 소스
  v_prev_id          uuid;
  v_prev_carry       text;
  v_prev_rollup      text;
  v_curr_rollup      text;

  -- 결과 메타
  v_prev_digest         text;
  v_prev_digest_source  text;
  v_recent              jsonb := '[]'::jsonb;
  v_recent_cnt          int := 0;
  v_last_entry_no       int := 0;  -- ★ 이제 테이블 칼럼이 아니라, 최신 행의 entry_no
  v_digest_len          int := 0;
  v_has_digest          boolean := false;

  v_ctx jsonb;
begin
  -- [start]
  if p_debug then
    insert into public.rpc_debug_log(func, phase, user_pass_id, data)
    values ('get_rollup_context', 'start', p_user_pass_id,
            jsonb_build_object('limit', p_limit));
  end if;

  -- 1) 현재 패스 메타
  select up.user_id,
         p.total_uses,
         coalesce(up.remaining_uses, p.total_uses) as remaining_uses_norm,
         greatest(1, least(p.total_uses, (p.total_uses - coalesce(up.remaining_uses, p.total_uses) + 1))) as entry_no_next_calc,
         coalesce(up.prev_pass_id, public.get_prev_user_pass_id(up.id, false)) as prev_id_calc
  into   v_user_id, v_total_uses, v_remaining_uses, v_entry_no_next, v_prev_id
  from public.user_passes up
  join public.passes p on p.id = up.pass_id
  where up.id = p_user_pass_id;

  if v_user_id is null then
    if p_debug then
      insert into public.rpc_debug_log(func, phase, user_pass_id, msg)
      values ('get_rollup_context', 'error_no_pass', p_user_pass_id, 'pass not found or no access');
    end if;
    return jsonb_build_object('status','error','reason','pass_not_found');
  end if;

  if p_debug then
    insert into public.rpc_debug_log(func, phase, user_pass_id, data)
    values ('get_rollup_context', 'meta', p_user_pass_id,
            jsonb_build_object(
              'user_id', v_user_id,
              'total_uses', v_total_uses,
              'remaining_uses', v_remaining_uses,
              'entry_no_next', v_entry_no_next,
              'prev_id', v_prev_id
            ));
  end if;

  -- 2) prev/curr 원천값 수집 (★ last_entry_no 칼럼 의존 제거 → entry_no 기준 최신 1건)
  -- 2-1) 직전 패스 carryover(done AR 최신 1건)
  if v_prev_id is not null then
    select ar.stats_json->>'carryover_digest'
      into v_prev_carry
    from public.analysis_requests ar
    where ar.user_pass_id = v_prev_id
      and ar.scope = 'pass'
      and ar.status = 'done'
    order by ar.updated_at desc nulls last, ar.created_at desc
    limit 1;

    -- 2-2) 직전 패스 롤업 최신 1건
    select prd.digest_text
      into v_prev_rollup
    from public.pass_rollup_digests prd
    where prd.user_pass_id = v_prev_id
    order by prd.entry_no desc nulls last, prd.created_at desc nulls last
    limit 1;
  end if;

  -- 2-3) 현재 패스 롤업 최신 1건
  select coalesce(prd.digest_text,''), coalesce(prd.entry_no, 0)
    into v_curr_rollup, v_last_entry_no
  from public.pass_rollup_digests prd
  where prd.user_pass_id = p_user_pass_id
  order by prd.entry_no desc nulls last, prd.created_at desc nulls last
  limit 1;

  if p_debug then
    insert into public.rpc_debug_log(func, phase, user_pass_id, data)
    values ('get_rollup_context', 'sources', p_user_pass_id,
            jsonb_build_object(
              'prev_id', v_prev_id,
              'prev_carry_len',  coalesce(length(v_prev_carry),0),
              'prev_rollup_len', coalesce(length(v_prev_rollup),0),
              'curr_rollup_len', coalesce(length(v_curr_rollup),0),
              'curr_last_entry_no', v_last_entry_no
            ));
  end if;

  -- 3) prev_digest 결정
  if v_entry_no_next = 1 then
    -- 첫 사용: 직전 carryover → 직전 롤업 → ''
    v_prev_digest := coalesce(nullif(v_prev_carry,''), v_prev_rollup, '');
    v_prev_digest_source := case
      when coalesce(v_prev_carry,'') <> '' then 'carryover'
      when v_prev_rollup is not null then 'prev_rollup'
      else ''
    end;
  else
    -- 두 번째 이후: 현재 패스 누적 롤업 최신본
    v_prev_digest := coalesce(v_curr_rollup,'');
    v_prev_digest_source := case when coalesce(v_curr_rollup,'') <> '' then 'current_rollup' else '' end;
  end if;

  v_digest_len := coalesce(length(v_curr_rollup), 0);
  v_has_digest := (coalesce(v_curr_rollup,'') <> '');

  if p_debug then
    insert into public.rpc_debug_log(func, phase, user_pass_id, data)
    values ('get_rollup_context', 'decision', p_user_pass_id,
            jsonb_build_object(
              'entry_no_next', v_entry_no_next,
              'prev_digest_source', v_prev_digest_source,
              'prev_digest_len', coalesce(length(v_prev_digest),0)
            ));
  end if;

  -- 4) 최근 N개 엔트리 요약
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb),
         count(*)
    into v_recent, v_recent_cnt
  from (
    select
      e.id,
      e.situation_summary_text,
      e.journal_summary_text,
      e.created_at,
      e.standard_emotion_id,
      se.name as standard_emotion_name
    from public.emotion_entries e
    left join public.standard_emotions se on se.id = e.standard_emotion_id
    where e.user_pass_id = p_user_pass_id
      and e.is_feedback_generated is true
    order by e.created_at desc
    limit p_limit
  ) t;

  -- 5) 반환 JSON
  v_ctx := jsonb_build_object(
    'user_id',         v_user_id,
    'remaining_uses',  v_remaining_uses,
    'total_uses',      v_total_uses,
    'entry_no_next',   v_entry_no_next,

    'prev_digest',     coalesce(v_prev_digest, ''),

    -- ★ 현재 패스 롤업 메타 (entry_no 기반)
    'last_entry_no',   coalesce(v_last_entry_no, 0),
    'digest_len',      v_digest_len,
    'has_digest',      v_has_digest,

    'recent_summaries', v_recent,
    'recent_count',     v_recent_cnt,
    'has_recent',       (v_recent_cnt > 0)
  );

  if p_debug then
    insert into public.rpc_debug_log(func, phase, user_pass_id, data)
    values ('get_rollup_context', 'end', p_user_pass_id,
            jsonb_build_object(
              'return_keys', array['user_id','prev_digest','recent_count','entry_no_next'],
              'recent_count', v_recent_cnt
            ));
  end if;

  return v_ctx;

exception when others then
  if p_debug then
    insert into public.rpc_debug_log(func, phase, user_pass_id, msg, data)
    values ('get_rollup_context', 'exception', p_user_pass_id,
            sqlstate,
            jsonb_build_object('message', sqlerrm));
  end if;
  return jsonb_build_object('status','error','code',sqlstate,'message',sqlerrm);
end;
$$;


ALTER FUNCTION "public"."get_rollup_context"("p_user_pass_id" "uuid", "p_limit" integer, "p_debug" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ingest_entry_and_rollup"("p_sid" "text", "p_user_pass_id" "uuid", "p_user_id" "uuid", "p_entry" "jsonb", "p_gpt_responses" "jsonb", "p_new_digest" "text", "p_ip" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$declare
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
        request_id, prompt_tokens, completion_tokens, temperature, status, summarize_mode
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
        end,
        v_sum->>'summarize_mode'
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
end;$$;


ALTER FUNCTION "public"."ingest_entry_and_rollup"("p_sid" "text", "p_user_pass_id" "uuid", "p_user_id" "uuid", "p_entry" "jsonb", "p_gpt_responses" "jsonb", "p_new_digest" "text", "p_ip" "inet", "p_user_agent" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."init_validate_and_attach_user"("p_sid" "text", "p_uuid_code" "text", "p_required" "jsonb", "p_ip" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_latency_ms" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$declare
  v_now         timestamptz := now();
  v_pass        record;
  v_reason      text := null;
  v_missing_key text;
  v_user_id     uuid;
  v_history_id  bigint;

  -- email 처리 (필수 정책)
  v_email_raw   text;
  v_email_norm  text;

  v_prev_of_cur uuid;
  v_user        users%ROWTYPE;
begin
  -- 0) 상태: pending 업서트
  insert into submission_state(sid, uuid_code, submit_status, status_reason, updated_at)
  values (p_sid, p_uuid_code, 'pending', 'received', v_now)
  on conflict (sid) do update
    set uuid_code     = excluded.uuid_code,
        submit_status = 'pending',
        status_reason = 'received',
        updated_at    = v_now;

  -- 1) 필수값 비어있음 체크 (email 포함/필수)
  select key into v_missing_key
  from jsonb_each_text(p_required)
  where normalize_whitespace(value) = ''
  limit 1;

  if v_missing_key is not null then
    v_reason := 'missing_field_'||v_missing_key;
  end if;

  -- 2) pass 유효성 + 잠금
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

  -- 3) 이메일 정규화/검증 (필수)
  if v_reason is null then
    v_email_raw := coalesce(p_required->>'email','');
    v_email_norm := normalize_and_validate_email(v_email_raw);
    if v_email_norm is null then
      v_reason := 'invalid_email';
    end if;
  end if;

  -- 4) 실패 공용 처리
  if v_reason is not null then
    update submission_state
       set user_pass_id = case when v_pass is null then null else v_pass.id end,
           uuid_code    = p_uuid_code,
           submit_status= 'fail',
           status_reason= v_reason,
           updated_at   = v_now
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
      'history_id', v_history_id
    );
  end if;

  -- 5) 사용자 매핑(UPSERT 스타일)
  if v_pass.user_id is null then
    -- 5-1) 이메일로 사용자 우선 탐색 (검증 완료 메일 우선)
    if v_email_norm is not null and v_email_norm <> '' then
      select id into v_user_id
      from users
      where email_verified = v_email_norm
      order by updated_at desc
      limit 1;

      -- 5-2) 없으면 guest + pending 이메일 재사용
      if v_user_id is null then
        select id into v_user_id
        from users
        where is_guest = true
          and email_pending = v_email_norm
        order by updated_at desc
        limit 1;
      end if;
    end if;

    -- 5-3) 그래도 없으면 새 guest 생성
    if v_user_id is null then
      insert into users(is_guest, email_pending)
      values (true, nullif(v_email_norm,''))
      returning id into v_user_id;
    end if;

    update user_passes
       set user_id = v_user_id
     where uuid_code = p_uuid_code
       and user_id is null;

    v_pass.user_id := v_user_id;
  else
    -- 이미 이용권 ↔ 사용자 연결이 존재할 때: 최초 이메일 고정, 불일치 시 soft warning
    v_user_id := v_pass.user_id;

    -- 현재 사용자 레코드 잠금
    select * into v_user
    from users
    where id = v_user_id
    for update;

    -- 검증 완료 이메일이 있으면: 다른 이메일 입력은 무시 + warning
    if v_user.email_verified is not null then
      if v_email_norm is distinct from v_user.email_verified then
        perform public.append_submission_log(
          p_sid,
          format('email mismatch: verified=%s new=%s', v_user.email_verified, v_email_norm)
        );

        update submission_state
           set status_reason = 'warn_email_mismatch_verified'
         where sid = p_sid;

        -- 새 이메일은 저장하지 않고 무시
      end if;

    else
      -- 아직 검증 이메일 없음
      if v_user.email_pending is not null then
        -- 이미 pending 이 설정되어 있으면: 다른 이메일은 무시 + warning
        if v_email_norm is distinct from v_user.email_pending then
          perform public.append_submission_log(
            p_sid,
            format('email mismatch: pending=%s new=%s', v_user.email_pending, v_email_norm)
          );

          update submission_state
             set status_reason = 'warn_email_mismatch_pending'
           where sid = p_sid;

          -- 기존 pending 유지, 새 입력 무시
        end if;
      else
        -- pending 이 비어있으면: 이번 입력으로 최초 1회만 세팅
        update users
           set email_pending = nullif(v_email_norm,''),
               updated_at    = v_now
         where id = v_user_id;
      end if;
    end if;
  end if;
  
  -- 6)
  update public.user_passes
    set first_seen_at = coalesce(first_seen_at, v_now),
        updated_at    = v_now
  where id = v_pass.id
    and first_seen_at is null;

  -- 7) prev_pass_id 세팅 (공통 함수 사용)
  v_prev_of_cur := public.get_prev_user_pass_id(v_pass.id, false);

  update public.user_passes cur
     set prev_pass_id = v_prev_of_cur,
         updated_at   = v_now
   where cur.id = v_pass.id
     and (cur.prev_pass_id is distinct from v_prev_of_cur);

  perform public.append_submission_log(
    p_sid,
    format('prev_linked=%s', coalesce((select prev_pass_id::text from public.user_passes where id=v_pass.id), '-'))
  );

  -- 8) 성공 히스토리
  insert into submission_history(
    user_pass_id, uuid_code, result_status, result_reason,
    ip, user_agent, latency_ms, created_at, updated_at
  )
  values (
    v_pass.id, p_uuid_code, 'pass', 'ok',
    p_ip, p_user_agent, p_latency_ms, v_now, v_now
  )
  returning id into v_history_id;

  -- 9) submission_state: ready 전환
  update submission_state
     set user_pass_id = v_pass.id,
         uuid_code    = p_uuid_code,
         submit_status= 'ready',
         status_reason= 'validation_success',
         updated_at   = v_now
   where sid = p_sid;

  perform public.append_submission_log(p_sid, 'init ok');

  -- 9) 응답
  return jsonb_build_object(
    'status','ok',
    'history_id',       v_history_id,
    'user_pass_id',     v_pass.id,
    'user_id',          v_user_id,
    'uuid_code',        p_uuid_code,
    'remaining_uses',   v_pass.remaining_uses,
    'expires_at',       v_pass.expires_at,
    'is_active',        v_pass.is_active,
    'normalized_email', nullif(v_email_norm,''),
    'normalized_emotion', normalize_whitespace(p_required->>'raw_emotion'),
    'situation_trimmed',  clean_visible_text(p_required->>'situation_raw'),
    'journal_trimmed',    clean_visible_text(p_required->>'journal_raw')
  );
end;$$;


ALTER FUNCTION "public"."init_validate_and_attach_user"("p_sid" "text", "p_uuid_code" "text", "p_required" "jsonb", "p_ip" "inet", "p_user_agent" "text", "p_latency_ms" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_ai_task_run"("p_entry_id" "uuid", "p_task_type" "text", "p_model" "text" DEFAULT NULL::"text", "p_request_id" "text" DEFAULT NULL::"text", "p_prompt_tokens" integer DEFAULT 0, "p_completion_tokens" integer DEFAULT 0, "p_temperature" numeric DEFAULT NULL::numeric, "p_status" "text" DEFAULT 'ok'::"text", "p_error_code" "text" DEFAULT NULL::"text", "p_prompt_version" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  insert into ai_task_runs(
    emotion_entry_id, task_type, provider, model,
    request_id, prompt_tokens, completion_tokens, temperature, 
    status, error_code, prompt_version
  )
  values (
    p_entry_id, p_task_type, 'openai', nullif(p_model,''),
    p_request_id, greatest(coalesce(p_prompt_tokens,0),0),
    greatest(coalesce(p_completion_tokens,0),0), p_temperature,
    coalesce(p_status,'ok'),
    nullif(p_error_code,''),
    nullif(p_prompt_version,'')
  );
$$;


ALTER FUNCTION "public"."log_ai_task_run"("p_entry_id" "uuid", "p_task_type" "text", "p_model" "text", "p_request_id" "text", "p_prompt_tokens" integer, "p_completion_tokens" integer, "p_temperature" numeric, "p_status" "text", "p_error_code" "text", "p_prompt_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_submission_fail"("p_sid" "text", "p_reason" "text", "p_history_id" bigint DEFAULT NULL::bigint, "p_error_json" "jsonb" DEFAULT NULL::"jsonb", "p_ip" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_latency_ms" integer DEFAULT NULL::integer, "p_emotion_entry_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_now       timestamptz := now();
  v_user_pass uuid;
  v_uuid_code text;
begin
  update public.submission_state s
     set submit_status = 'fail',
         status_reason = p_reason,
         updated_at    = v_now
   where s.sid = p_sid;

  perform public.append_submission_log(p_sid, format('fail reason=%s', p_reason));

  select s.user_pass_id, s.uuid_code
    into v_user_pass, v_uuid_code
  from public.submission_state s
  where s.sid = p_sid;

  if p_history_id is not null then
    update public.submission_history
       set result_status    = 'error',
           result_reason    = p_reason,
           emotion_entry_id = coalesce(p_emotion_entry_id, emotion_entry_id),
           updated_at       = v_now,
           error_json       = p_error_json
     where id = p_history_id;
  else
    insert into public.submission_history(
      user_pass_id, emotion_entry_id, uuid_code,
      result_status, result_reason, ip, user_agent, latency_ms, created_at, updated_at, error_json
    )
    values (
      v_user_pass, p_emotion_entry_id, v_uuid_code,
      'error', p_reason, p_ip, p_user_agent, p_latency_ms, v_now, v_now, p_error_json
    );
  end if;
end;
$$;


ALTER FUNCTION "public"."mark_submission_fail"("p_sid" "text", "p_reason" "text", "p_history_id" bigint, "p_error_json" "jsonb", "p_ip" "inet", "p_user_agent" "text", "p_latency_ms" integer, "p_emotion_entry_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_and_validate_email"("p_email" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'pg_catalog'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."normalize_and_validate_email"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_whitespace"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'pg_catalog'
    AS $$
  select regexp_replace(
           regexp_replace(coalesce(p_text,''),
             E'[\\u00A0\\u200B\\uFEFF]', '', 'g'
           ),
           E'[\\s]+', '', 'g'
         );
$$;


ALTER FUNCTION "public"."normalize_whitespace"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_feedback_and_finish_v2"("p_entry_id" "uuid", "p_sid" "text", "p_feedback_text" "text", "p_gpt_responses" "jsonb", "p_language" "text" DEFAULT 'ko'::"text") RETURNS TABLE("entry_id" "uuid", "feedback_id" "uuid", "sid" "text", "state_after" "text", "remaining_uses_after" integer, "updated_at" timestamp with time zone, "prev_carryover" "text", "current_digest" "text", "is_last_turn" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$DECLARE
  v_now     timestamptz := now();
  v_lang    text := coalesce(nullif(p_language,''), 'ko');
  v_text    text := left(coalesce(p_feedback_text,''), 4000);

  v_feedback_id uuid;
  v_rem_after   int;

  v_dec_happened   boolean := false;
  v_ar_stats       jsonb := null;
  v_prev_carryover text := null;
  v_current_digest text := null;
  v_is_last        boolean := false;

  v_user_pass_id uuid;           -- ★ 로그에 쓸 user_pass_id 보관
BEGIN
  IF length(v_text) = 0 THEN
    RAISE EXCEPTION 'feedback_text required';
  END IF;

  -- (선택) 미리 user_pass_id를 변수로 확보해두면 편합니다
  SELECT e.user_pass_id INTO v_user_pass_id
  FROM public.emotion_entries e
  WHERE e.id = p_entry_id;

  WITH
  lock_entry AS (
    SELECT e.user_pass_id, coalesce(e.is_feedback_generated,false) AS already_generated
    FROM public.emotion_entries e
    WHERE e.id = p_entry_id
    FOR UPDATE
  ),
  upsert_feedback AS (
    INSERT INTO public.emotion_feedbacks(
      id, emotion_entry_id, feedback_text, language, created_at, updated_at
    )
    VALUES (gen_random_uuid(), p_entry_id, v_text, v_lang, v_now, v_now)
    ON CONFLICT (emotion_entry_id) DO UPDATE
      SET feedback_text = excluded.feedback_text,
          language      = excluded.language,
          updated_at    = v_now
    RETURNING id
  ),
  mark_entry AS (
    UPDATE public.emotion_entries e
       SET is_feedback_generated = true,
           feedback_generated_at = coalesce(e.feedback_generated_at, v_now)
     WHERE e.id = p_entry_id
    RETURNING 1
  ),
  bump_rollup AS (
    WITH next_no AS (
      SELECT COALESCE(MAX(entry_no), 0) + 1 AS n
      FROM public.pass_rollup_digests
      WHERE user_pass_id = (SELECT user_pass_id FROM lock_entry)
    ),
    snap AS (
      SELECT NULLIF(e.rollup_digest_snapshot,'') AS snapshot_text
      FROM public.emotion_entries e
      WHERE e.id = p_entry_id
    )
    INSERT INTO public.pass_rollup_digests(
      user_pass_id, digest_text, entry_no, created_at, updated_at
    )
    SELECT
      (SELECT user_pass_id FROM lock_entry),
      LEFT(COALESCE((SELECT snapshot_text FROM snap),''), 8000),
      (SELECT n FROM next_no),
      v_now, v_now
    WHERE (SELECT already_generated FROM lock_entry) = FALSE
      AND COALESCE((SELECT snapshot_text FROM snap),'') <> ''
    RETURNING 1
  ),
  -- 첫 회차 들어갔으면 seed 비우기
  seed_cleanup as (
    update public.user_passes up
      set rollup_seed_text = null,
          updated_at       = v_now
    where up.id = (select user_pass_id from lock_entry)
      and exists (
        select 1 from public.pass_rollup_digests d
        where d.user_pass_id = up.id and d.entry_no = 1
      )
    returning 1
  ),
  dec_pass AS (
    UPDATE public.user_passes up
       SET remaining_uses = up.remaining_uses - 1,
           first_used_at  = coalesce(first_used_at, v_now),
           updated_at     = v_now
     FROM lock_entry le
     WHERE up.id = le.user_pass_id
       AND le.already_generated = false
    RETURNING up.id AS user_pass_id, up.remaining_uses
  ),
  ar_insert AS (
    INSERT INTO public.analysis_requests(
      user_pass_id, scope, status, reason, analysis_text,
      stats_json, created_at, updated_at
    )
    SELECT
      d.user_pass_id,
      'pass',
      'pending',
      NULL,
      '',
      jsonb_build_object(
        -- 직전 패스 요약만: done carryover → prev 롤업 → 없으면 NULL
        'prev_carryover',
          NULLIF(
            coalesce(prev_ar.carryover_digest, prev_prd.digest_text, ''),
            ''
          ),

        -- 오늘 요약 우선: 스냅샷 → 일기 → 상황 → (보조) 이번 패스 롤업 → 없으면 NULL
        'current_digest',
          NULLIF(
            BTRIM(
              coalesce(
                NULLIF(ce.rollup_digest_snapshot, ''),  -- ① 오늘 스냅샷 최우선
                NULLIF(ce.journal_summary_text, ''),            -- ② 오늘 일기 원문
                NULLIF(ce.situation_summary_text, ''),          -- ③ 오늘 상황 텍스트
                curr_prd.digest_text,                   -- ④ 이번 패스 최신 롤업(보조)
                ''                                      -- ⑤ 최종 NULL 처리
              )
            ),
            ''
          )
      ),
      v_now, v_now
    FROM dec_pass d
    JOIN public.user_passes up ON up.id = d.user_pass_id
    JOIN public.emotion_entries ce ON ce.id = p_entry_id

    -- 직전 패스 id 계산
    left join lateral (
      select public.get_prev_user_pass_id(up.id, false) as prev_id
    ) prev on true

    -- 직전 패스의 완료된 carryover(최신 1건)
    LEFT JOIN LATERAL (
      SELECT ar.stats_json->>'carryover_digest' AS carryover_digest
      FROM public.analysis_requests ar
      WHERE ar.user_pass_id = prev.prev_id
        AND ar.scope = 'pass'
        AND ar.status = 'done'
      ORDER BY ar.updated_at DESC NULLS LAST, ar.created_at DESC
      LIMIT 1
    ) prev_ar ON true

    -- 직전 패스 롤업(최신 1건)
    LEFT JOIN LATERAL (
      SELECT prd.digest_text
      FROM public.pass_rollup_digests prd
      WHERE prd.user_pass_id = prev.prev_id
      ORDER BY prd.entry_no DESC NULLS LAST, prd.created_at DESC
      LIMIT 1
    ) prev_prd ON true

    -- 이번 패스 롤업(최신 1건) — current_digest의 보조 소스
    LEFT JOIN LATERAL (
      SELECT prd.digest_text
      FROM public.pass_rollup_digests prd
      WHERE prd.user_pass_id = d.user_pass_id
      ORDER BY prd.entry_no DESC NULLS LAST, prd.created_at DESC
      LIMIT 1
    ) curr_prd ON true

    WHERE d.remaining_uses = 0
    ON CONFLICT (user_pass_id, scope, status) DO UPDATE
      SET stats_json = EXCLUDED.stats_json,
          updated_at = v_now
    RETURNING stats_json
  ),
  ar_debug AS (
    INSERT INTO public.rpc_debug_log(func, phase, entry_id, user_pass_id, msg, data)
    SELECT
      'save_feedback_and_finish_v2',
      'ar_inserted',
      p_entry_id,
      COALESCE(v_user_pass_id, NULL),
      'analysis_requests.stats_json',
      jsonb_build_object(
        'stats_json',  a.stats_json,
        'user_pass_id', (SELECT user_pass_id FROM lock_entry),
        'is_last',     TRUE,              -- ar_insert는 조건상 마지막 회차에서만 실행됨
        'ts',          to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SSOF')
      )
    FROM ar_insert a
    RETURNING 1
  ),
  done_state AS (
    UPDATE public.submission_state s
       SET submit_status = 'done',
           updated_at    = v_now
     WHERE s.sid = p_sid
    RETURNING 1
  )        
  SELECT
    (SELECT id FROM upsert_feedback),
    coalesce(
      (SELECT remaining_uses FROM dec_pass LIMIT 1),
      (SELECT up.remaining_uses FROM public.user_passes up
         JOIN lock_entry le ON up.id = le.user_pass_id)
    ),
    EXISTS(SELECT 1 FROM dec_pass),
    (SELECT stats_json FROM ar_insert LIMIT 1)
  INTO v_feedback_id, v_rem_after, v_dec_happened, v_ar_stats;

  v_is_last := v_dec_happened AND v_rem_after = 0;

  IF v_is_last AND v_ar_stats IS NOT NULL THEN
    v_prev_carryover := NULLIF(v_ar_stats->>'prev_carryover', '');
    v_current_digest := NULLIF(v_ar_stats->>'current_digest',  '');
  END IF;

  -- GPT 'feedbacks' 로그 적재 (실패 흡수)
  BEGIN
    IF p_gpt_responses IS NOT NULL AND (p_gpt_responses ? 'feedbacks') THEN
      IF jsonb_typeof(p_gpt_responses->'feedbacks') = 'array' THEN
        p_gpt_responses := jsonb_set(p_gpt_responses, '{feedbacks}', (p_gpt_responses->'feedbacks')->0);
      END IF;

      IF jsonb_typeof(p_gpt_responses->'feedbacks') = 'object' THEN
        INSERT INTO ai_task_runs(
          emotion_entry_id, task_type, provider, model,
          request_id, prompt_tokens, completion_tokens, temperature, status
        )
        VALUES (
          p_entry_id,
          'feedback',
          'openai',
          coalesce(nullif(p_gpt_responses->'feedbacks'->>'model',''), 'unknown'),
          p_gpt_responses->'feedbacks'->>'request_id',
          coalesce(nullif(p_gpt_responses->'feedbacks'->>'prompt_tokens','')::int, 0),
          coalesce(nullif(p_gpt_responses->'feedbacks'->>'completion_tokens','')::int, 0),
          nullif(p_gpt_responses->'feedbacks'->>'temperature','')::numeric,
          CASE lower(coalesce(p_gpt_responses->'feedbacks'->>'status','ok'))
            WHEN 'ok' THEN 'ok'
            WHEN 'fail' THEN 'fail'
            WHEN 'timeout' THEN 'timeout'
            ELSE 'ok'
          END
        );
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM public.append_submission_log(p_sid, format('feedbacks log error=%s', SQLSTATE));
  END;

  PERFORM public.append_submission_log(p_sid, format('feedback_saved entry=%s', p_entry_id));

  -- 반환
  entry_id := p_entry_id;
  feedback_id := v_feedback_id;
  sid := p_sid;
  state_after := 'done';
  remaining_uses_after := v_rem_after;
  updated_at := v_now;
  prev_carryover := v_prev_carryover;
  current_digest := v_current_digest;
  is_last_turn := v_is_last;

  RETURN NEXT;
END;$$;


ALTER FUNCTION "public"."save_feedback_and_finish_v2"("p_entry_id" "uuid", "p_sid" "text", "p_feedback_text" "text", "p_gpt_responses" "jsonb", "p_language" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_and_record_submission"("p_sid" "text", "p_uuid_code" "text", "p_user_pass_id" "uuid", "p_user_id" "uuid", "p_reason" "text", "p_ip" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_latency_ms" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$declare
  v_now timestamptz := now();
  v_state text;
  v_status text := 'skipped';
  v_reason text := p_reason;
  v_seed text := '';
  v_seed_source text := 'empty';
  v_prev_pass_id uuid;
begin
  select submit_status into v_state
  from submission_state
  where sid = p_sid;

  if v_state is distinct from 'ready' then
    return jsonb_build_object('status','error','reason','bad_state');
  end if;

  perform 1
  from user_passes
  where id = p_user_pass_id
    and user_id = p_user_id
    and uuid_code = p_uuid_code
    and is_active = true
  for update;

  if not found then
    return jsonb_build_object('status','error','reason','mismatch_or_inactive');
  end if;

  -- 이전 pass에서 시드 소스 탐색 (공통 함수 사용)
  select public.get_prev_user_pass_id(p_user_pass_id, false)
  into v_prev_pass_id;

  if v_prev_pass_id is not null then
    -- 1순위: 직전 패스의 완료된 carryover
    select ar.stats_json->>'carryover_digest' into v_seed
    from analysis_requests ar
    where ar.user_pass_id = v_prev_pass_id
      and ar.scope='pass'
      and ar.status='done'
    order by ar.created_at desc
    limit 1;

    -- 폴백: 직전 패스의 진행형 롤업 digest (최신 1건)
    if coalesce(v_seed,'') = '' then
      select prd.digest_text
        into v_seed
      from pass_rollup_digests prd
      where prd.user_pass_id = v_prev_pass_id
      order by prd.entry_no desc nulls last, prd.created_at desc
      limit 1;

      v_seed_source := case when coalesce(v_seed,'')<>'' then 'prev_pass_digest' else 'empty' end;
    else
      v_seed_source := 'carryover_digest';
    end if;
  end if;
  
  if coalesce(v_seed,'') <> '' then
    update public.user_passes
      set rollup_seed_text = v_seed,
          updated_at       = v_now
    where id = p_user_pass_id;
    v_status := 'seeded';
  else
    v_reason := 'empty_seed';
  end if;

  perform public.append_submission_log(
    p_sid,
    format('seed status=%s seed_source=%s prev_pass_id=%s reason=%s',
           v_status, v_seed_source,
           coalesce(v_prev_pass_id::text,'-'),
           coalesce(v_reason,'-'))
  );

  return jsonb_build_object(
    'status', v_status,
    'seed_source', v_seed_source,
    'prev_pass_id', v_prev_pass_id,
    'seed_len', coalesce(length(v_seed),0)
  );
end;$$;


ALTER FUNCTION "public"."seed_and_record_submission"("p_sid" "text", "p_uuid_code" "text", "p_user_pass_id" "uuid", "p_user_id" "uuid", "p_reason" "text", "p_ip" "inet", "p_user_agent" "text", "p_latency_ms" integer) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ai_task_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "emotion_entry_id" "uuid",
    "task_type" "text" NOT NULL,
    "provider" "text" DEFAULT 'openai'::"text" NOT NULL,
    "model" "text" NOT NULL,
    "request_id" "text",
    "prompt_tokens" integer,
    "completion_tokens" integer,
    "total_tokens" integer GENERATED ALWAYS AS (("prompt_tokens" + "completion_tokens")) STORED,
    "temperature" numeric(3,2),
    "status" "text" DEFAULT 'ok'::"text" NOT NULL,
    "error_code" "text",
    "prompt_version" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "summarize_mode" "text",
    CONSTRAINT "ai_task_runs_summarize_mode_ck" CHECK ((("summarize_mode" = ANY (ARRAY['situation'::"text", 'journal'::"text", 'both'::"text", 'none'::"text"])) OR ("summarize_mode" IS NULL))),
    CONSTRAINT "ai_task_runs_task_type_check" CHECK (("task_type" = ANY (ARRAY['classify_standard_emotion'::"text", 'summarize_situation_and_journal'::"text", 'rolling_digest'::"text", 'feedback'::"text", 'carryover_digest'::"text"])))
);


ALTER TABLE "public"."ai_task_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."analysis_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "user_pass_id" "uuid",
    "scope" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reason" "text",
    "analysis_text" "text" DEFAULT ''::"text" NOT NULL,
    "stats_json" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "analysis_requests_scope_check" CHECK (("scope" = ANY (ARRAY['pass'::"text", 'user_all'::"text"]))),
    CONSTRAINT "analysis_requests_scope_xor" CHECK (((("scope" = 'pass'::"text") AND ("user_pass_id" IS NOT NULL) AND ("user_id" IS NULL)) OR (("scope" = 'user_all'::"text") AND ("user_id" IS NOT NULL) AND ("user_pass_id" IS NULL)))),
    CONSTRAINT "analysis_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'done'::"text"]))),
    CONSTRAINT "chk_analysis_requests_status_allowed" CHECK (("status" = ANY (ARRAY['pending'::"text", 'done'::"text"]))),
    CONSTRAINT "ck_analysis_scope_target" CHECK (((("scope" = 'pass'::"text") AND ("user_pass_id" IS NOT NULL) AND ("user_id" IS NULL)) OR (("scope" = 'user_all'::"text") AND ("user_id" IS NOT NULL) AND ("user_pass_id" IS NULL))))
);


ALTER TABLE "public"."analysis_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."emotion_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_pass_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "raw_emotion_text" "text" NOT NULL,
    "supposed_emotion_text" "text",
    "standard_emotion_id" "uuid",
    "standard_emotion_reasoning" "text",
    "situation_raw_text" "text" NOT NULL,
    "situation_summary_text" "text",
    "journal_raw_text" "text" NOT NULL,
    "journal_summary_text" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_feedback_generated" boolean DEFAULT false,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "error_reason" "text",
    "emotion_level_label_snapshot" "text" NOT NULL,
    "feedback_type_label_snapshot" "text" NOT NULL,
    "feedback_speech_label_snapshot" "text" NOT NULL,
    "feedback_generated_at" timestamp with time zone,
    "journal_raw_length" integer GENERATED ALWAYS AS ("char_length"(COALESCE("journal_raw_text", ''::"text"))) STORED,
    "situation_raw_length" integer GENERATED ALWAYS AS ("char_length"(COALESCE("situation_raw_text", ''::"text"))) STORED,
    "rollup_digest_snapshot" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "emotion_entries_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'ready'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."emotion_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."emotion_feedbacks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "emotion_entry_id" "uuid" NOT NULL,
    "feedback_text" "text" NOT NULL,
    "language" "text" DEFAULT 'ko'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."emotion_feedbacks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."one_time_email_deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "submission_id" "uuid" NOT NULL,
    "emotion_entry_id" "uuid",
    "emotion_feedback_id" "uuid",
    "purpose" "text" DEFAULT 'feedback_result'::"text" NOT NULL,
    "email" "text" NOT NULL,
    "submit_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone,
    "fail_reason" "text",
    "expires_at" timestamp with time zone DEFAULT ("now"() + '7 days'::interval) NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "one_time_email_deliveries_submit_status_check" CHECK (("submit_status" = ANY (ARRAY['pending'::"text", 'ready'::"text", 'fail'::"text"])))
);


ALTER TABLE "public"."one_time_email_deliveries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pass_rollup_digests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_pass_id" "uuid" NOT NULL,
    "digest_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "entry_no" integer
);


ALTER TABLE "public"."pass_rollup_digests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."passes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "total_uses" integer NOT NULL,
    "price" integer NOT NULL,
    "description" "text",
    "expires_after_days" integer,
    "create_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."passes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rpc_debug_log" (
    "id" bigint NOT NULL,
    "ts" timestamp with time zone DEFAULT "now"() NOT NULL,
    "func" "text" NOT NULL,
    "phase" "text",
    "entry_id" "uuid",
    "user_pass_id" "uuid",
    "msg" "text",
    "data" "jsonb"
);


ALTER TABLE "public"."rpc_debug_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."rpc_debug_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rpc_debug_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."rpc_debug_log_id_seq" OWNED BY "public"."rpc_debug_log"."id";



CREATE TABLE IF NOT EXISTS "public"."standard_emotions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "soft_order" integer NOT NULL,
    "color_code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."standard_emotions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."submission_history" (
    "id" bigint NOT NULL,
    "user_pass_id" "uuid",
    "emotion_entry_id" "uuid",
    "uuid_code" "text",
    "result_status" "text" NOT NULL,
    "result_reason" "text",
    "ip" "inet",
    "user_agent" "text",
    "latency_ms" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "error_json" "jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "submission_history_result_status_check" CHECK (("result_status" = ANY (ARRAY['pass'::"text", 'fail'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."submission_history" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."submission_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."submission_history_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."submission_history_id_seq" OWNED BY "public"."submission_history"."id";



CREATE TABLE IF NOT EXISTS "public"."submission_state" (
    "sid" "text" NOT NULL,
    "user_pass_id" "uuid",
    "emotion_entry_id" "uuid",
    "uuid_code" "text" NOT NULL,
    "submit_status" "text" NOT NULL,
    "status_reason" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status_log" "text",
    CONSTRAINT "submission_state_submit_status_check" CHECK (("submit_status" = ANY (ARRAY['pending'::"text", 'fail'::"text", 'ready'::"text", 'done'::"text"])))
);


ALTER TABLE "public"."submission_state" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_passes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "pass_id" "uuid" NOT NULL,
    "remaining_uses" integer NOT NULL,
    "purchased_at" timestamp with time zone,
    "expires_at" timestamp with time zone,
    "uuid_code" "text" DEFAULT "lower"((((((("encode"("extensions"."gen_random_bytes"(2), 'hex'::"text") || '-'::"text") || "encode"("extensions"."gen_random_bytes"(2), 'hex'::"text")) || '-'::"text") || "encode"("extensions"."gen_random_bytes"(2), 'hex'::"text")) || '-'::"text") || "encode"("extensions"."gen_random_bytes"(2), 'hex'::"text"))) NOT NULL,
    "first_used_at" timestamp with time zone,
    "source" "text" DEFAULT 'kmong'::"text" NOT NULL,
    "source_order_id" "text",
    "buyer_handle" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "prev_pass_id" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "first_seen_at" timestamp with time zone,
    "rollup_seed_text" "text"
);


ALTER TABLE "public"."user_passes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "is_guest" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "first_activity_at" timestamp with time zone DEFAULT "now"(),
    "email" "text",
    "email_verified" "text",
    "email_pending" "text",
    "email_verified_at" timestamp with time zone
);


ALTER TABLE "public"."users" OWNER TO "postgres";


ALTER TABLE ONLY "public"."rpc_debug_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."rpc_debug_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."submission_history" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."submission_history_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ai_task_runs"
    ADD CONSTRAINT "ai_task_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."analysis_requests"
    ADD CONSTRAINT "analysis_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."emotion_entries"
    ADD CONSTRAINT "emotion_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."emotion_feedbacks"
    ADD CONSTRAINT "emotion_feedbacks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."one_time_email_deliveries"
    ADD CONSTRAINT "one_time_email_deliveries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pass_rollup_digests"
    ADD CONSTRAINT "pass_rollup_digests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."passes"
    ADD CONSTRAINT "passes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rpc_debug_log"
    ADD CONSTRAINT "rpc_debug_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."standard_emotions"
    ADD CONSTRAINT "standard_emotions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."submission_history"
    ADD CONSTRAINT "submission_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."submission_state"
    ADD CONSTRAINT "submission_state_pkey" PRIMARY KEY ("sid");



ALTER TABLE ONLY "public"."user_passes"
    ADD CONSTRAINT "user_passes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_passes"
    ADD CONSTRAINT "user_passes_uuid_code_key" UNIQUE ("uuid_code");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_verified_key" UNIQUE ("email_verified");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_ai_task_runs_entry" ON "public"."ai_task_runs" USING "btree" ("emotion_entry_id", "created_at" DESC);



CREATE INDEX "idx_ai_task_runs_task" ON "public"."ai_task_runs" USING "btree" ("task_type", "created_at" DESC);



CREATE INDEX "idx_analysis_pass_created" ON "public"."analysis_requests" USING "btree" ("user_pass_id", "created_at" DESC);



CREATE INDEX "idx_analysis_user_created" ON "public"."analysis_requests" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_entries_pass_created" ON "public"."emotion_entries" USING "btree" ("user_pass_id", "created_at" DESC);



CREATE INDEX "idx_entries_user_created" ON "public"."emotion_entries" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_prd_user_entryno_created" ON "public"."pass_rollup_digests" USING "btree" ("user_pass_id", "entry_no" DESC, "created_at" DESC);



CREATE INDEX "idx_submission_history_created_at" ON "public"."submission_history" USING "btree" ("created_at");



CREATE INDEX "idx_submission_history_entry_id" ON "public"."submission_history" USING "btree" ("emotion_entry_id");



CREATE INDEX "idx_submission_history_result_reason" ON "public"."submission_history" USING "btree" ("result_reason");



CREATE INDEX "idx_submission_history_result_status" ON "public"."submission_history" USING "btree" ("result_status");



CREATE INDEX "idx_submission_history_user_pass_id" ON "public"."submission_history" USING "btree" ("user_pass_id");



CREATE INDEX "idx_submission_history_uuid_code" ON "public"."submission_history" USING "btree" ("uuid_code");



CREATE INDEX "idx_submission_state_status" ON "public"."submission_state" USING "btree" ("submit_status");



CREATE INDEX "idx_submission_state_updated_at" ON "public"."submission_state" USING "btree" ("updated_at");



CREATE INDEX "idx_submission_state_user_pass_id" ON "public"."submission_state" USING "btree" ("user_pass_id");



CREATE INDEX "idx_submission_state_uuid_code" ON "public"."submission_state" USING "btree" ("uuid_code");



CREATE INDEX "idx_user_passes_user_created" ON "public"."user_passes" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_user_passes_user_pass_time" ON "public"."user_passes" USING "btree" ("user_id", "pass_id", "purchased_at" DESC, "created_at" DESC);



CREATE INDEX "idx_user_passes_user_time" ON "public"."user_passes" USING "btree" ("user_id", "purchased_at", "created_at", "id");



CREATE INDEX "idx_users_email_pending_guest" ON "public"."users" USING "btree" ("email_pending") WHERE ("is_guest" = true);



CREATE INDEX "idx_users_email_verified" ON "public"."users" USING "btree" ("email_verified");



CREATE INDEX "one_time_email_deliveries_submission_idx" ON "public"."one_time_email_deliveries" USING "btree" ("submission_id");



CREATE UNIQUE INDEX "uq_ar_pass_done" ON "public"."analysis_requests" USING "btree" ("user_pass_id") WHERE (("scope" = 'pass'::"text") AND ("status" = 'done'::"text"));



CREATE UNIQUE INDEX "uq_ar_pass_pending" ON "public"."analysis_requests" USING "btree" ("user_pass_id") WHERE (("scope" = 'pass'::"text") AND ("status" = 'pending'::"text"));



CREATE UNIQUE INDEX "uq_ar_user_pass_scope_status" ON "public"."analysis_requests" USING "btree" ("user_pass_id", "scope", "status");



CREATE UNIQUE INDEX "uq_emotion_feedbacks_entry" ON "public"."emotion_feedbacks" USING "btree" ("emotion_entry_id");



CREATE UNIQUE INDEX "user_passes_source_order_uidx" ON "public"."user_passes" USING "btree" ("source", "source_order_id") WHERE ("source_order_id" IS NOT NULL);



CREATE UNIQUE INDEX "ux_prd_user_entryno" ON "public"."pass_rollup_digests" USING "btree" ("user_pass_id", "entry_no") WHERE ("entry_no" IS NOT NULL);



ALTER TABLE ONLY "public"."ai_task_runs"
    ADD CONSTRAINT "ai_task_runs_emotion_entry_id_fkey" FOREIGN KEY ("emotion_entry_id") REFERENCES "public"."emotion_entries"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."analysis_requests"
    ADD CONSTRAINT "analysis_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."analysis_requests"
    ADD CONSTRAINT "analysis_requests_user_pass_id_fkey" FOREIGN KEY ("user_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."emotion_entries"
    ADD CONSTRAINT "emotion_entries_standard_emotion_id_fkey" FOREIGN KEY ("standard_emotion_id") REFERENCES "public"."standard_emotions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."emotion_entries"
    ADD CONSTRAINT "emotion_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."emotion_entries"
    ADD CONSTRAINT "emotion_entries_user_pass_id_fkey" FOREIGN KEY ("user_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."emotion_feedbacks"
    ADD CONSTRAINT "emotion_feedbacks_emotion_entry_id_fkey" FOREIGN KEY ("emotion_entry_id") REFERENCES "public"."emotion_entries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."analysis_requests"
    ADD CONSTRAINT "fk_ar_user_id_users" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."analysis_requests"
    ADD CONSTRAINT "fk_ar_user_pass_id_user_passes" FOREIGN KEY ("user_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."one_time_email_deliveries"
    ADD CONSTRAINT "one_time_email_deliveries_emotion_entry_id_fkey" FOREIGN KEY ("emotion_entry_id") REFERENCES "public"."emotion_entries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."one_time_email_deliveries"
    ADD CONSTRAINT "one_time_email_deliveries_emotion_feedback_id_fkey" FOREIGN KEY ("emotion_feedback_id") REFERENCES "public"."emotion_feedbacks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."one_time_email_deliveries"
    ADD CONSTRAINT "one_time_email_deliveries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pass_rollup_digests"
    ADD CONSTRAINT "pass_rollup_digests_user_pass_id_fkey" FOREIGN KEY ("user_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."submission_history"
    ADD CONSTRAINT "submission_history_emotion_entry_id_fkey" FOREIGN KEY ("emotion_entry_id") REFERENCES "public"."emotion_entries"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."submission_history"
    ADD CONSTRAINT "submission_history_user_pass_id_fkey" FOREIGN KEY ("user_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."submission_state"
    ADD CONSTRAINT "submission_state_emotion_entry_id_fkey" FOREIGN KEY ("emotion_entry_id") REFERENCES "public"."emotion_entries"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."submission_state"
    ADD CONSTRAINT "submission_state_user_pass_id_fkey" FOREIGN KEY ("user_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_passes"
    ADD CONSTRAINT "user_passes_pass_id_fkey" FOREIGN KEY ("pass_id") REFERENCES "public"."passes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."user_passes"
    ADD CONSTRAINT "user_passes_prev_pass_id_fkey" FOREIGN KEY ("prev_pass_id") REFERENCES "public"."user_passes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."user_passes"
    ADD CONSTRAINT "user_passes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE RESTRICT;



ALTER TABLE "public"."ai_task_runs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."analysis_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."emotion_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."emotion_feedbacks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."one_time_email_deliveries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pass_rollup_digests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."passes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rpc_debug_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."standard_emotions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."submission_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."submission_state" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_passes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;



GRANT ALL ON FUNCTION "public"."append_submission_log"("p_sid" "text", "p_msg" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."seed_and_record_submission"("p_sid" "text", "p_uuid_code" "text", "p_user_pass_id" "uuid", "p_user_id" "uuid", "p_reason" "text", "p_ip" "inet", "p_user_agent" "text", "p_latency_ms" integer) TO "service_role";



RESET ALL;
