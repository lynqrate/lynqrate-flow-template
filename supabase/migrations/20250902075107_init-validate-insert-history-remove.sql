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

  -- 3) pass 조회/유효성 (잠금 포함)
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

  -- 4) 이메일 검증(선택)
  if v_reason is null and coalesce(btrim(p_email),'') <> '' then
    v_norm := normalize_and_validate_email(p_email);
    if v_norm is null then
      v_reason := 'invalid_email';
    else
      p_email := v_norm;
    end if;
  end if;

  -- 5) 실패 분기: 상태/히스토리 기록 후 반환
  if v_reason is not null then
    update submission_state
       set user_pass_id = case when v_pass is null then null else v_pass.id end,
           uuid_code = p_uuid_code,
           submit_status = 'fail',
           status_reason = v_reason,
           updated_at    = v_now,
           status_log    = concat_ws(' | ', nullif(status_log,''), format('init fail reason=%s ts=%s', v_reason, to_char(v_now,'YYYY-MM-DD HH24:MI:SS')))
     where sid = p_sid;

    update submission_state
       set status_log = right(status_log, 4000),
           updated_at = v_now
     where sid = p_sid;

    insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
    values (case when v_pass is null then null else v_pass.id end, p_uuid_code, 'fail', v_reason, p_ip, p_user_agent, p_latency_ms, v_now);

    return jsonb_build_object('status','fail','reason',v_reason);
  end if;

  -- 6) user 매핑
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
    perform 1 from users where id = v_user_id;
    if not found then
      insert into users (id, is_guest, email_pending)
      values (v_user_id, true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end);
    else
      if coalesce(btrim(p_email),'') <> '' then
        update users
           set email_pending = p_email,
               updated_at    = v_now
         where id = v_user_id;
      end if;
    end if;
  end if;

  -- 7) ✅ 성공 시 히스토리 인서트는 생략 (seed에서 기록)
  -- insert into submission_history(...)  -- 제거

  -- 8) state를 ready로
  update submission_state
     set user_pass_id = v_pass.id,
         uuid_code    = p_uuid_code,
         submit_status= 'ready',
         status_reason= 'validation_success',
         status_log   = right(coalesce(status_log,''), 4000),
         updated_at   = v_now
   where sid = p_sid;

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
end
$func$;