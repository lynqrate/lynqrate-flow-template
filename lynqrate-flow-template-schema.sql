CREATE TABLE "users" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "email" text UNIQUE,
  "is_guest" boolean NOT NULL DEFAULT true,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz,
  "deleted_at" timestamptz,
  "first_activity_at" timestamptz
);

CREATE TABLE "passes" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "name" text NOT NULL,
  "total_uses" int NOT NULL,
  "price" int NOT NULL,
  "description" text,
  "is_active" boolean NOT NULL DEFAULT true,
  "expires_after_days" int
);

CREATE TABLE "user_passes" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_id" uuid NOT NULL,
  "pass_id" uuid NOT NULL,
  "remaining_uses" int NOT NULL,
  "purchased_at" timestamptz NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "uuid_code" text UNIQUE NOT NULL,
  "first_used_at" timestamptz
);

CREATE TABLE "standard_emotions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "name" text NOT NULL,
  "description" text,
  "soft_order" int NOT NULL,
  "color_code" text NOT NULL
);

CREATE TABLE "emotion_entries" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_pass_id" uuid NOT NULL,
  "user_id" uuid,
  "raw_emotion_text" text NOT NULL,
  "supposed_emotion_text" text,
  "standard_emotion_id" uuid,
  "standard_emotion_reasoning" text,
  "situation_raw_text" text NOT NULL,
  "situation_summary_text" text,
  "journal_raw_text" text NOT NULL,
  "journal_summary_text" text,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "is_feedback_generated" boolean DEFAULT false,
  "status" text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'ready', 'error')),
  "error_reason" text
);

CREATE TABLE "emotion_feedbacks" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "emotion_entry_id" uuid NOT NULL,
  "feedback_text" text NOT NULL,
  "language" text NOT NULL,
  "gpt_model_used" text NOT NULL,
  "temperature" float NOT NULL,
  "token_count" int NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE "submission_state" (
  "sid" text PRIMARY KEY,
  "user_pass_id" uuid,
  "emotion_entry_id" uuid,
  "uuid_code" text NOT NULL,
  "submit_status" text NOT NULL CHECK (submit_status in ('pending', 'ready', 'fail')),
  "status_reason" text,
  "updated_at" timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE "submission_history" (
  "id" bigserial PRIMARY KEY,
  "user_pass_id" uuid,
  "emotion_entry_id" uuid,
  "uuid_code" text,
  "result_status" text NOT NULL CHECK (result_status in ('pass','fail','error')),
  "result_reason" text, 
  "ip" inet,
  "user_agent" text,
  "latency_ms" int,
  "created_at" timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE "passes" IS '이용권 종류';

COMMENT ON COLUMN "passes"."name" IS '1회권, 10회권';

COMMENT ON COLUMN "passes"."total_uses" IS '총 사용 가능 횟수';

COMMENT ON TABLE "user_passes" IS '이용권 구매 기록. User:Pass = M:N 구조를 해결하는 중간 테이블';

COMMENT ON COLUMN "user_passes"."remaining_uses" IS '잔여 회차';

COMMENT ON COLUMN "user_passes"."expires_at" IS '구매일 기준 30일 후 만료';

COMMENT ON COLUMN "user_passes"."uuid_code" IS '이용권 인증 코드';

COMMENT ON TABLE "standard_emotions" IS '표준 감정 정의';

COMMENT ON COLUMN "standard_emotions"."name" IS '기쁨, 슬픔 등';

COMMENT ON TABLE "emotion_entries" IS '감정 분석 요청 및 결과 저장';

COMMENT ON COLUMN "emotion_entries"."user_id" IS '직접 연결된 사용자';

COMMENT ON COLUMN "emotion_entries"."raw_emotion_text" IS '사용자 입력 원본';

COMMENT ON COLUMN "emotion_entries"."standard_emotion_id" IS 'GPT 분류 결과';

COMMENT ON COLUMN "emotion_entries"."standard_emotion_reasoning" IS 'GPT가 왜 그렇게 분류했는지';

COMMENT ON COLUMN "emotion_entries"."supposed_emotion_text" IS 'GPT가 추정한 감정';

COMMENT ON COLUMN "emotion_entries"."situation_raw_text" IS '상황 원문 (항상 저장)';

COMMENT ON COLUMN "emotion_entries"."journal_raw_text" IS '일기 원문 (항상 저장)';

COMMENT ON TABLE "emotion_feedbacks" IS 'GPT 피드백 결과';

COMMENT ON COLUMN "emotion_feedbacks"."gpt_model_used" IS '추후 enum 고려. 예: gpt-3.5-turbo, gpt-4o, …';

COMMENT ON COLUMN "users"."first_activity_at" IS '이 사용자가 처음 감정일기 or 피드백 요청한 시간';

COMMENT ON COLUMN "user_passes"."first_used_at" IS '이 이용권이 처음 사용된 시간 (예: 감정 분석 요청됨)';

COMMENT ON COLUMN "passes"."expires_after_days" IS '만료일 계산용';

COMMENT ON COLUMN "submission_state"."sid" IS 'Tally 폼 고유 ID';

COMMENT ON COLUMN "submission_state"."uuid_code" IS 'user_passes.uuid_code';

COMMENT ON COLUMN "submission_state"."emotion_entry_id" IS 'emotion_entries.id';

COMMENT ON COLUMN "submission_history"."result_reason" IS 'not_found, expired, no_uses, inactive, exception';

COMMENT ON COLUMN "submission_history"."latency_ms" IS '응답까지 걸린 시간(ms)';

ALTER TABLE "user_passes" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id");

ALTER TABLE "user_passes" ADD FOREIGN KEY ("pass_id") REFERENCES "passes" ("id");

ALTER TABLE "emotion_entries" ADD FOREIGN KEY ("user_pass_id") REFERENCES "user_passes" ("id");

ALTER TABLE "emotion_entries" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id");

ALTER TABLE "emotion_entries" ADD FOREIGN KEY ("standard_emotion_id") REFERENCES "standard_emotions" ("id");

ALTER TABLE "emotion_feedbacks" ADD FOREIGN KEY ("emotion_entry_id") REFERENCES "emotion_entries" ("id");

-- 1. user_passes.user_id → users.id (삭제 시 구매 기록도 삭제)
ALTER TABLE user_passes
DROP CONSTRAINT user_passes_user_id_fkey;

ALTER TABLE user_passes
ADD CONSTRAINT user_passes_user_id_fkey
FOREIGN KEY (user_id) REFERENCES users(id)
ON DELETE CASCADE;

-- 2. user_passes.pass_id → passes.id (삭제 제한)
ALTER TABLE user_passes
DROP CONSTRAINT user_passes_pass_id_fkey;

ALTER TABLE user_passes
ADD CONSTRAINT user_passes_pass_id_fkey
FOREIGN KEY (pass_id) REFERENCES passes(id)
ON DELETE RESTRICT;

-- 3. emotion_entries.user_pass_id → user_passes.id (이용권 삭제 시 감정일기도 삭제)
ALTER TABLE emotion_entries
DROP CONSTRAINT emotion_entries_user_pass_id_fkey;

ALTER TABLE emotion_entries
ADD CONSTRAINT emotion_entries_user_pass_id_fkey
FOREIGN KEY (user_pass_id) REFERENCES user_passes(id)
ON DELETE CASCADE;

-- 4. emotion_entries.user_id → users.id (사용자 삭제 시 감정일기 user_id만 null 처리)
ALTER TABLE emotion_entries
DROP CONSTRAINT emotion_entries_user_id_fkey;

ALTER TABLE emotion_entries
ADD CONSTRAINT emotion_entries_user_id_fkey
FOREIGN KEY (user_id) REFERENCES users(id)
ON DELETE SET NULL;

-- 5. emotion_entries.standard_emotion_id → standard_emotions.id (감정 삭제 시 null 처리)
ALTER TABLE emotion_entries
DROP CONSTRAINT emotion_entries_standard_emotion_id_fkey;

ALTER TABLE emotion_entries
ADD CONSTRAINT emotion_entries_standard_emotion_id_fkey
FOREIGN KEY (standard_emotion_id) REFERENCES standard_emotions(id)
ON DELETE SET NULL;

-- 6. emotion_feedbacks.emotion_entry_id → emotion_entries.id (일기 삭제 시 피드백도 삭제)
ALTER TABLE emotion_feedbacks
DROP CONSTRAINT emotion_feedbacks_emotion_entry_id_fkey;

ALTER TABLE emotion_feedbacks
ADD CONSTRAINT emotion_feedbacks_emotion_entry_id_fkey
FOREIGN KEY (emotion_entry_id) REFERENCES emotion_entries(id)
ON DELETE CASCADE;

--7. submission_state.user_pass_id → user_passes.id (사용자 이용권을 참조하되, 부모 삭제 시 기록은 남기고 FK만 NULL로 비움(느슨한 FK))
ALTER TABLE submission_state
DROP CONSTRAINT IF EXISTS submission_state_user_pass_id_fkey;

ALTER TABLE submission_state
ADD CONSTRAINT submission_state_user_pass_id_fkey
FOREIGN KEY (user_pass_id)
REFERENCES user_passes(id)
ON DELETE SET NULL;

--8. submission_state.emotion_entry_id → emotion_entries.id (사용자 감정 피드백 내용을 참조하되, 부모 삭제시 기록은 남기고 FK만 NULL로 비움)
ALTER TABLE submission_state
DROP CONSTRAINT IF EXISTS submission_state_emotion_entry_id_fkey;

ALTER TABLE submission_state
ADD CONSTRAINT submission_state_emotion_entry_id_fkey
FOREIGN KEY (emotion_entry_id)
REFERENCES emotion_entries(id)
ON DELETE SET NULL;

--9. submission_history.user_pass_id → user_passes.id (사용자 이용권을 참조하되, 부모 삭제 시 기록은 남기고 FK만 NULL로 비움(느슨한 FK))
ALTER TABLE submission_history
DROP CONSTRAINT IF EXISTS submission_history_user_pass_id_fkey;

ALTER TABLE submission_history
ADD CONSTRAINT submission_history_user_pass_id_fkey
FOREIGN KEY (user_pass_id) REFERENCES user_passes(id)
ON DELETE SET NULL;

--10. submission_history.emotion_entry_id → emotion_entries.id (사용자 감정 피드백 내용을 참조하되, 부모 삭제시 기록은 남기고 FK만 NULL로 비움)
ALTER TABLE submission_history
DROP CONSTRAINT IF EXISTS submission_history_emotion_entry_id_fkey;

ALTER TABLE submission_history
ADD CONSTRAINT submission_history_emotion_entry_id_fkey
FOREIGN KEY (emotion_entry_id) REFERENCES emotion_entries(id)
ON DELETE SET NULL;

-- 조회 자주 쓰는 컬럼에 인덱스
-- submission_state
CREATE INDEX IF NOT EXISTS idx_submission_state_updated_at ON submission_state(updated_at);
CREATE INDEX IF NOT EXISTS idx_submission_state_status ON submission_state(submit_status);
CREATE INDEX IF NOT EXISTS idx_submission_state_uuid_code ON submission_state(uuid_code);
CREATE INDEX IF NOT EXISTS idx_submission_state_user_pass_id ON submission_state(user_pass_id);

-- submission_history
CREATE INDEX IF NOT EXISTS idx_submission_history_created_at ON submission_history(created_at);
CREATE INDEX IF NOT EXISTS idx_submission_history_uuid_code ON submission_history(uuid_code);
CREATE INDEX IF NOT EXISTS idx_submission_history_result_status ON submission_history(result_status);
CREATE INDEX IF NOT EXISTS idx_submission_history_result_reason ON submission_history(result_reason);
CREATE INDEX IF NOT EXISTS idx_submission_history_user_pass_id ON submission_history(user_pass_id);
CREATE INDEX IF NOT EXISTS idx_submission_history_entry_id ON submission_history(emotion_entry_id);

-- (선택) 모니터링 최적화: 최근 실패 빠르게
CREATE INDEX IF NOT EXISTS idx_submission_history_fail_recent
  ON submission_history(created_at)
  WHERE result_status = 'fail';

-- (선택) 복합 인덱스: 상태+시간 순 조회 최적화
-- 최근 상태별 목록이 잦다면 아래 중 하나만 선택
-- CREATE INDEX IF NOT EXISTS idx_submission_state_status_time ON submission_state(submit_status, updated_at);
-- CREATE INDEX IF NOT EXISTS idx_submission_history_status_time ON submission_history(result_status, created_at);
