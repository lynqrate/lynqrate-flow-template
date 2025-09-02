begin;

-- ===============================================================
-- 0) 안전한 인덱스들 (있으면 건너뜀)
-- ===============================================================
create unique index if not exists uq_ar_pass_done
  on public.analysis_requests(user_pass_id)
  where scope='pass' and status='done';

create unique index if not exists uq_ar_pass_pending
  on public.analysis_requests(user_pass_id)
  where scope='pass' and status='pending';

-- 엔트리당 피드백 1건 정책(원하면 유지 / 여러개 허용이면 주석처리)
create unique index if not exists uq_emotion_feedbacks_one_per_entry
  on public.emotion_feedbacks(emotion_entry_id);

-- ===============================================================
-- 1) 로그 헬퍼: 앞 구분자 방지 + 4000자 캡 + 타임스탬프 통일
-- ===============================================================
create or replace function public.append_submission_log(p_sid text, p_msg text)
returns void
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_now text := to_char(now(),'YYYY-MM-DD HH24:MI:SS');
  v_line text := format('%s ts=%s', p_msg, v_now);
begin
  update public.submission_state
     set status_log = case
           when coalesce(status_log,'') = '' then v_line
           else status_log || ' | ' || v_line
         end,
         updated_at = now()
   where sid = p_sid;

  update public.submission_state
     set status_log = right(status_log, 4000)
   where sid = p_sid;
end;
$func$;

grant execute on function public.append_submission_log(text, text) to service_role;

-- ===============================================================
-- 2) init_validate_and_attach_user  → 존재확인 SELECT 축소(UPSERT) + 로그 1회
-- ===============================================================
create or replace function public.init_validate_and_attach_user(
  p_sid text,
  p_uuid_code text,
  p_required jsonb,
  p_email text default null,
  p_ip inet default null,
  p_user_agent text default null,
  p_latency_ms int default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $func$
declare
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
    insert into users (is_guest, email_pending)
    values (true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end)
    returning id into v_user_id;

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
end;
$func$;

grant execute on function public.init_validate_and_attach_user(
  text, text, jsonb, text, inet, text, integer
) to service_role;

-- ===============================================================
-- 3) seed_and_record_submission  → 프리체크 제거(ON CONFLICT) + 로그 헬퍼
-- ===============================================================
create or replace function public.seed_and_record_submission(
  p_sid text,
  p_uuid_code text,
  p_user_pass_id uuid,
  p_user_id uuid,
  p_reason text,
  p_ip inet default null,
  p_user_agent text default null,
  p_latency_ms int default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_now timestamptz := now();
  v_state text;
  v_status text := 'seeded';
  v_reason text := p_reason;
  v_seed text := '';
  v_seed_source text := 'empty';
  v_prev_pass_id uuid;
  v_inserted int := 0;
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

  -- 새 digest 시도 → 있으면 skip
  insert into pass_rollup_digests(user_pass_id, digest_text, last_entry_no)
  values (p_user_pass_id, '', 0)
  on conflict (user_pass_id) do nothing;

  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    v_status := 'skipped';
    v_reason := 'digest_exists';
  else
    -- 이전 pass에서 시드 소스 탐색
    select up.id into v_prev_pass_id
    from user_passes up
    where up.user_id = p_user_id
      and up.id <> p_user_pass_id
    order by up.created_at desc
    limit 1;

    if v_prev_pass_id is not null then
      select ar.stats_json->>'carryover_digest' into v_seed
      from analysis_requests ar
      where ar.user_pass_id = v_prev_pass_id
        and ar.scope='pass'
        and ar.status='done'
      order by ar.created_at desc
      limit 1;

      if coalesce(v_seed,'') = '' then
        select prd.digest_text into v_seed
        from pass_rollup_digests prd
        where prd.user_pass_id = v_prev_pass_id;

        v_seed_source := case when coalesce(v_seed,'')<>'' then 'prev_pass_digest' else 'empty' end;
      else
        v_seed_source := 'carryover_digest';
      end if;
    end if;

    update pass_rollup_digests
       set digest_text = coalesce(v_seed,'')
     where user_pass_id = p_user_pass_id;
  end if;

  perform public.append_submission_log(
    p_sid,
    format('seed status=%s seed_source=%s prev_pass_id=%s', v_status, v_seed_source, coalesce(v_prev_pass_id::text,'-'))
  );

  return jsonb_build_object(
    'status', v_status,
    'seed_source', v_seed_source,
    'prev_pass_id', v_prev_pass_id,
    'seed_len', coalesce(length(v_seed),0)
  );
end;
$func$;

grant execute on function public.seed_and_record_submission(
  text, text, uuid, uuid, text, inet, text, integer
) to service_role;

-- ===============================================================
-- 4) upsert_entry_decrement_and_link → I/O 줄임 + 로그 헬퍼 사용
--     - entry INSERT 시 status='ready'
--     - pass 회차 차감 + 0이면 analysis_requests done 멱등 생성
-- ===============================================================
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
as $func$
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
  v_ins_ar          int := 0;
begin
  if p_sid is null or p_user_pass_id is null then
    return jsonb_build_object('status','error','reason','missing_sid_or_pass');
  end if;

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

  if (p_entry ? 'standard_emotion_id')
     and jsonb_typeof(p_entry->'standard_emotion_id')='string'
     and nullif(p_entry->>'standard_emotion_id','') is not null then
    v_std_id := (p_entry->>'standard_emotion_id')::uuid;
  else
    v_std_id := null;
  end if;

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
end;
$func$;

grant execute on function public.upsert_entry_decrement_and_link(
  text, uuid, jsonb, inet, text
) to service_role;

-- ===============================================================
-- 5) mark_feedback_save_and_done (UPSERT형: 엔트리당 1건 정책)
--    - 여러 번 저장 허용하려면 ON CONFLICT 절을 제거
-- ===============================================================
create or replace function public.mark_feedback_save_and_done(
  p_entry_id        uuid,
  p_sid             text,
  p_feedback_text   text,
  p_gpt_model_used  text,
  p_temperature     double precision default 0.2,
  p_token_count     integer          default 0,
  p_language        text             default 'ko'
)
returns table (
  entry_id uuid,
  feedback_id uuid,
  sid text,
  state_after text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_now timestamptz := now();
  v_temp double precision := coalesce(p_temperature, 0.2);
  v_tokens int := greatest(coalesce(p_token_count,0), 0);
  v_lang text := coalesce(nullif(p_language,''), 'ko');
  v_text text := left(coalesce(p_feedback_text,''), 4000);
begin
  if length(v_text)=0 then
    raise exception 'feedback_text required';
  end if;

  insert into public.emotion_feedbacks(
    id, emotion_entry_id, feedback_text, language,
    gpt_model_used, temperature, token_count, created_at
  ) values (
    gen_random_uuid(), p_entry_id, v_text, v_lang,
    coalesce(nullif(p_gpt_model_used,''), 'gpt-3.5-turbo'), least(greatest(v_temp,0.0),1.0), v_tokens, v_now
  )
  on conflict (emotion_entry_id) do update
    set feedback_text = excluded.feedback_text,
        language      = excluded.language,
        gpt_model_used= excluded.gpt_model_used,
        temperature   = excluded.temperature,
        token_count   = excluded.token_count,
        created_at    = excluded.created_at
  returning id into feedback_id;

  update public.emotion_entries
     set is_feedback_generated = true,
         feedback_generated_at = coalesce(feedback_generated_at, v_now)
   where id = p_entry_id;

  update public.submission_state
     set submit_status = 'done',
         updated_at    = v_now
   where sid = p_sid
  returning p_entry_id, sid, submit_status, updated_at
  into entry_id, sid, state_after, updated_at;

  perform public.append_submission_log(p_sid, format('feedback_saved entry=%s', p_entry_id));

  return next;
end;
$func$;

grant execute on function public.mark_feedback_save_and_done(
  uuid, text, text, text, double precision, integer, text
) to service_role;

commit;