drop extension if exists "pg_net";

create extension if not exists pgcrypto;

create sequence "public"."submission_history_id_seq";


  create table "public"."analysis_requests" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid,
    "user_pass_id" uuid,
    "scope" text not null,
    "status" text not null default 'pending'::text,
    "reason" text,
    "analysis_text" text not null,
    "stats_json" jsonb,
    "model" text not null,
    "token_used" integer not null default 0,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."analysis_requests" enable row level security;


  create table "public"."emotion_entries" (
    "id" uuid not null default gen_random_uuid(),
    "user_pass_id" uuid not null,
    "user_id" uuid,
    "raw_emotion_text" text not null,
    "supposed_emotion_text" text,
    "standard_emotion_id" uuid,
    "standard_emotion_reasoning" text,
    "situation_raw_text" text not null,
    "situation_summary_text" text,
    "journal_raw_text" text not null,
    "journal_summary_text" text,
    "created_at" timestamp with time zone not null default now(),
    "is_feedback_generated" boolean default false,
    "status" text not null default 'pending'::text,
    "error_reason" text,
    "emotion_level_label_snapshot" text not null,
    "feedback_type_label_snapshot" text not null,
    "feedback_speech_label_snapshot" text not null
      );


alter table "public"."emotion_entries" enable row level security;


  create table "public"."emotion_feedbacks" (
    "id" uuid not null default gen_random_uuid(),
    "emotion_entry_id" uuid not null,
    "feedback_text" text not null,
    "language" text not null default 'ko'::text,
    "gpt_model_used" text not null,
    "temperature" double precision not null,
    "token_count" integer not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."emotion_feedbacks" enable row level security;


  create table "public"."one_time_email_deliveries" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid,
    "submission_id" uuid not null,
    "emotion_entry_id" uuid,
    "emotion_feedback_id" uuid,
    "purpose" text not null default 'feedback_result'::text,
    "email" text not null,
    "submit_status" text not null default 'pending'::text,
    "created_at" timestamp with time zone not null default now(),
    "sent_at" timestamp with time zone,
    "fail_reason" text,
    "expires_at" timestamp with time zone not null default (now() + '7 days'::interval),
    "deleted_at" timestamp with time zone
      );


alter table "public"."one_time_email_deliveries" enable row level security;


  create table "public"."pass_rollup_digests" (
    "id" uuid not null default gen_random_uuid(),
    "user_pass_id" uuid not null,
    "digest_text" text not null,
    "last_entry_no" integer not null default 0,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."pass_rollup_digests" enable row level security;


  create table "public"."passes" (
    "id" uuid not null default gen_random_uuid(),
    "name" text not null,
    "total_uses" integer not null,
    "price" integer not null,
    "description" text,
    "expires_after_days" integer,
    "create_at" timestamp with time zone not null default now()
      );


alter table "public"."passes" enable row level security;


  create table "public"."standard_emotions" (
    "id" uuid not null default gen_random_uuid(),
    "name" text not null,
    "description" text,
    "soft_order" integer not null,
    "color_code" text not null
      );


alter table "public"."standard_emotions" enable row level security;


  create table "public"."submission_history" (
    "id" bigint not null default nextval('submission_history_id_seq'::regclass),
    "user_pass_id" uuid,
    "emotion_entry_id" uuid,
    "uuid_code" text,
    "result_status" text not null,
    "result_reason" text,
    "ip" inet,
    "user_agent" text,
    "latency_ms" integer,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."submission_history" enable row level security;


  create table "public"."submission_state" (
    "sid" text not null,
    "user_pass_id" uuid,
    "emotion_entry_id" uuid,
    "uuid_code" text not null,
    "submit_status" text not null,
    "status_reason" text,
    "updated_at" timestamp with time zone not null default now(),
    "created_at" timestamp with time zone not null default now(),
    "status_log" text
      );


alter table "public"."submission_state" enable row level security;


  create table "public"."user_passes" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid,
    "pass_id" uuid not null,
    "remaining_uses" integer not null,
    "purchased_at" timestamp with time zone not null,
    "expires_at" timestamp with time zone,
    "uuid_code" text not null default lower(
  encode(extensions.gen_random_bytes(2), 'hex') || '-' ||
  encode(extensions.gen_random_bytes(2), 'hex') || '-' ||
  encode(extensions.gen_random_bytes(2), 'hex') || '-' ||
  encode(extensions.gen_random_bytes(2), 'hex')
),        
    "first_used_at" timestamp with time zone,
    "source" text not null default '''kmong''::text'::text,
    "source_order_id" text,
    "buyer_handle" text,
    "created_at" timestamp with time zone not null default now(),
    "is_active" boolean not null default true,
    "prev_pass_id" uuid
      );


alter table "public"."user_passes" enable row level security;


  create table "public"."users" (
    "id" uuid not null default gen_random_uuid(),
    "is_guest" boolean not null default true,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now(),
    "deleted_at" timestamp with time zone,
    "first_activity_at" timestamp with time zone default now(),
    "email" text,
    "email_verified" text,
    "email_pending" text,
    "email_verified_at" timestamp with time zone
      );


alter table "public"."users" enable row level security;

alter sequence "public"."submission_history_id_seq" owned by "public"."submission_history"."id";

CREATE UNIQUE INDEX analysis_requests_pkey ON public.analysis_requests USING btree (id);

CREATE UNIQUE INDEX emotion_entries_pkey ON public.emotion_entries USING btree (id);

CREATE UNIQUE INDEX emotion_feedbacks_pkey ON public.emotion_feedbacks USING btree (id);

CREATE INDEX idx_analysis_pass_created ON public.analysis_requests USING btree (user_pass_id, created_at DESC);

CREATE INDEX idx_analysis_user_created ON public.analysis_requests USING btree (user_id, created_at DESC);

CREATE INDEX idx_entries_pass_created ON public.emotion_entries USING btree (user_pass_id, created_at DESC);

CREATE INDEX idx_entries_user_created ON public.emotion_entries USING btree (user_id, created_at DESC);

CREATE INDEX idx_submission_history_created_at ON public.submission_history USING btree (created_at);

CREATE INDEX idx_submission_history_entry_id ON public.submission_history USING btree (emotion_entry_id);

CREATE INDEX idx_submission_history_result_reason ON public.submission_history USING btree (result_reason);

CREATE INDEX idx_submission_history_result_status ON public.submission_history USING btree (result_status);

CREATE INDEX idx_submission_history_user_pass_id ON public.submission_history USING btree (user_pass_id);

CREATE INDEX idx_submission_history_uuid_code ON public.submission_history USING btree (uuid_code);

CREATE INDEX idx_submission_state_status ON public.submission_state USING btree (submit_status);

CREATE INDEX idx_submission_state_updated_at ON public.submission_state USING btree (updated_at);

CREATE INDEX idx_submission_state_user_pass_id ON public.submission_state USING btree (user_pass_id);

CREATE INDEX idx_submission_state_uuid_code ON public.submission_state USING btree (uuid_code);

CREATE INDEX idx_user_passes_user_created ON public.user_passes USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX one_time_email_deliveries_pkey ON public.one_time_email_deliveries USING btree (id);

CREATE INDEX one_time_email_deliveries_submission_idx ON public.one_time_email_deliveries USING btree (submission_id);

CREATE UNIQUE INDEX pass_rollup_digests_pkey ON public.pass_rollup_digests USING btree (id);

CREATE UNIQUE INDEX pass_rollup_digests_user_pass_id_key ON public.pass_rollup_digests USING btree (user_pass_id);

CREATE UNIQUE INDEX passes_pkey ON public.passes USING btree (id);

CREATE UNIQUE INDEX standard_emotions_pkey ON public.standard_emotions USING btree (id);

CREATE UNIQUE INDEX submission_history_pkey ON public.submission_history USING btree (id);

CREATE UNIQUE INDEX submission_state_pkey ON public.submission_state USING btree (sid);

CREATE UNIQUE INDEX uq_ar_pass_done ON public.analysis_requests USING btree (user_pass_id) WHERE ((scope = 'pass'::text) AND (status = 'done'::text));

CREATE UNIQUE INDEX uq_ar_pass_open ON public.analysis_requests USING btree (user_pass_id) WHERE ((scope = 'pass'::text) AND (status = ANY (ARRAY['pending'::text, 'ready'::text])));

CREATE UNIQUE INDEX user_passes_pkey ON public.user_passes USING btree (id);

CREATE UNIQUE INDEX user_passes_source_order_uidx ON public.user_passes USING btree (source, source_order_id) WHERE (source_order_id IS NOT NULL);

CREATE UNIQUE INDEX user_passes_uuid_code_key ON public.user_passes USING btree (uuid_code);

CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);

CREATE UNIQUE INDEX users_email_verified_key ON public.users USING btree (email_verified);

CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id);

alter table "public"."analysis_requests" add constraint "analysis_requests_pkey" PRIMARY KEY using index "analysis_requests_pkey";

alter table "public"."emotion_entries" add constraint "emotion_entries_pkey" PRIMARY KEY using index "emotion_entries_pkey";

alter table "public"."emotion_feedbacks" add constraint "emotion_feedbacks_pkey" PRIMARY KEY using index "emotion_feedbacks_pkey";

alter table "public"."one_time_email_deliveries" add constraint "one_time_email_deliveries_pkey" PRIMARY KEY using index "one_time_email_deliveries_pkey";

alter table "public"."pass_rollup_digests" add constraint "pass_rollup_digests_pkey" PRIMARY KEY using index "pass_rollup_digests_pkey";

alter table "public"."passes" add constraint "passes_pkey" PRIMARY KEY using index "passes_pkey";

alter table "public"."standard_emotions" add constraint "standard_emotions_pkey" PRIMARY KEY using index "standard_emotions_pkey";

alter table "public"."submission_history" add constraint "submission_history_pkey" PRIMARY KEY using index "submission_history_pkey";

alter table "public"."submission_state" add constraint "submission_state_pkey" PRIMARY KEY using index "submission_state_pkey";

alter table "public"."user_passes" add constraint "user_passes_pkey" PRIMARY KEY using index "user_passes_pkey";

alter table "public"."users" add constraint "users_pkey" PRIMARY KEY using index "users_pkey";

alter table "public"."analysis_requests" add constraint "analysis_requests_scope_check" CHECK ((scope = ANY (ARRAY['pass'::text, 'user_all'::text]))) not valid;

alter table "public"."analysis_requests" validate constraint "analysis_requests_scope_check";

alter table "public"."analysis_requests" add constraint "analysis_requests_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'done'::text]))) not valid;

alter table "public"."analysis_requests" validate constraint "analysis_requests_status_check";

alter table "public"."analysis_requests" add constraint "analysis_requests_token_used_check" CHECK ((token_used >= 0)) not valid;

alter table "public"."analysis_requests" validate constraint "analysis_requests_token_used_check";

alter table "public"."analysis_requests" add constraint "analysis_requests_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL not valid;

alter table "public"."analysis_requests" validate constraint "analysis_requests_user_id_fkey";

alter table "public"."analysis_requests" add constraint "analysis_requests_user_pass_id_fkey" FOREIGN KEY (user_pass_id) REFERENCES user_passes(id) ON DELETE SET NULL not valid;

alter table "public"."analysis_requests" validate constraint "analysis_requests_user_pass_id_fkey";

alter table "public"."analysis_requests" add constraint "ck_analysis_scope_target" CHECK ((((scope = 'pass'::text) AND (user_pass_id IS NOT NULL) AND (user_id IS NULL)) OR ((scope = 'user_all'::text) AND (user_id IS NOT NULL) AND (user_pass_id IS NULL)))) not valid;

alter table "public"."analysis_requests" validate constraint "ck_analysis_scope_target";

alter table "public"."emotion_entries" add constraint "emotion_entries_standard_emotion_id_fkey" FOREIGN KEY (standard_emotion_id) REFERENCES standard_emotions(id) ON DELETE SET NULL not valid;

alter table "public"."emotion_entries" validate constraint "emotion_entries_standard_emotion_id_fkey";

alter table "public"."emotion_entries" add constraint "emotion_entries_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'ready'::text, 'error'::text]))) not valid;

alter table "public"."emotion_entries" validate constraint "emotion_entries_status_check";

alter table "public"."emotion_entries" add constraint "emotion_entries_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL not valid;

alter table "public"."emotion_entries" validate constraint "emotion_entries_user_id_fkey";

alter table "public"."emotion_entries" add constraint "emotion_entries_user_pass_id_fkey" FOREIGN KEY (user_pass_id) REFERENCES user_passes(id) ON DELETE CASCADE not valid;

alter table "public"."emotion_entries" validate constraint "emotion_entries_user_pass_id_fkey";

alter table "public"."emotion_feedbacks" add constraint "emotion_feedbacks_emotion_entry_id_fkey" FOREIGN KEY (emotion_entry_id) REFERENCES emotion_entries(id) ON DELETE CASCADE not valid;

alter table "public"."emotion_feedbacks" validate constraint "emotion_feedbacks_emotion_entry_id_fkey";

alter table "public"."one_time_email_deliveries" add constraint "one_time_email_deliveries_emotion_entry_id_fkey" FOREIGN KEY (emotion_entry_id) REFERENCES emotion_entries(id) ON DELETE CASCADE not valid;

alter table "public"."one_time_email_deliveries" validate constraint "one_time_email_deliveries_emotion_entry_id_fkey";

alter table "public"."one_time_email_deliveries" add constraint "one_time_email_deliveries_emotion_feedback_id_fkey" FOREIGN KEY (emotion_feedback_id) REFERENCES emotion_feedbacks(id) ON DELETE CASCADE not valid;

alter table "public"."one_time_email_deliveries" validate constraint "one_time_email_deliveries_emotion_feedback_id_fkey";

alter table "public"."one_time_email_deliveries" add constraint "one_time_email_deliveries_submit_status_check" CHECK ((submit_status = ANY (ARRAY['pending'::text, 'ready'::text, 'fail'::text]))) not valid;

alter table "public"."one_time_email_deliveries" validate constraint "one_time_email_deliveries_submit_status_check";

alter table "public"."one_time_email_deliveries" add constraint "one_time_email_deliveries_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL not valid;

alter table "public"."one_time_email_deliveries" validate constraint "one_time_email_deliveries_user_id_fkey";

alter table "public"."pass_rollup_digests" add constraint "pass_rollup_digests_last_entry_no_check" CHECK ((last_entry_no >= 0)) not valid;

alter table "public"."pass_rollup_digests" validate constraint "pass_rollup_digests_last_entry_no_check";

alter table "public"."pass_rollup_digests" add constraint "pass_rollup_digests_user_pass_id_fkey" FOREIGN KEY (user_pass_id) REFERENCES user_passes(id) ON DELETE CASCADE not valid;

alter table "public"."pass_rollup_digests" validate constraint "pass_rollup_digests_user_pass_id_fkey";

alter table "public"."pass_rollup_digests" add constraint "pass_rollup_digests_user_pass_id_key" UNIQUE using index "pass_rollup_digests_user_pass_id_key";

alter table "public"."submission_history" add constraint "submission_history_emotion_entry_id_fkey" FOREIGN KEY (emotion_entry_id) REFERENCES emotion_entries(id) ON DELETE SET NULL not valid;

alter table "public"."submission_history" validate constraint "submission_history_emotion_entry_id_fkey";

alter table "public"."submission_history" add constraint "submission_history_result_status_check" CHECK ((result_status = ANY (ARRAY['pass'::text, 'fail'::text, 'error'::text]))) not valid;

alter table "public"."submission_history" validate constraint "submission_history_result_status_check";

alter table "public"."submission_history" add constraint "submission_history_user_pass_id_fkey" FOREIGN KEY (user_pass_id) REFERENCES user_passes(id) ON DELETE SET NULL not valid;

alter table "public"."submission_history" validate constraint "submission_history_user_pass_id_fkey";

alter table "public"."submission_state" add constraint "submission_state_emotion_entry_id_fkey" FOREIGN KEY (emotion_entry_id) REFERENCES emotion_entries(id) ON DELETE SET NULL not valid;

alter table "public"."submission_state" validate constraint "submission_state_emotion_entry_id_fkey";

alter table "public"."submission_state" add constraint "submission_state_submit_status_check" CHECK ((submit_status = ANY (ARRAY['pending'::text, 'fail'::text, 'ready'::text, 'done'::text]))) not valid;

alter table "public"."submission_state" validate constraint "submission_state_submit_status_check";

alter table "public"."submission_state" add constraint "submission_state_user_pass_id_fkey" FOREIGN KEY (user_pass_id) REFERENCES user_passes(id) ON DELETE SET NULL not valid;

alter table "public"."submission_state" validate constraint "submission_state_user_pass_id_fkey";

alter table "public"."user_passes" add constraint "user_passes_pass_id_fkey" FOREIGN KEY (pass_id) REFERENCES passes(id) ON DELETE RESTRICT not valid;

alter table "public"."user_passes" validate constraint "user_passes_pass_id_fkey";

alter table "public"."user_passes" add constraint "user_passes_prev_pass_id_fkey" FOREIGN KEY (prev_pass_id) REFERENCES user_passes(id) ON DELETE RESTRICT not valid;

alter table "public"."user_passes" validate constraint "user_passes_prev_pass_id_fkey";

alter table "public"."user_passes" add constraint "user_passes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT not valid;

alter table "public"."user_passes" validate constraint "user_passes_user_id_fkey";

alter table "public"."user_passes" add constraint "user_passes_uuid_code_key" UNIQUE using index "user_passes_uuid_code_key";

alter table "public"."users" add constraint "users_email_key" UNIQUE using index "users_email_key";

alter table "public"."users" add constraint "users_email_verified_key" UNIQUE using index "users_email_verified_key";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.clean_visible_text(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select
    trim(  -- 앞/뒤 공백, 탭, 개행 정리
      regexp_replace(
        regexp_replace(
          coalesce(p_text,''),
          E'[\\u200B\\u200C\\u200D\\uFEFF]',  -- 제로폭/ BOM 제거
          '', 'g'
        ),
        E'\\u00A0',                           -- NBSP → 일반 공백
        ' ', 'g'
      )
    )
$function$
;

CREATE OR REPLACE FUNCTION public.get_rollup_context(p_user_pass_id uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
with pass_info as (
  -- 패스 메타 정보 (진행도 계산용)
  select
    up.user_id,
    coalesce(up.remaining_uses, 0) as remaining_uses,    -- NULL일 경우 0으로
    p.total_uses,
    -- 다음 엔트리 번호 (최소 1, 최대 total_uses 범위로 보정)
    greatest(1, least(p.total_uses,
      (p.total_uses - coalesce(up.remaining_uses, 0) + 1)
    )) as entry_no_next
  from user_passes up
  join passes p on p.id = up.pass_id
  where up.id = p_user_pass_id
),
prd as (
  -- 롤업 요약(digest)
  select
    coalesce(digest_text, '') as digest_text,      -- NULL일 경우 빈 문자열
    coalesce(last_entry_no, 0) as last_entry_no    -- NULL일 경우 0
  from pass_rollup_digests
  where user_pass_id = p_user_pass_id
),
cnt as (
  -- 전체 엔트리 개수
  select count(*)::int as total_cnt
  from emotion_entries
  where user_pass_id = p_user_pass_id
),
lastn as (
  -- 최근 N개의 엔트리 요약 (표준 감정명까지 조인)
  select
    e.id,
    e.situation_summary_text,
    e.journal_summary_text,
    e.created_at,
    e.standard_emotion_id,
    se.name as standard_emotion_name
  from emotion_entries e
  left join standard_emotions se on se.id = e.standard_emotion_id
  where e.user_pass_id = p_user_pass_id
  order by e.created_at desc
  limit p_limit
),
lastn_json as (
  -- 최근 N개를 JSON 배열로 변환 (없으면 [] 반환)
  select coalesce(
           (select jsonb_agg(to_jsonb(lastn) order by lastn.created_at desc) from lastn),
           '[]'::jsonb
         ) as arr
)
-- 최종 JSON 반환
select jsonb_build_object(
  -- 진행도 관련
  'user_id',        (select user_id from pass_info),
  'remaining_uses', (select remaining_uses from pass_info),
  'total_uses',     (select total_uses     from pass_info),
  'entry_no_next',  (select entry_no_next  from pass_info),

  -- 요약(digest)
  'digest',         (select digest_text   from prd),
  'last_entry_no',  (select last_entry_no from prd),
  'digest_len',     coalesce(length((select digest_text from prd)), 0),
  'has_digest',     (select exists(select 1 from prd)),

  -- 최근 엔트리
  'recent_summaries', (select arr from lastn_json),
  'recent_count',   coalesce((select total_cnt from cnt), 0),
  'has_recent',     coalesce(((select total_cnt from cnt) > 0), false)
);
$function$
;

CREATE OR REPLACE FUNCTION public.init_validate_and_attach_user(p_sid text, p_uuid_code text, p_required jsonb, p_email text DEFAULT NULL::text, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_latency_ms integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- 3) pass 조회/유효성 (잠금까지 한 번에 처리)
  if v_reason is null then
    select up.* into v_pass
    from user_passes up
    where up.uuid_code = p_uuid_code
    for update;  -- ✅ 조회+잠금 한번에

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

  -- 이메일 검사 (비어있으면 그냥 통과)
  if v_reason is null and coalesce(btrim(p_email),'') <> '' then
    v_norm := normalize_and_validate_email(p_email);  -- 검증+정규화

    if v_norm is null then
      v_reason := 'invalid_email';
      -- 여기서 바로 fail 기록/리턴하는 로직이 있으면 그 흐름대로 진행
    else
      p_email := v_norm;  -- ✅ 정규화된 이메일로 교체 후 이후 로직 사용/저장
    end if;
  end if;

  -- 5) 실패 처리 공용 루틴
  if v_reason is not null then
    update submission_state
       set user_pass_id = case when v_pass is null then null else v_pass.id end,
           uuid_code = p_uuid_code,
           submit_status = 'fail',
           status_reason = v_reason,
           updated_at    = v_now,
           status_log    = concat_ws(' | ', nullif(status_log,''), format('init fail reason=%s ts=%s', v_reason, to_char(v_now,'YYYY-MM-DD HH24:MI:SS')))
     where sid = p_sid;

     -- 로그 append 후 바로 4000자 유지
     update submission_state
        set status_log = right(status_log, 4000),
            updated_at = v_now
      where sid = p_sid;

    insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
    values (case when v_pass is null then null else v_pass.id end, p_uuid_code, 'fail', v_reason, p_ip, p_user_agent, p_latency_ms, v_now);

    return jsonb_build_object('status','fail','reason',v_reason);
  end if;

  -- 6) user 매핑(심플 & 안전): NULL일 때만 1회 매핑
  --    - 이메일은 있으면 email_pending에만 넣음
  --    - 기존 user_id 있으면 절대 덮어쓰지 않음

  if v_pass.user_id is null then
    -- 새 게스트 생성 (이메일 있으면 pending으로 기록)
    insert into users (is_guest, email_pending)
    values (true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end)
    returning id into v_user_id;

    -- NULL일 때만 매핑 (멱등 보장)
    update user_passes
       set user_id = v_user_id
     where uuid_code = p_uuid_code
       and user_id is null;

    -- 이후 로직에서 쓸 수 있게 v_pass.user_id 갱신
    v_pass.user_id := v_user_id;

  else
    -- 기존 유저ID 사용
    v_user_id := v_pass.user_id;

    -- 유저 레코드 보강(없을 수 있는 극소수 케이스 방지용)
    perform 1 from users where id = v_user_id;
    if not found then
      insert into users (id, is_guest, email_pending)
      values (v_user_id, true, case when coalesce(btrim(p_email),'') <> '' then p_email else null end);
    else
      -- verified는 절대 건드리지 않음. 이메일 값이 있으면 pending만 (선택) 갱신
      if coalesce(btrim(p_email),'') <> '' then
        update users
           set email_pending = p_email,
               updated_at    = v_now
         where id = v_user_id;
      end if;
    end if;
  end if;

  -- 7) 성공 기록(원하면 여기서 validated로 올려도 됨)
  insert into submission_history(user_pass_id, uuid_code, result_status, result_reason, ip, user_agent, latency_ms, created_at)
  values (v_pass.id, p_uuid_code, 'pass', 'ok', p_ip, p_user_agent, p_latency_ms, v_now);

  -- 성공 케이스여도, 마지막에 한 번 더 캡핑
  update submission_state
     set user_pass_id = v_pass.id,
         uuid_code    = p_uuid_code,
         submit_status= 'ready',
         status_reason= 'validation_success',
         status_log = right(coalesce(status_log,''), 4000),
         updated_at   = v_now
   where sid = p_sid;
   
  -- state에는 pending 유지(바로 seed 단계로 넘어가니까). validated로 바꾸고 싶으면 아래 주석 해제
  -- update submission_state set submit_status='validated', updated_at=v_now where sid=p_sid;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.mark_feedback_and_done(p_entry_id uuid, p_sid text)
 RETURNS TABLE(entry_id uuid, entry_flag_before boolean, entry_flag_after boolean, sid text, state_before text, state_after text, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_flag_before boolean;
  v_state_before text;
begin
  -- 현재 상태 스냅샷
  select is_feedback_generated into v_flag_before
  from public.emotion_entries
  where id = p_entry_id
  for update;  -- 동시성 방지

  select submit_status into v_state_before
  from public.submission_state
  where sid = p_sid
  for update;

  -- 1) entry 플래그 true (멱등)
  update public.emotion_entries
     set is_feedback_generated = true,
         feedback_generated_at = coalesce(feedback_generated_at, now())
   where id = p_entry_id;

  -- 2) submission_state 를 done 으로 (멱등)
  update public.submission_state
     set submit_status = 'done',
         updated_at    = now()
   where sid = p_sid
     and submit_status <> 'done';

  -- 결과 반환
  return query
  select
    e.id as entry_id,
    v_flag_before as entry_flag_before,
    e.is_feedback_generated as entry_flag_after,
    s.sid,
    v_state_before as state_before,
    s.submit_status as state_after,
    s.updated_at
  from public.emotion_entries e
  join public.submission_state s on s.sid = p_sid
  where e.id = p_entry_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_feedback_and_done_simple(p_sid text, p_entry uuid)
 RETURNS TABLE(ok boolean, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare v_up uuid;
begin
  select user_pass_id into v_up from submission_state where sid=p_sid for update;
  if v_up is null then return query select false,'not_found'; return; end if;

  update emotion_entries
     set is_feedback_generated=true, updated_at=now()
   where id=p_entry;

  update user_passes
     set remaining_uses = remaining_uses - 1, updated_at=now()
   where id=v_up and remaining_uses>0;
  if not found then return query select false,'no_uses'; return; end if;

  update submission_state
     set submit_status='done', emotion_entry_id=p_entry, updated_at=now()
   where sid=p_sid;

  return query select true,null;
exception when others then return query select false,'exception'; end;
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_and_validate_email(p_email text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_whitespace(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(
           regexp_replace(
             coalesce(p_text,''), 
             E'[\\u00A0\\u200B\\uFEFF]', -- non-breaking space, zero-width, BOM
             '', 'g'
           ),
           E'[\\s]+',  -- 일반 공백, 탭, 엔터 포함
           '', 'g'
         );
$function$
;

CREATE OR REPLACE FUNCTION public.seed_and_record_submission(p_sid text, p_uuid_code text, p_user_pass_id uuid, p_user_id uuid, p_reason text, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_latency_ms integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- 0) 게이트: 유효성 RPC가 'ready'로 만든 상태인지 확인
  --------------------------------------------------------------------
  select submit_status
    into v_state
  from submission_state
  where sid = p_sid;

  if v_state is distinct from 'ready' then
    return jsonb_build_object('status','error','reason','bad_state');
  end if;

  --------------------------------------------------------------------
  -- 1) user_pass 검증 (uuid_code, is_active 일치)
  --------------------------------------------------------------------
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

  --------------------------------------------------------------------
  -- 2) 시드 주입(멱등): digest 존재 여부 체크
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
      and up.id <> p_user_pass_id
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

      if coalesce(v_seed,'') = '' then
        -- 2순위: 직전 pass digest
        select prd.digest_text
          into v_seed
        from pass_rollup_digests prd
        where prd.user_pass_id = v_prev_pass_id;

        v_seed_source := case when coalesce(v_seed,'')<>'' then 'prev_pass_digest' else 'empty' end;
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
  -- 3) 상태 로그 append
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

  return jsonb_build_object(
    'status', v_status,
    'seed_source', v_seed_source,
    'prev_pass_id', v_prev_pass_id,
    'seed_len', coalesce(length(v_seed),0)
  );
end $function$
;

CREATE OR REPLACE FUNCTION public.upsert_entry_decrement_and_link(p_sid text, p_user_pass_id uuid, p_entry jsonb, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_now         timestamptz := now();
  v_state       text;
  v_linked_id   uuid;
  v_user_id     uuid;
  v_remaining   int;
  v_entry_id    uuid;
  v_std_id      uuid;   -- standard_emotion_id(UUID) 안전 캐스팅용
begin
  -- 0) 필수 파라미터
  if p_sid is null or p_user_pass_id is null then
    return jsonb_build_object('status','error','reason','missing_sid_or_pass');
  end if;

  -- 1) submission_state 잠금 + 멱등/상태 확인
  select submit_status, emotion_entry_id
    into v_state, v_linked_id
  from submission_state
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

  -- 2) 패스 잠금 + 잔여 회차 로딩 (SELECT 1회)
  select up.user_id, coalesce(up.remaining_uses,0)
    into v_user_id, v_remaining
  from user_passes up
  where up.id = p_user_pass_id
  for update;

  if v_user_id is null then
    return jsonb_build_object('status','error','reason','user_id_null');
  end if;
  if v_remaining <= 0 then
    return jsonb_build_object('status','error','reason','no_remaining');
  end if;

  -- 3) 필수 입력(원문 3종 + 라벨 3종) 확인
  if coalesce(p_entry->>'raw_emotion','')      = '' or
     coalesce(p_entry->>'situation_raw','')    = '' or
     coalesce(p_entry->>'journal_raw','')      = '' or
     coalesce(p_entry#>>'{labels,level}','')   = '' or
     coalesce(p_entry#>>'{labels,feedback_type}','') = '' or
     coalesce(p_entry#>>'{labels,speech}','')  = '' then
    return jsonb_build_object('status','error','reason','missing_required_fields');
  end if;

  -- 3.5) standard_emotion_id(UUID) 안전 캐스팅
  if (p_entry ? 'standard_emotion_id')
     and jsonb_typeof(p_entry->'standard_emotion_id') = 'string'
     and nullif(p_entry->>'standard_emotion_id','') is not null then
    v_std_id := (p_entry->>'standard_emotion_id')::uuid;
  else
    v_std_id := null;
  end if;

  -- 4) INSERT (스키마에 맞춤: ip/user_agent 없음)
  insert into emotion_entries(
    id,
    user_pass_id, user_id,
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
    created_at
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
    v_now   -- created_at은 default now()지만, 명시해도 무방
  )
  returning id into v_entry_id;

  -- 5) 회차 차감 + 최초 사용 시각
  update user_passes
     set remaining_uses = v_remaining - 1,
         first_used_at  = coalesce(first_used_at, v_now),
         updated_at     = v_now
   where id = p_user_pass_id;

  -- 6) submissions 링크 + 로그(캡)
  update submission_state
     set emotion_entry_id = v_entry_id,
         status_log = concat_ws(
           ' | ', nullif(status_log,''),
           format('entry_linked=%s ts=%s',
                  v_entry_id, to_char(v_now,'YYYY-MM-DD HH24:MI:SS'))
         ),
         updated_at = v_now
   where sid = p_sid;

  update submission_state
     set status_log = right(status_log, 4000)
   where sid = p_sid;

  return jsonb_build_object(
    'status','ok',
    'entry_id', v_entry_id,
    'remaining_uses_after', v_remaining - 1
  );
end $function$
;

CREATE OR REPLACE FUNCTION public.upsert_pass_rollup_digest(p_user_pass_id uuid, p_digest_text text)
 RETURNS TABLE(id uuid, user_pass_id uuid, digest_text text, last_entry_no integer, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  return query
  insert into public.pass_rollup_digests as d (user_pass_id, digest_text, last_entry_no)
  values (p_user_pass_id, p_digest_text, 1)
  on conflict (user_pass_id) do update
    set digest_text   = excluded.digest_text,
        last_entry_no = d.last_entry_no + 1,
        updated_at    = now()
  returning d.id, d.user_pass_id, d.digest_text, d.last_entry_no, d.created_at, d.updated_at;
end;
$function$
;

grant delete on table "public"."analysis_requests" to "anon";

grant insert on table "public"."analysis_requests" to "anon";

grant references on table "public"."analysis_requests" to "anon";

grant select on table "public"."analysis_requests" to "anon";

grant trigger on table "public"."analysis_requests" to "anon";

grant truncate on table "public"."analysis_requests" to "anon";

grant update on table "public"."analysis_requests" to "anon";

grant delete on table "public"."analysis_requests" to "authenticated";

grant insert on table "public"."analysis_requests" to "authenticated";

grant references on table "public"."analysis_requests" to "authenticated";

grant select on table "public"."analysis_requests" to "authenticated";

grant trigger on table "public"."analysis_requests" to "authenticated";

grant truncate on table "public"."analysis_requests" to "authenticated";

grant update on table "public"."analysis_requests" to "authenticated";

grant delete on table "public"."analysis_requests" to "service_role";

grant insert on table "public"."analysis_requests" to "service_role";

grant references on table "public"."analysis_requests" to "service_role";

grant select on table "public"."analysis_requests" to "service_role";

grant trigger on table "public"."analysis_requests" to "service_role";

grant truncate on table "public"."analysis_requests" to "service_role";

grant update on table "public"."analysis_requests" to "service_role";

grant delete on table "public"."emotion_entries" to "anon";

grant insert on table "public"."emotion_entries" to "anon";

grant references on table "public"."emotion_entries" to "anon";

grant select on table "public"."emotion_entries" to "anon";

grant trigger on table "public"."emotion_entries" to "anon";

grant truncate on table "public"."emotion_entries" to "anon";

grant update on table "public"."emotion_entries" to "anon";

grant delete on table "public"."emotion_entries" to "authenticated";

grant insert on table "public"."emotion_entries" to "authenticated";

grant references on table "public"."emotion_entries" to "authenticated";

grant select on table "public"."emotion_entries" to "authenticated";

grant trigger on table "public"."emotion_entries" to "authenticated";

grant truncate on table "public"."emotion_entries" to "authenticated";

grant update on table "public"."emotion_entries" to "authenticated";

grant delete on table "public"."emotion_entries" to "service_role";

grant insert on table "public"."emotion_entries" to "service_role";

grant references on table "public"."emotion_entries" to "service_role";

grant select on table "public"."emotion_entries" to "service_role";

grant trigger on table "public"."emotion_entries" to "service_role";

grant truncate on table "public"."emotion_entries" to "service_role";

grant update on table "public"."emotion_entries" to "service_role";

grant delete on table "public"."emotion_feedbacks" to "anon";

grant insert on table "public"."emotion_feedbacks" to "anon";

grant references on table "public"."emotion_feedbacks" to "anon";

grant select on table "public"."emotion_feedbacks" to "anon";

grant trigger on table "public"."emotion_feedbacks" to "anon";

grant truncate on table "public"."emotion_feedbacks" to "anon";

grant update on table "public"."emotion_feedbacks" to "anon";

grant delete on table "public"."emotion_feedbacks" to "authenticated";

grant insert on table "public"."emotion_feedbacks" to "authenticated";

grant references on table "public"."emotion_feedbacks" to "authenticated";

grant select on table "public"."emotion_feedbacks" to "authenticated";

grant trigger on table "public"."emotion_feedbacks" to "authenticated";

grant truncate on table "public"."emotion_feedbacks" to "authenticated";

grant update on table "public"."emotion_feedbacks" to "authenticated";

grant delete on table "public"."emotion_feedbacks" to "service_role";

grant insert on table "public"."emotion_feedbacks" to "service_role";

grant references on table "public"."emotion_feedbacks" to "service_role";

grant select on table "public"."emotion_feedbacks" to "service_role";

grant trigger on table "public"."emotion_feedbacks" to "service_role";

grant truncate on table "public"."emotion_feedbacks" to "service_role";

grant update on table "public"."emotion_feedbacks" to "service_role";

grant delete on table "public"."one_time_email_deliveries" to "anon";

grant insert on table "public"."one_time_email_deliveries" to "anon";

grant references on table "public"."one_time_email_deliveries" to "anon";

grant select on table "public"."one_time_email_deliveries" to "anon";

grant trigger on table "public"."one_time_email_deliveries" to "anon";

grant truncate on table "public"."one_time_email_deliveries" to "anon";

grant update on table "public"."one_time_email_deliveries" to "anon";

grant delete on table "public"."one_time_email_deliveries" to "authenticated";

grant insert on table "public"."one_time_email_deliveries" to "authenticated";

grant references on table "public"."one_time_email_deliveries" to "authenticated";

grant select on table "public"."one_time_email_deliveries" to "authenticated";

grant trigger on table "public"."one_time_email_deliveries" to "authenticated";

grant truncate on table "public"."one_time_email_deliveries" to "authenticated";

grant update on table "public"."one_time_email_deliveries" to "authenticated";

grant delete on table "public"."one_time_email_deliveries" to "service_role";

grant insert on table "public"."one_time_email_deliveries" to "service_role";

grant references on table "public"."one_time_email_deliveries" to "service_role";

grant select on table "public"."one_time_email_deliveries" to "service_role";

grant trigger on table "public"."one_time_email_deliveries" to "service_role";

grant truncate on table "public"."one_time_email_deliveries" to "service_role";

grant update on table "public"."one_time_email_deliveries" to "service_role";

grant delete on table "public"."pass_rollup_digests" to "anon";

grant insert on table "public"."pass_rollup_digests" to "anon";

grant references on table "public"."pass_rollup_digests" to "anon";

grant select on table "public"."pass_rollup_digests" to "anon";

grant trigger on table "public"."pass_rollup_digests" to "anon";

grant truncate on table "public"."pass_rollup_digests" to "anon";

grant update on table "public"."pass_rollup_digests" to "anon";

grant delete on table "public"."pass_rollup_digests" to "authenticated";

grant insert on table "public"."pass_rollup_digests" to "authenticated";

grant references on table "public"."pass_rollup_digests" to "authenticated";

grant select on table "public"."pass_rollup_digests" to "authenticated";

grant trigger on table "public"."pass_rollup_digests" to "authenticated";

grant truncate on table "public"."pass_rollup_digests" to "authenticated";

grant update on table "public"."pass_rollup_digests" to "authenticated";

grant delete on table "public"."pass_rollup_digests" to "service_role";

grant insert on table "public"."pass_rollup_digests" to "service_role";

grant references on table "public"."pass_rollup_digests" to "service_role";

grant select on table "public"."pass_rollup_digests" to "service_role";

grant trigger on table "public"."pass_rollup_digests" to "service_role";

grant truncate on table "public"."pass_rollup_digests" to "service_role";

grant update on table "public"."pass_rollup_digests" to "service_role";

grant delete on table "public"."passes" to "anon";

grant insert on table "public"."passes" to "anon";

grant references on table "public"."passes" to "anon";

grant select on table "public"."passes" to "anon";

grant trigger on table "public"."passes" to "anon";

grant truncate on table "public"."passes" to "anon";

grant update on table "public"."passes" to "anon";

grant delete on table "public"."passes" to "authenticated";

grant insert on table "public"."passes" to "authenticated";

grant references on table "public"."passes" to "authenticated";

grant select on table "public"."passes" to "authenticated";

grant trigger on table "public"."passes" to "authenticated";

grant truncate on table "public"."passes" to "authenticated";

grant update on table "public"."passes" to "authenticated";

grant delete on table "public"."passes" to "service_role";

grant insert on table "public"."passes" to "service_role";

grant references on table "public"."passes" to "service_role";

grant select on table "public"."passes" to "service_role";

grant trigger on table "public"."passes" to "service_role";

grant truncate on table "public"."passes" to "service_role";

grant update on table "public"."passes" to "service_role";

grant delete on table "public"."standard_emotions" to "anon";

grant insert on table "public"."standard_emotions" to "anon";

grant references on table "public"."standard_emotions" to "anon";

grant select on table "public"."standard_emotions" to "anon";

grant trigger on table "public"."standard_emotions" to "anon";

grant truncate on table "public"."standard_emotions" to "anon";

grant update on table "public"."standard_emotions" to "anon";

grant delete on table "public"."standard_emotions" to "authenticated";

grant insert on table "public"."standard_emotions" to "authenticated";

grant references on table "public"."standard_emotions" to "authenticated";

grant select on table "public"."standard_emotions" to "authenticated";

grant trigger on table "public"."standard_emotions" to "authenticated";

grant truncate on table "public"."standard_emotions" to "authenticated";

grant update on table "public"."standard_emotions" to "authenticated";

grant delete on table "public"."standard_emotions" to "service_role";

grant insert on table "public"."standard_emotions" to "service_role";

grant references on table "public"."standard_emotions" to "service_role";

grant select on table "public"."standard_emotions" to "service_role";

grant trigger on table "public"."standard_emotions" to "service_role";

grant truncate on table "public"."standard_emotions" to "service_role";

grant update on table "public"."standard_emotions" to "service_role";

grant delete on table "public"."submission_history" to "anon";

grant insert on table "public"."submission_history" to "anon";

grant references on table "public"."submission_history" to "anon";

grant select on table "public"."submission_history" to "anon";

grant trigger on table "public"."submission_history" to "anon";

grant truncate on table "public"."submission_history" to "anon";

grant update on table "public"."submission_history" to "anon";

grant delete on table "public"."submission_history" to "authenticated";

grant insert on table "public"."submission_history" to "authenticated";

grant references on table "public"."submission_history" to "authenticated";

grant select on table "public"."submission_history" to "authenticated";

grant trigger on table "public"."submission_history" to "authenticated";

grant truncate on table "public"."submission_history" to "authenticated";

grant update on table "public"."submission_history" to "authenticated";

grant delete on table "public"."submission_history" to "service_role";

grant insert on table "public"."submission_history" to "service_role";

grant references on table "public"."submission_history" to "service_role";

grant select on table "public"."submission_history" to "service_role";

grant trigger on table "public"."submission_history" to "service_role";

grant truncate on table "public"."submission_history" to "service_role";

grant update on table "public"."submission_history" to "service_role";

grant delete on table "public"."submission_state" to "anon";

grant insert on table "public"."submission_state" to "anon";

grant references on table "public"."submission_state" to "anon";

grant select on table "public"."submission_state" to "anon";

grant trigger on table "public"."submission_state" to "anon";

grant truncate on table "public"."submission_state" to "anon";

grant update on table "public"."submission_state" to "anon";

grant delete on table "public"."submission_state" to "authenticated";

grant insert on table "public"."submission_state" to "authenticated";

grant references on table "public"."submission_state" to "authenticated";

grant select on table "public"."submission_state" to "authenticated";

grant trigger on table "public"."submission_state" to "authenticated";

grant truncate on table "public"."submission_state" to "authenticated";

grant update on table "public"."submission_state" to "authenticated";

grant delete on table "public"."submission_state" to "service_role";

grant insert on table "public"."submission_state" to "service_role";

grant references on table "public"."submission_state" to "service_role";

grant select on table "public"."submission_state" to "service_role";

grant trigger on table "public"."submission_state" to "service_role";

grant truncate on table "public"."submission_state" to "service_role";

grant update on table "public"."submission_state" to "service_role";

grant delete on table "public"."user_passes" to "anon";

grant insert on table "public"."user_passes" to "anon";

grant references on table "public"."user_passes" to "anon";

grant select on table "public"."user_passes" to "anon";

grant trigger on table "public"."user_passes" to "anon";

grant truncate on table "public"."user_passes" to "anon";

grant update on table "public"."user_passes" to "anon";

grant delete on table "public"."user_passes" to "authenticated";

grant insert on table "public"."user_passes" to "authenticated";

grant references on table "public"."user_passes" to "authenticated";

grant select on table "public"."user_passes" to "authenticated";

grant trigger on table "public"."user_passes" to "authenticated";

grant truncate on table "public"."user_passes" to "authenticated";

grant update on table "public"."user_passes" to "authenticated";

grant delete on table "public"."user_passes" to "service_role";

grant insert on table "public"."user_passes" to "service_role";

grant references on table "public"."user_passes" to "service_role";

grant select on table "public"."user_passes" to "service_role";

grant trigger on table "public"."user_passes" to "service_role";

grant truncate on table "public"."user_passes" to "service_role";

grant update on table "public"."user_passes" to "service_role";

grant delete on table "public"."users" to "anon";

grant insert on table "public"."users" to "anon";

grant references on table "public"."users" to "anon";

grant select on table "public"."users" to "anon";

grant trigger on table "public"."users" to "anon";

grant truncate on table "public"."users" to "anon";

grant update on table "public"."users" to "anon";

grant delete on table "public"."users" to "authenticated";

grant insert on table "public"."users" to "authenticated";

grant references on table "public"."users" to "authenticated";

grant select on table "public"."users" to "authenticated";

grant trigger on table "public"."users" to "authenticated";

grant truncate on table "public"."users" to "authenticated";

grant update on table "public"."users" to "authenticated";

grant delete on table "public"."users" to "service_role";

grant insert on table "public"."users" to "service_role";

grant references on table "public"."users" to "service_role";

grant select on table "public"."users" to "service_role";

grant trigger on table "public"."users" to "service_role";

grant truncate on table "public"."users" to "service_role";

grant update on table "public"."users" to "service_role";


  create policy "Service insert emotion_feedbacks"
  on "public"."emotion_feedbacks"
  as permissive
  for insert
  to service_role
with check (true);



  create policy "Delete own user_passes"
  on "public"."user_passes"
  as permissive
  for delete
  to authenticated
using ((user_id = ( SELECT auth.uid() AS uid)));



  create policy "Insert own user_passes"
  on "public"."user_passes"
  as permissive
  for insert
  to authenticated
with check ((user_id = ( SELECT auth.uid() AS uid)));



  create policy "Select own user_passes"
  on "public"."user_passes"
  as permissive
  for select
  to authenticated
using ((user_id = ( SELECT auth.uid() AS uid)));



  create policy "Update own user_passes"
  on "public"."user_passes"
  as permissive
  for update
  to authenticated
using ((user_id = ( SELECT auth.uid() AS uid)))
with check ((user_id = ( SELECT auth.uid() AS uid)));



