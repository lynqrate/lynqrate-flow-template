-- file: 2025-09-02-save-entry-feedback-and-finish.sql
begin;

-- 0) 사전 보강: 컬럼/인덱스
alter table public.emotion_entries
  add column if not exists feedback_generated_at timestamptz;

create unique index if not exists uq_feedback_per_entry
  on public.emotion_feedbacks(emotion_entry_id);

-- (참고) 패스 종료 done 멱등용 인덱스(이미 있으면 스킵됨)
create unique index if not exists uq_ar_pass_done
  on public.analysis_requests(user_pass_id)
  where scope='pass' and status='done';

-- 2) 롤업 업서트(헬퍼) - 제약명으로 충돌 지정
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
set search_path = public
as $rollup$
begin
  return query
  insert into public.pass_rollup_digests as d (user_pass_id, digest_text, last_entry_no)
  values (p_user_pass_id, coalesce(p_digest_text,''), 1)
  on conflict on constraint pass_rollup_digests_user_pass_id_key
  do update
    set digest_text   = excluded.digest_text,
        last_entry_no = greatest(d.last_entry_no, 0) + 1,
        updated_at    = now()
  returning d.id, d.user_pass_id, d.digest_text, d.last_entry_no, d.created_at, d.updated_at;
end;
$rollup$;

grant execute on function public.upsert_pass_rollup_digest(uuid, text) to service_role;

-- 3) 통합 RPC: 엔트리 저장 → 차감/링크 → 피드백 저장 → done (+옵션: 롤업)
create or replace function public.save_entry_feedback_and_finish(
  p_sid              text,
  p_user_pass_id     uuid,
  p_entry            jsonb,                -- {raw_emotion, situation_raw, journal_raw, labels{level,feedback_type,speech}, ...}
  p_feedback_text    text,
  p_gpt_model_used   text,
  p_temperature      double precision default 0.2,
  p_token_count      integer          default 0,
  p_language         text             default 'ko',
  p_rollup_digest    text             default null   -- 있으면 롤업까지 수행
)
returns table (
  status text,
  entry_id uuid,
  feedback_id uuid,
  remaining_uses_after int,
  pass_done_created boolean,
  rollup_updated boolean,
  updated_at timestamptz
)
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
    on conflict on constraint uq_ar_pass_done do nothing;

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
end;
$func$;

grant execute on function public.save_entry_feedback_and_finish(
  text, uuid, jsonb, text, text, double precision, integer, text, text
) to service_role;

commit;