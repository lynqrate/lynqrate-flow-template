alter table "public"."submission_history" add column "error_json" jsonb;

alter table "public"."submission_history" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."user_passes" alter column "source" set default 'kmong'::text;

set check_function_bodies = off;

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


