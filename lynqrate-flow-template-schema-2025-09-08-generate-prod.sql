create table public.analysis_requests (
  id uuid not null default gen_random_uuid (),
  user_id uuid null,
  user_pass_id uuid null,
  scope text not null,
  status text not null default 'pending'::text,
  reason text null,
  analysis_text text not null default ''::text,
  stats_json jsonb null,
  model text not null,
  token_used integer not null default 0,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint analysis_requests_pkey primary key (id),
  constraint fk_ar_user_pass_id_user_passes foreign KEY (user_pass_id) references user_passes (id) on delete set null,
  constraint analysis_requests_user_id_fkey foreign KEY (user_id) references users (id) on delete set null,
  constraint analysis_requests_user_pass_id_fkey foreign KEY (user_pass_id) references user_passes (id) on delete set null,
  constraint fk_ar_user_id_users foreign KEY (user_id) references users (id) on delete set null,
  constraint ck_analysis_scope_target check (
    (
      (
        (scope = 'pass'::text)
        and (user_pass_id is not null)
        and (user_id is null)
      )
      or (
        (scope = 'user_all'::text)
        and (user_id is not null)
        and (user_pass_id is null)
      )
    )
  ),
  constraint analysis_requests_scope_check check (
    (
      scope = any (array['pass'::text, 'user_all'::text])
    )
  ),
  constraint chk_analysis_requests_status_allowed check (
    (
      status = any (array['pending'::text, 'done'::text])
    )
  ),
  constraint analysis_requests_scope_xor check (
    (
      (
        (scope = 'pass'::text)
        and (user_pass_id is not null)
        and (user_id is null)
      )
      or (
        (scope = 'user_all'::text)
        and (user_id is not null)
        and (user_pass_id is null)
      )
    )
  ),
  constraint analysis_requests_status_check check (
    (
      status = any (array['pending'::text, 'done'::text])
    )
  ),
  constraint analysis_requests_token_used_check check ((token_used >= 0))
) TABLESPACE pg_default;

create unique INDEX IF not exists uq_ar_pass_pending on public.analysis_requests using btree (user_pass_id) TABLESPACE pg_default
where
  (
    (scope = 'pass'::text)
    and (status = 'pending'::text)
  );

create unique INDEX IF not exists uq_ar_user_pass_scope_status on public.analysis_requests using btree (user_pass_id, scope, status) TABLESPACE pg_default;

create index IF not exists idx_analysis_user_created on public.analysis_requests using btree (user_id, created_at desc) TABLESPACE pg_default;

create index IF not exists idx_analysis_pass_created on public.analysis_requests using btree (user_pass_id, created_at desc) TABLESPACE pg_default;

create unique INDEX IF not exists uq_ar_pass_done on public.analysis_requests using btree (user_pass_id) TABLESPACE pg_default
where
  (
    (scope = 'pass'::text)
    and (status = 'done'::text)
  );

create unique INDEX IF not exists uq_ar_pass_open on public.analysis_requests using btree (user_pass_id) TABLESPACE pg_default
where
  (
    (scope = 'pass'::text)
    and (
      status = any (array['pending'::text, 'ready'::text])
    )
  );



create table public.emotion_entries (
  id uuid not null default gen_random_uuid (),
  user_pass_id uuid not null,
  user_id uuid null,
  raw_emotion_text text not null,
  supposed_emotion_text text null,
  standard_emotion_id uuid null,
  standard_emotion_reasoning text null,
  situation_raw_text text not null,
  situation_summary_text text null,
  journal_raw_text text not null,
  journal_summary_text text null,
  created_at timestamp with time zone not null default now(),
  is_feedback_generated boolean null default false,
  status text not null default 'pending'::text,
  error_reason text null,
  emotion_level_label_snapshot text not null,
  feedback_type_label_snapshot text not null,
  feedback_speech_label_snapshot text not null,
  feedback_generated_at timestamp with time zone null,
  constraint emotion_entries_pkey primary key (id),
  constraint emotion_entries_standard_emotion_id_fkey foreign KEY (standard_emotion_id) references standard_emotions (id) on delete set null,
  constraint emotion_entries_user_id_fkey foreign KEY (user_id) references users (id) on delete set null,
  constraint emotion_entries_user_pass_id_fkey foreign KEY (user_pass_id) references user_passes (id) on delete CASCADE,
  constraint emotion_entries_status_check check (
    (
      status = any (
        array['pending'::text, 'ready'::text, 'error'::text]
      )
    )
  )
) TABLESPACE pg_default;

create index IF not exists idx_entries_user_created on public.emotion_entries using btree (user_id, created_at desc) TABLESPACE pg_default;

create index IF not exists idx_entries_pass_created on public.emotion_entries using btree (user_pass_id, created_at desc) TABLESPACE pg_default;






create table public.emotion_feedbacks (
  id uuid not null default gen_random_uuid (),
  emotion_entry_id uuid not null,
  feedback_text text not null,
  language text not null default 'ko'::text,
  gpt_model_used text not null,
  temperature double precision not null,
  token_count integer not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint emotion_feedbacks_pkey primary key (id),
  constraint emotion_feedbacks_emotion_entry_id_fkey foreign KEY (emotion_entry_id) references emotion_entries (id) on delete CASCADE
) TABLESPACE pg_default;

create unique INDEX IF not exists uq_emotion_feedbacks_entry on public.emotion_feedbacks using btree (emotion_entry_id) TABLESPACE pg_default;






create table public.one_time_email_deliveries (
  id uuid not null default gen_random_uuid (),
  user_id uuid null,
  submission_id uuid not null,
  emotion_entry_id uuid null,
  emotion_feedback_id uuid null,
  purpose text not null default 'feedback_result'::text,
  email text not null,
  submit_status text not null default 'pending'::text,
  created_at timestamp with time zone not null default now(),
  sent_at timestamp with time zone null,
  fail_reason text null,
  expires_at timestamp with time zone not null default (now() + '7 days'::interval),
  deleted_at timestamp with time zone null,
  constraint one_time_email_deliveries_pkey primary key (id),
  constraint one_time_email_deliveries_emotion_entry_id_fkey foreign KEY (emotion_entry_id) references emotion_entries (id) on delete CASCADE,
  constraint one_time_email_deliveries_emotion_feedback_id_fkey foreign KEY (emotion_feedback_id) references emotion_feedbacks (id) on delete CASCADE,
  constraint one_time_email_deliveries_user_id_fkey foreign KEY (user_id) references users (id) on delete set null,
  constraint one_time_email_deliveries_submit_status_check check (
    (
      submit_status = any (
        array['pending'::text, 'ready'::text, 'fail'::text]
      )
    )
  )
) TABLESPACE pg_default;

create index IF not exists one_time_email_deliveries_submission_idx on public.one_time_email_deliveries using btree (submission_id) TABLESPACE pg_default;






create table public.pass_rollup_digests (
  id uuid not null default gen_random_uuid (),
  user_pass_id uuid not null,
  digest_text text not null,
  last_entry_no integer not null default 0,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint pass_rollup_digests_pkey primary key (id),
  constraint pass_rollup_digests_user_pass_id_key unique (user_pass_id),
  constraint pass_rollup_digests_user_pass_id_fkey foreign KEY (user_pass_id) references user_passes (id) on delete CASCADE,
  constraint pass_rollup_digests_last_entry_no_check check ((last_entry_no >= 0))
) TABLESPACE pg_default;







create table public.passes (
  id uuid not null default gen_random_uuid (),
  name text not null,
  total_uses integer not null,
  price integer not null,
  description text null,
  expires_after_days integer null,
  create_at timestamp with time zone not null default now(),
  constraint passes_pkey primary key (id)
) TABLESPACE pg_default;








create table public.standard_emotions (
  id uuid not null default gen_random_uuid (),
  name text not null,
  description text null,
  soft_order integer not null,
  color_code text not null,
  constraint standard_emotions_pkey primary key (id)
) TABLESPACE pg_default;








create table public.submission_history (
  id bigserial not null,
  user_pass_id uuid null,
  emotion_entry_id uuid null,
  uuid_code text null,
  result_status text not null,
  result_reason text null,
  ip inet null,
  user_agent text null,
  latency_ms integer null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  error_json jsonb null,
  constraint submission_history_pkey primary key (id),
  constraint submission_history_emotion_entry_id_fkey foreign KEY (emotion_entry_id) references emotion_entries (id) on delete set null,
  constraint submission_history_user_pass_id_fkey foreign KEY (user_pass_id) references user_passes (id) on delete set null,
  constraint submission_history_result_status_check check (
    (
      result_status = any (array['pass'::text, 'fail'::text, 'error'::text])
    )
  )
) TABLESPACE pg_default;

create index IF not exists idx_submission_history_created_at on public.submission_history using btree (created_at) TABLESPACE pg_default;

create index IF not exists idx_submission_history_uuid_code on public.submission_history using btree (uuid_code) TABLESPACE pg_default;

create index IF not exists idx_submission_history_result_status on public.submission_history using btree (result_status) TABLESPACE pg_default;

create index IF not exists idx_submission_history_result_reason on public.submission_history using btree (result_reason) TABLESPACE pg_default;

create index IF not exists idx_submission_history_user_pass_id on public.submission_history using btree (user_pass_id) TABLESPACE pg_default;

create index IF not exists idx_submission_history_entry_id on public.submission_history using btree (emotion_entry_id) TABLESPACE pg_default;










create table public.submission_state (
  sid text not null,
  user_pass_id uuid null,
  emotion_entry_id uuid null,
  uuid_code text not null,
  submit_status text not null,
  status_reason text null,
  updated_at timestamp with time zone not null default now(),
  created_at timestamp with time zone not null default now(),
  status_log text null,
  constraint submission_state_pkey primary key (sid),
  constraint submission_state_emotion_entry_id_fkey foreign KEY (emotion_entry_id) references emotion_entries (id) on delete set null,
  constraint submission_state_user_pass_id_fkey foreign KEY (user_pass_id) references user_passes (id) on delete set null,
  constraint submission_state_submit_status_check check (
    (
      submit_status = any (
        array[
          'pending'::text,
          'fail'::text,
          'ready'::text,
          'done'::text
        ]
      )
    )
  )
) TABLESPACE pg_default;

create index IF not exists idx_submission_state_updated_at on public.submission_state using btree (updated_at) TABLESPACE pg_default;

create index IF not exists idx_submission_state_status on public.submission_state using btree (submit_status) TABLESPACE pg_default;

create index IF not exists idx_submission_state_uuid_code on public.submission_state using btree (uuid_code) TABLESPACE pg_default;

create index IF not exists idx_submission_state_user_pass_id on public.submission_state using btree (user_pass_id) TABLESPACE pg_default;










create table public.user_passes (
  id uuid not null default gen_random_uuid (),
  user_id uuid null,
  pass_id uuid not null,
  remaining_uses integer not null,
  purchased_at timestamp with time zone null,
  expires_at timestamp with time zone null,
  uuid_code text not null default lower(
    (
      (
        (
          (
            (
              (
                encode(extensions.gen_random_bytes (2), 'hex'::text) || '-'::text
              ) || encode(extensions.gen_random_bytes (2), 'hex'::text)
            ) || '-'::text
          ) || encode(extensions.gen_random_bytes (2), 'hex'::text)
        ) || '-'::text
      ) || encode(extensions.gen_random_bytes (2), 'hex'::text)
    )
  ),
  first_used_at timestamp with time zone null,
  source text not null default 'kmong'::text,
  source_order_id text null,
  buyer_handle text null,
  created_at timestamp with time zone not null default now(),
  is_active boolean not null default true,
  prev_pass_id uuid null,
  updated_at timestamp with time zone null default now(),
  constraint user_passes_pkey primary key (id),
  constraint user_passes_uuid_code_key unique (uuid_code),
  constraint user_passes_pass_id_fkey foreign KEY (pass_id) references passes (id) on delete RESTRICT,
  constraint user_passes_prev_pass_id_fkey foreign KEY (prev_pass_id) references user_passes (id) on delete RESTRICT,
  constraint user_passes_user_id_fkey foreign KEY (user_id) references users (id) on delete RESTRICT
) TABLESPACE pg_default;

create index IF not exists idx_user_passes_user_pass_time on public.user_passes using btree (
  user_id,
  pass_id,
  purchased_at desc,
  created_at desc
) TABLESPACE pg_default;

create unique INDEX IF not exists user_passes_source_order_uidx on public.user_passes using btree (source, source_order_id) TABLESPACE pg_default
where
  (source_order_id is not null);

create index IF not exists idx_user_passes_user_created on public.user_passes using btree (user_id, created_at desc) TABLESPACE pg_default;










create table public.users (
  id uuid not null default gen_random_uuid (),
  is_guest boolean not null default true,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone null,
  first_activity_at timestamp with time zone null default now(),
  email text null,
  email_verified text null,
  email_pending text null,
  email_verified_at timestamp with time zone null,
  constraint users_pkey primary key (id),
  constraint users_email_key unique (email),
  constraint users_email_verified_key unique (email_verified)
) TABLESPACE pg_default;