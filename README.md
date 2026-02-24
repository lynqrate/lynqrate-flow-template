# Mind-Echo
AI 기반 감정 기록/분석 서비스 Mind-Echo DB 설계 및 자동화 흐름을 정리한 저장소입니다.

### 구성
- **tally-form.md** : 감정일기 입력 폼 필드 요약
- **make-flow.md** : Webhook → 감정 정규화 → GPT 피드백 생성 흐름
- **lynqrate-flow-template-schema.sql** : Supabase 테이블 구조
- **lynqrate-flow-template-dbml** : ERD용 dbml

## 시스템 흐름
1. Tally 폼 응답 → Make Webhook 트리거
2. 이용권 코드 검증 및 감정 데이터 정규화
3. GPT-4o 감정 분석 및 피드백 생성 후 DB 저장
4. 이용권 회차 차감 및 사용자 응답 전송
5. 이용권 소진 시 전체 회차 자동 요약 생성 → 다음 이용권 컨텍스트 연결

## 기술 스택
Supabase (PostgreSQL) / DBML
