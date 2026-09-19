# monitor01 구성 후보 검증 기록

검증일: 2026-09-19 KST. 실행 위치: 분석용 Linux 작업 환경, 실제 monitor01/ca01 접속 없음. 기준 main: `73b9432e8c793f64469ea708c14018f010ad74c1`. 검토할 최종 commit SHA는 이 변경의 PR 본문에 연결한다.

| 단계 | 수행·결과 | 한계 |
|---|---|---|
| 원본 확보 | 기준 main 42파일 Git blob 42/42 일치 | 이후의 변경은 아래 후보 범위 |
| STATIC | `python3 tools/check_source.py` PASS | Python AST·JSON/YAML 구문·제한 secret pattern 검사 |
| UNIT | `python3 -m unittest discover -s monitor01 -p 'test_*.py' -v` 13/13 PASS | 합성 입력·임시 폴더만 사용 |
| 기존 이관 보존 | `python3 tools/verify_migration.py` 27/27 PASS | E-K3S 참고 소스 무결성 |
| native parser | NGINX·promtool 없음, NOT RUN | 승인 실제 버전에서 `nginx -t` 및 `promtool check config/rules` 필요 |
| CI | PR 생성 후 실행 결과 별도 확인 | 로컬 UNIT을 CI 성공으로 표현하지 않음 |
| Runtime/배포 | NOT RUN | 서비스·호스트 정책·CA 변경 없음 |
| 독립 리뷰/병합 | 대기 | 작성자 자체 점검은 독립 승인 아님 |

13개 시험은 미확정 입력·unknown/secret 필드·port 오형식/예약값·전체 허용/CIDR/잘못된 source·경로 주입·키/credential 경로 충돌·사용자명 주입의 중단, proxy/TLS/Auth 계약, heartbeat-only 및 label 제한, localhost receiver/추가 지연 부재, 입력 불변성, 기존 출력 보존과 파일 mode, symlink 경로 거부를 확인한다. 생성된 설정의 실제 parser/네트워크 동작 시험으로 확대하지 않는다.

## 변경·복구 범위

추가: `monitor01` 입력 검증/생성기·예제·단위시험·인계/실행 준비 Runbook. 변경: README·정본 차이 목록과 기존 source-validation에 무배포 UNIT 단계 추가. 워크플로 권한/Runner/Secret 및 기존 E-K3S 파일은 유지한다.

검토 후보 철회 시 이 소스 변경을 되돌리면 된다. 실제 서비스가 이 변경을 소비한 이후에는 Git revert만으로 복구 완료를 선언하지 않고 인계 Runbook의 현장 복구·재검증을 수행한다. PKI 완료 증적은 별도 evidence PR의 원본 보존·독립 편입 절차를 유지한다.
