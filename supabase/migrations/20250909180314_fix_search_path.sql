-- 함수 재정의 (예시 clean_visible_text)
create or replace function public.clean_visible_text(p_text text)
returns text
language sql
immutable
set search_path = pg_catalog
as $fn$
  select trim(
           regexp_replace(
             regexp_replace(coalesce(p_text,''),
               E'[\\u200B\\u200C\\u200D\\uFEFF]', '', 'g'
             ),
             E'\\u00A0', ' ', 'g'
           )
         );
$fn$;
alter function public.clean_visible_text(text)
  set search_path = pg_catalog;

-- normalize_whitespace
create or replace function public.normalize_whitespace(p_text text)
returns text
language sql
immutable
set search_path = pg_catalog
as $fn$
  select regexp_replace(
           regexp_replace(coalesce(p_text,''),
             E'[\\u00A0\\u200B\\uFEFF]', '', 'g'
           ),
           E'[\\s]+', '', 'g'
         );
$fn$;
alter function public.normalize_whitespace(text)
  set search_path = pg_catalog;

-- mark_submission_fail
create or replace function public.mark_submission_fail(
  p_sid text, p_reason text, p_history_id bigint default null,
  p_error_json jsonb default null, p_ip inet default null,
  p_user_agent text default null, p_latency_ms integer default null,
  p_emotion_entry_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
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
$function$;
