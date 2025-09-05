alter table "public"."emotion_feedbacks" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."user_passes" alter column "purchased_at" drop not null;

alter table "public"."user_passes" alter column "updated_at" set default now();

CREATE UNIQUE INDEX uq_ar_user_pass_scope_status ON public.analysis_requests USING btree (user_pass_id, scope, status);

CREATE UNIQUE INDEX uq_emotion_feedbacks_entry ON public.emotion_feedbacks USING btree (emotion_entry_id);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.ingest_entry_and_rollup(p_sid text, p_user_pass_id uuid, p_user_id uuid, p_entry jsonb, p_new_digest text, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
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
end;
$function$
;

CREATE OR REPLACE FUNCTION public.save_feedback_and_finish(p_entry_id uuid, p_sid text, p_feedback_text text, p_gpt_model_used text, p_temperature double precision DEFAULT 0.25, p_token_count integer DEFAULT 0, p_language text DEFAULT 'ko'::text)
 RETURNS TABLE(entry_id uuid, feedback_id uuid, sid text, state_after text, remaining_uses_after integer, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
  v_now     timestamptz := now();
  v_temp    double precision := least(greatest(coalesce(p_temperature,0.2),0.0),1.0);
  v_tokens  int := greatest(coalesce(p_token_count,0), 0);
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
      gpt_model_used, temperature, token_count, created_at, updated_at
    )
    values (
      gen_random_uuid(), p_entry_id, v_text, v_lang,
      coalesce(nullif(p_gpt_model_used,''), 'gpt-3.5-turbo'),
      v_temp, v_tokens, v_now, v_now
    )
    on conflict (emotion_entry_id) do update
      set feedback_text  = excluded.feedback_text,
          language       = excluded.language,
          gpt_model_used = excluded.gpt_model_used,
          temperature    = excluded.temperature,
          token_count    = excluded.token_count,
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
      stats_json, model, token_used, created_at
    )
    select d.user_pass_id, 'pass', 'done', null, '',
           case when coalesce(prd.digest_text,'') <> ''
                then jsonb_build_object('carryover_digest', prd.digest_text)
                else null end,
           coalesce(nullif(p_gpt_model_used,''), 'gpt-3.5-turbo'), v_tokens, v_now
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

    insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
    values (case when v_pass is null then null else v_pass.id end, p_uuid_code, 'fail', v_reason, p_ip, p_user_agent, p_latency_ms, v_now);

    return jsonb_build_object('status','fail','reason',v_reason);
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

  insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
  values (v_pass.id, p_uuid_code, 'pass', 'ok', p_ip, p_user_agent, p_latency_ms, v_now);

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

CREATE OR REPLACE FUNCTION public.save_entry_feedback_and_finish(p_sid text, p_user_pass_id uuid, p_entry jsonb, p_feedback_text text, p_gpt_model_used text, p_temperature double precision DEFAULT 0.2, p_token_count integer DEFAULT 0, p_language text DEFAULT 'ko'::text, p_rollup_digest text DEFAULT NULL::text)
 RETURNS TABLE(status text, entry_id uuid, feedback_id uuid, remaining_uses_after integer, pass_done_created boolean, rollup_updated boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
  v_now             timestamptz := now();
  v_state           text;
  v_linked_id       uuid;
  v_user_id         uuid;
  v_remaining       int;
  v_entry_id        uuid;
  v_std_id          uuid;
  v_remaining_after int;
  v_ins_ar          int := 0;
  v_feedback_id     uuid;
  v_rollup_updated  boolean := false;

  -- JSON 추출(안전)
  v_raw_emotion     text := jsonb_extract_path_text(p_entry, 'raw_emotion');
  v_supposed        text := nullif(jsonb_extract_path_text(p_entry, 'supposed_emotion'), '');
  v_std_id_txt      text := nullif(jsonb_extract_path_text(p_entry, 'standard_emotion_id'), '');
  v_std_reason      text := nullif(jsonb_extract_path_text(p_entry, 'standard_emotion_reasoning'), '');
  v_sit_raw         text := jsonb_extract_path_text(p_entry, 'situation_raw');
  v_sit_sum         text := nullif(jsonb_extract_path_text(p_entry, 'situation_summary'), '');
  v_journal_raw     text := jsonb_extract_path_text(p_entry, 'journal_raw');
  v_journal_sum     text := nullif(jsonb_extract_path_text(p_entry, 'journal_summary'), '');
  v_label_level     text := jsonb_extract_path_text(p_entry, 'labels', 'level');
  v_label_type      text := jsonb_extract_path_text(p_entry, 'labels', 'feedback_type');
  v_label_speech    text := jsonb_extract_path_text(p_entry, 'labels', 'speech');

  v_temp            double precision := coalesce(p_temperature, 0.2);
  v_tokens          int := greatest(coalesce(p_token_count,0), 0);
  v_lang            text := coalesce(nullif(p_language,''), 'ko');
  v_fb_text         text := left(coalesce(p_feedback_text,''), 4000);
begin
  -- 0) 필수값 체크
  if p_sid is null or p_user_pass_id is null then
    status := 'error'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, null::int, false, false, updated_at;
  end if;
  if coalesce(v_raw_emotion,'')='' or coalesce(v_sit_raw,'')='' or coalesce(v_journal_raw,'')='' or
     coalesce(v_label_level,'')='' or coalesce(v_label_type,'')='' or coalesce(v_label_speech,'')='' then
    status := 'missing_required_fields'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, null::int, false, false, updated_at;
  end if;
  if length(v_fb_text)=0 then
    status := 'feedback_required'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, null::int, false, false, updated_at;
  end if;

  -- 1) 제출 상태 잠금/검증
  select submit_status, emotion_entry_id
    into v_state, v_linked_id
  from public.submission_state
  where sid = p_sid
  for update;

  if v_state is null then
    status := 'sid_not_found'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, null::int, false, false, updated_at;
  end if;

  if v_linked_id is not null then
    status := 'skipped'; updated_at := v_now;
    return query select status, v_linked_id, null::uuid, null::int, false, false, updated_at;
  end if;

  if v_state <> 'ready' then
    status := 'bad_state'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, null::int, false, false, updated_at;
  end if;

  -- 2) 패스/잔여 회차 잠금
  select up.user_id, coalesce(up.remaining_uses,0)
    into v_user_id, v_remaining
  from public.user_passes up
  where up.id = p_user_pass_id
  for update;

  if v_user_id is null then
    status := 'user_id_null'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, null::int, false, false, updated_at;
  end if;
  if v_remaining <= 0 then
    status := 'no_remaining'; updated_at := v_now;
    return query select status, null::uuid, null::uuid, v_remaining, false, false, updated_at;
  end if;

  -- 3) standard_emotion_id 캐스팅
  if v_std_id_txt is not null then
    v_std_id := v_std_id_txt::uuid;
  else
    v_std_id := null;
  end if;

  -- 4) entry INSERT (status='ready')
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
    created_at,
    status,
    error_reason
  ) values (
    gen_random_uuid(), p_user_pass_id, v_user_id,
    v_raw_emotion, v_supposed,
    v_std_id, v_std_reason,
    v_sit_raw, v_sit_sum,
    v_journal_raw, v_journal_sum,
    v_label_level, v_label_type, v_label_speech,
    false,
    v_now,
    'ready',
    null
  )
  returning id into v_entry_id;

  -- 5) 회차 차감
  update public.user_passes
     set remaining_uses = v_remaining - 1,
         first_used_at  = coalesce(first_used_at, v_now),
         updated_at     = v_now
   where id = p_user_pass_id
  returning remaining_uses into v_remaining_after;

  -- 6) 패스 소진 시 분석요청 done 1건 멱등 생성
  if v_remaining_after = 0 then
    insert into public.analysis_requests(
      user_pass_id, scope, status, reason,
      analysis_text, stats_json, model, token_used
    ) values (
      p_user_pass_id, 'pass', 'done', null,
      '',
      null,
      coalesce(nullif(p_gpt_model_used,''), 'gpt-3.5-turbo'),
      v_tokens
    )
    on conflict (user_pass_id, scope, status) do nothing;

    -- row_count를 정수로 받아서 나중에 비교(부등호 회피)
    get diagnostics v_ins_ar = row_count;
  end if;

  -- 7) 피드백 UPSERT (엔트리당 1건 정책)
  insert into public.emotion_feedbacks(
    id, emotion_entry_id, feedback_text, language,
    gpt_model_used, temperature, token_count, created_at
  ) values (
    gen_random_uuid(), v_entry_id, v_fb_text, v_lang,
    coalesce(nullif(p_gpt_model_used,''), 'gpt-3.5-turbo'),
    least(greatest(v_temp,0.0),1.0), v_tokens, v_now
  )
  on conflict (emotion_entry_id) do update
    set feedback_text  = excluded.feedback_text,
        language       = excluded.language,
        gpt_model_used = excluded.gpt_model_used,
        temperature    = excluded.temperature,
        token_count    = excluded.token_count,
        created_at     = excluded.created_at
  returning id into v_feedback_id;

  -- 8) 엔트리 플래그 & 제출 상태 done
  update public.emotion_entries
     set is_feedback_generated = true,
         feedback_generated_at = coalesce(feedback_generated_at, v_now)
   where id = v_entry_id;

  update public.submission_state
     set emotion_entry_id = v_entry_id,
         submit_status    = 'done',
         updated_at       = v_now
   where sid = p_sid
  returning updated_at into updated_at;

  perform public.append_submission_log(p_sid, format('entry_linked=%s', v_entry_id));
  perform public.append_submission_log(p_sid, 'feedback_saved and done');

  -- 9) (옵션) 롤업 갱신
  if p_rollup_digest is not null then
    perform public.upsert_pass_rollup_digest(p_user_pass_id, p_rollup_digest);
    v_rollup_updated := true;
    perform public.append_submission_log(p_sid, 'rollup_upserted');
  end if;

  status := 'ok';
  pass_done_created := (v_ins_ar <> 0);
  rollup_updated := v_rollup_updated;

  return query
    select status, v_entry_id, v_feedback_id, v_remaining_after, pass_done_created, rollup_updated, updated_at;
end;$function$
;

CREATE OR REPLACE FUNCTION public.upsert_entry_decrement_and_link(p_sid text, p_user_pass_id uuid, p_entry jsonb, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
  v_now             timestamptz := now();
  v_state           text;
  v_linked_id       uuid;
  v_user_id         uuid;
  v_remaining       int;
  v_entry_id        uuid;
  v_std_id          uuid;
  v_remaining_after int;
  v_digest          text;
  v_ins_ar          int := 0;
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
    created_at,
    status,
    error_reason
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
    v_now,
    'ready',
    null
  )
  returning id into v_entry_id;

  -- 회차 차감 + 최초 사용 시각
  update public.user_passes
     set remaining_uses = v_remaining - 1,
         first_used_at  = coalesce(first_used_at, v_now),
         updated_at     = v_now
   where id = p_user_pass_id
  returning remaining_uses into v_remaining_after;

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
      case when coalesce(v_digest,'')<>'' then jsonb_build_object('carryover_digest', v_digest) else null end,
      'gpt-3.5-turbo', 0
    )
    on conflict on constraint uq_ar_pass_done do nothing;

    get diagnostics v_ins_ar = row_count;
  end if;
  
  -- 링크 + 로그 캡
  update public.submission_state
     set emotion_entry_id = v_entry_id,
         updated_at = v_now
   where sid = p_sid;

  perform public.append_submission_log(p_sid, format('entry_linked=%s', v_entry_id));

  return jsonb_build_object(
    'status','ok',
    'entry_id', v_entry_id,
    'remaining_uses_after', v_remaining_after,
    'pass_done_created', (v_ins_ar > 0)
  );
end;$function$
;


