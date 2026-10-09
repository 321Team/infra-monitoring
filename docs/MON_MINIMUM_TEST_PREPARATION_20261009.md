# MON 접근 경로·Probe 후속 최소 시험 준비

CODEX_ASSISTED · 이권욱. 2026-10-09 09:10~12:00 단독 작업창의 **준비 문서**이며 새 Runtime GO·AC 변경이 아니다. MON Lead 이재환 / SEC Review Owner 이하영의 기존 책임을 유지한다. 독립 리뷰는 창 종료 후 회수하고 Harbor 자동기동은 타 세션 범위다.

## 재사용할 증적과 남은 판단

| 항목 | 재사용 근거 | 추가로 필요한 범위 |
|---|---|---|
| 승인 단말 PF 성공·회수 | 병합된 [증적130](https://github.com/321Team/fds-project-evidence/pull/130): 제한 SA/Role, health200·무인증401, credential/리스너 정리 | 과거 종료 회차다. 현재 운영·비상 보유자/경로·감사·회수 입력과 승인 단말 배타성은 별도 |
| 현재 Grafana 접근 메타데이터 | [175](https://github.com/321Team/fds-project-evidence/pull/175) HEAD8bdba54 + [증적185](https://github.com/321Team/fds-project-evidence/pull/185) HEAD32eb6d2의 09:40 참조 보완 | 정상·비상 credential의 인적 소유, 회전·사용 감사·최종 통제 판단. Secret 값 조회로 대체하지 않음 |
| 격리 Probe 전이 | 병합된 [173](https://github.com/321Team/fds-project-evidence/pull/173) HEAD8be4f2e: 10/8 readiness/Endpoint 제외·복구, liveness restart0→1, 생성 객체 삭제·운영 차이0 | exec Probe 격리 사례의 성공이다. 실제6종 HTTP 경로 장애·모든 workload 재시작 성공을 증명하지 않음 |
| 실제6종 Probe 정의/현재상태 | [177](https://github.com/321Team/fds-project-evidence/pull/177) HEAD410042c: GET18건, controller6·Pod10 Ready, Endpoint UID 연결 | HTTP 음성 응답→Endpoint 제외·재시작 전이는 미시험. 누적 restart4/1/1의 원인·시각도 미확인. 모든6종 장애 주입을 신규 필수 AC로 만들지 않음 |
| monitor01 수신 경로 | [Runbook](RUNBOOK_P1_MON_01_20261002.md)의 기존 remote write204/Watchdog/API LB 시험과 증적91·94 | 병합된 [122](https://github.com/321Team/fds-project-evidence/pull/122)에서10/6 `.108`/잘못된 인증401 관측, [151](https://github.com/321Team/fds-project-evidence/pull/151)에서10/8 gateway 정책 원본 확보. **잔여는8443 차단 지점 귀속**이며 당시 gate/추가 실행 한계도 보존 |

## 권장 순서

1. **우선 문서·소유자 입력 정리.** 접근 장부의 실물 참조 정보는 보완됐으므로 같은 메타데이터를 다시 수집하지 않는다. 보관자·회전·감사·접근 처분을 MON/SEC가 채우면 필요한 음성 경로와 기대 판정을 고정할 수 있다. #130을 새 권한/토큰 승인으로 재사용하지 않는다.
2. **그다음8443 차단 구간 확인 준비.** 기존401/Source 관측을 반복하지 않고 [잔여 시험 입력](IF06B_REMAINING_TEST_INPUTS_20261009.md)에서 gateway 양측·receiver 동시 관측안을 고정했다. 과거 정책의 DROP에는counter가 없고, 기존 T2의 monitor01 SYN 도착 기준과 gateway DROP 위치가 충돌하므로 판정 기준과 관측 수단을 먼저 검토한다.
3. **실제 workload Probe 장애는 필요성이 확정된 최소 사례만.** #173/#177을 먼저 인수·대조하고, 부족한 HTTP 전이 사례가 실제 AC에 필요하다는 판단을 받는다. 현 APP27 후보와 운영 이미지가 다르면 기존 이미지 시험을 후보 검증으로 기록하지 않는다. MON 단일 replica나 local PV의 재시작은 수집/알림 공백이 있어 첫 후보로 임의 선정하지 않는다.

## monitor01 경로 시험을 구체화할 입력

실행 위치는 기존 정상 운영 계정과 승인된 Source 경로, 대상은 Runbook의 monitor01 `10.250.10.30`이다. 09:40 초안의401·Source 전체 미실행 표기는 #122/#151 원본 대조 후 정정했다. 아래는 추가 관측 시 준비 조건이며, 구체적인1회안과 미결정 경계는 [잔여 시험 입력](IF06B_REMAINING_TEST_INPUTS_20261009.md)을 따른다. 실행 명령/번들은 아직 승인·실행하지 않았다.

| 회차 항목 | 실행·정상 판정 조건 | 실패·중단 및 복구 |
|---|---|---|
| 출발지/관측 경로 | 정확한 호스트·Pod UID(해당 시)·Source/NAT·대상443/8443·인터페이스·관측자·원본 로그 시간 범위를 고정. `.108` 규칙에 실제 유입이 귀속되는지 제한된 패킷 헤더/접근 로그로 연결 | Source가 다르거나 관측이 없으면 INVALID/미확인. 룰을 확대하거나 경로를 바꾸며 재시도하지 않음 |
| 401 기존 증적 재사용 | #122의 TLS검증 성공·401·nginx/Source 관측을 연결. 이번 후속은 인증 시도 반복을 기본값으로 삼지 않음 | 과거 두 번 실행/덮어쓰기 한계 보존. 새443 관측 대조는 별도 제안된 무인증 GET `/`404이며401 재검증 아님 |
| 8443 직접 차단 | 같은 승인 Source에서 직접8443 요청과 대상 listener 존재·차단 정책/규칙 귀속을 함께 확보. 필요한 양성 대조는 서비스 상태를 바꾸지 않는 기존 기록/승인 요청 이용 | 단순 timeout은 접근통제 PASS가 아님. route/Source/수신기 중단과 구분 불가하면 미확인 |
| 관측·정리 | 회차별 최대 요청 수/전체 시간·출력 경로·도구 hash·수집 프로세스 PID/UID 및 종료 기준 고정 | 서비스·방화벽·인증서·SELinux 변경0. 시험 소유 관측 프로세스/파일만 종료·회수하고 기존 프로세스를 일괄 종료하지 않음 |

패킷 본문·Authorization·Secret 값은 수집하지 않는다. 스냅숏/정책 읽기는 런타임 경로 PASS가 아니다. API LB 장애 도구나 Watchdog 단절 시험은 이 경로 확인에 필요하지 않으므로 함께 실행하지 않는다.

## 실제 workload Probe를 추가할 경우의 Gate

- 정확한 AC/부족 증거, workload·namespace·controller/Pod UID·imageID·Probe 정의·Endpoint UID, 실행자·복구 인수자·비중첩 창을 고정한다. 아직 선정된 실제 장애 대상은 없다.
- readiness와 liveness를 분리한다. readiness 음성은 Ready=false와 해당 Endpoint 제외/복귀를, liveness 음성은 같은 Pod의 containerID/restart 변화 및 Ready/Endpoint 회복을 관측해야 한다. 새 Pod rollout을 같은 컨테이너 재시작으로 기록하지 않는다.
- 장애 주입은 이미 검토된 도구·정확한 한 대상·상한 시간·자동 회수·기존 콘솔 복구를 갖추어야 한다. 업무 앱 데이터/설정 변경이나 광범위 NetworkPolicy로 간접 장애를 만들지 않는다.
- 실패·예상 외 영향·복구 시간 초과·관측 불능이면 다음 사례를 중단한다. 새 apply/down/Pod삭제로 성공 모양을 만들지 않고 실패 원본을 보존한다. 승인된 원상태 복구와 그 확인 후에만 창을 반환한다.
- 현재 준비 단계는 실제 서버 설정을 바꾸지 않아 Runtime 원복 대상이 없다. **추가 시험 횟수·기간·새 AC나 예외 정책을 이 문서에서 확정하지 않는다.**

STATIC=문서/기존 증적 대조 / 추가 ACCESS_TEST·FAULT_TEST=NOT_RUN / REVIEW=PENDING / MERGE·Runtime GO=NOT_GRANTED.
