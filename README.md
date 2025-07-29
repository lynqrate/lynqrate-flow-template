# lynqrate-flow-template

## Lynqrate Tally & Make Template

이 리포는 크몽/유료 템플릿 서비스용 Tally- Make 자동화 흐름 및 DB 설계를 정리한 저장소입니다.

### 구성
- **tally-form.md** : 감정일기 입력 폼 필드 요약
- **make-flow.md** : Webhook → 감정 정규화 → GPT 피드백 생성 흐름
- **lynqrate-flow-template-schema.sql** : Supabase 테이블 구조
- **lynqrate-flow-template-dbml** : ERD용 dbml

### 사용 예시
1. Tally 폼 응답 → Make Webhook 트리거
2. 인증코드 검증 및 감정 정규화
3. GPT 피드백 생성 후 DB 저장
4. 남은 회차 차감 및 사용자 응답 전송
