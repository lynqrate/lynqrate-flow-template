drop function if exists "public"."mark_feedback_and_done"(p_entry_id uuid, p_sid text);

drop function if exists "public"."mark_feedback_save_and_done"(p_entry_id uuid, p_sid text, p_feedback_text text, p_gpt_model_used text, p_temperature double precision, p_token_count integer, p_language text);

drop function if exists "public"."save_entry_feedback_and_finish"(p_sid text, p_user_pass_id uuid, p_entry jsonb, p_feedback_text text, p_gpt_model_used text, p_temperature double precision, p_token_count integer, p_language text, p_rollup_digest text);

drop function if exists "public"."upsert_entry_decrement_and_link"(p_sid text, p_user_pass_id uuid, p_entry jsonb, p_ip inet, p_user_agent text);

drop function if exists "public"."upsert_pass_rollup_digest"(p_user_pass_id uuid, p_digest_text text);

CREATE INDEX idx_user_passes_user_pass_time ON public.user_passes USING btree (user_id, pass_id, purchased_at DESC, created_at DESC);

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

CREATE OR REPLACE FUNCTION public.seed_and_record_submission(p_sid text, p_uuid_code text, p_user_pass_id uuid, p_user_id uuid, p_reason text, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_latency_ms integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
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
end;$function$
;


