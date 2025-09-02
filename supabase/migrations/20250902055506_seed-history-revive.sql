begin;

create or replace function seed_and_record_submission(
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
as $$
declare
  v_now timestamptz := now();
  v_state text;
  v_status text := 'seeded';
  v_reason text := p_reason;
  v_seed text := '';
  v_seed_source text := 'empty';
  v_prev_pass_id uuid;
  v_digest_exists boolean;
begin
  --------------------------------------------------------------------
  -- 0) 유효성 게이트: submission_state 가 'ready' 이어야 진행
  --------------------------------------------------------------------
  select submit_status
    into v_state
  from submission_state
  where sid = p_sid;

  if v_state is distinct from 'ready' then
    -- 상태 로그만 남기고 에러
    update submission_state
       set status_log = concat_ws(' | ', coalesce(status_log,''), format(
             'seed status=error reason=bad_state ts=%s', to_char(v_now,'YYYY-MM-DD HH24:MI:SS')
           )),
           updated_at = v_now
     where sid = p_sid;

    -- history 기록 (fail)
    insert into submission_history(
      user_pass_id, uuid_code, result_status, result_reason,
      ip, user_agent, latency_ms, created_at
    ) values (
      p_user_pass_id, p_uuid_code, 'fail', 'bad_state',
      p_ip, p_user_agent, p_latency_ms, v_now
    );

    return jsonb_build_object('status','error','reason','bad_state');
  end if;

  --------------------------------------------------------------------
  -- 1) user_pass 검증 (uuid_code, user_id, is_active 일치)
  --------------------------------------------------------------------
  perform 1
  from user_passes
  where id = p_user_pass_id
    and user_id = p_user_id
    and uuid_code = p_uuid_code
    and is_active = true
  for update;

  if not found then
    update submission_state
       set status_log = concat_ws(' | ', coalesce(status_log,''), format(
             'seed status=error reason=mismatch_or_inactive ts=%s', to_char(v_now,'YYYY-MM-DD HH24:MI:SS')
           )),
           updated_at = v_now
     where sid = p_sid;

    insert into submission_history(
      user_pass_id, uuid_code, result_status, result_reason,
      ip, user_agent, latency_ms, created_at
    ) values (
      p_user_pass_id, p_uuid_code, 'fail', 'mismatch_or_inactive',
      p_ip, p_user_agent, p_latency_ms, v_now
    );

    return jsonb_build_object('status','error','reason','mismatch_or_inactive');
  end if;

  --------------------------------------------------------------------
  -- 2) 시드 주입(멱등): 이미 digest 있으면 skip
  --------------------------------------------------------------------
  select exists(select 1 from pass_rollup_digests where user_pass_id = p_user_pass_id)
    into v_digest_exists;

  if v_digest_exists then
    v_status := 'skipped';
    v_reason := 'digest_exists';
  else
    -- 직전 pass 찾기
    select up.id
      into v_prev_pass_id
    from user_passes up
    where up.user_id = p_user_id
      and up.id is distinct from p_user_pass_id
    order by up.created_at desc
    limit 1;

    if v_prev_pass_id is not null then
      -- 1순위: carryover_digest
      select ar.stats_json->>'carryover_digest'
        into v_seed
      from analysis_requests ar
      where ar.user_pass_id = v_prev_pass_id
        and ar.scope='pass'
        and ar.status='done'
      order by ar.created_at desc
      limit 1;

      if coalesce(length(v_seed),0) = 0 then
        -- 2순위: 직전 pass digest
        select prd.digest_text
          into v_seed
        from pass_rollup_digests prd
        where prd.user_pass_id = v_prev_pass_id;

        v_seed_source := case when coalesce(length(v_seed),0) <> 0 then 'prev_pass_digest' else 'empty' end;
      else
        v_seed_source := 'carryover_digest';
      end if;
    end if;

    -- 새 pass digest 초기화
    insert into pass_rollup_digests(user_pass_id, digest_text, last_entry_no)
    values (p_user_pass_id, coalesce(v_seed,''), 0)
    on conflict (user_pass_id) do nothing;
  end if;

  --------------------------------------------------------------------
  -- 3) 상태 로그 append + 캡
  --------------------------------------------------------------------
  update submission_state
     set status_log = concat_ws(' | ', coalesce(status_log,''), format(
           'seed status=%s seed_source=%s prev_pass_id=%s ts=%s',
           v_status, v_seed_source, coalesce(v_prev_pass_id::text,'-'), to_char(v_now,'YYYY-MM-DD HH24:MI:SS')
         )),
         updated_at = v_now
   where sid = p_sid;

  update submission_state
     set status_log = right(coalesce(status_log,''), 4000),
         updated_at = v_now
   where sid = p_sid;

  --------------------------------------------------------------------
  -- 4) ✅ seed 결과를 history에도 한 줄 기록 (운영 가시성)
  --------------------------------------------------------------------
  insert into submission_history(
    user_pass_id, uuid_code, result_status, result_reason,
    ip, user_agent, latency_ms, created_at
  ) values (
    p_user_pass_id,
    p_uuid_code,
    case when v_status = 'seeded' then 'pass' else 'pass' end,  -- seeded/ skipped 둘 다 성공 범주
    v_reason,
    p_ip, p_user_agent, p_latency_ms, v_now
  );

  return jsonb_build_object(
    'status', v_status,
    'seed_source', v_seed_source,
    'prev_pass_id', v_prev_pass_id,
    'seed_len', coalesce(length(v_seed),0)
  );
end $$;

commit;