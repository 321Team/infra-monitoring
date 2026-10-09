# IF-06B 잔여 시험 입력 — 기존 성공 재사용과 8443 귀속

CODEX_ASSISTED · 이권욱 · 2026-10-09 KST. **실행 전 검토안 / 새 패킷 시험·정책 적용 NOT_RUN.** MON 시험·인수 이재환, K8S/SEC 정책 이하영, ICR 경로·증적 지원 이권욱의 기존 책임을 유지한다. 단독 작업창은 개별 정책 변경 GO가 아니다.

## 1. 기존 증적을 먼저 재사용

| 질문 | 검증한 원본 | 현재 판정 |
|---|---|---|
| `.108`의 잘못된 인증401·Source 보존 | [증적122 병합2bb083e의 README](https://github.com/321Team/fds-project-evidence/blob/2bb083eb370546b936cf2742abe38101e0b24230/evidence/P1-MON-01/pf-run2-canary-20261006T0725Z/README.md), worker03 `t1.out`·monitor01 `cap.txt`/nginx | 10/6 16:40 회차에서 관측됨. 전체 미실행 표기는 더 이상 적용하지 않음. 당시 두 번 실행했고 worker03 파일은 두 번째 결과라는 한계는 보존 |
| gateway 정책 원본 | [증적151 병합62eec37](https://github.com/321Team/fds-project-evidence/blob/62eec37158cf16e1345336f1c475de008b50b2e4/evidence/ICR-D-NET-01-01/if06b-policy-20261008/README.md), capture.tar.gz 내부 before/after 정책·nft | 10/8 00:54 조회에서 physical→management / priority-1 / target DROP / `.108→.30 tcp443` 단일 allow, 해당 흐름 SNAT 관측 없음. 현재 시점 재조회나 과거10/6 패킷 귀속은 아님 |
| `.108→.30:8443` 차단 지점 | #122 `t2.rc`=28, monitor01 캡처8443 SYN0 | **NOT_VERIFIED**. 연결 실패는 사실이나 worker/gateway/receiver 중 어디서 차단됐는지 당시 원본으로 확정할 수 없음 |
| 특정 DROP 규칙 counter | #151 내부 `before-nft.stdout`의 `drop # handle 606` | **counter 표현식 없음.** 기존 rule handle만으로 counter 전후를 얻을 수 있다고 약속하지 않음. handle606/618/619는 그 회차 값이며 새 실행에 하드코딩하지 않음 |

로컬 오프라인 대조: #122 manifest124/124, #151 외부 manifest21/21·archive 내부67/67, 선택11개 파일/압축본이 각 병합 커밋 Git blob과 동일했다. 이는 원본 무결성·출처 확인이며 새 Runtime 성공이나 AC 인수가 아니다. 철회된 #17 의견6052028091의 처분·기한은 근거로 사용하지 않고, 병합된 원본을 직접 대조했다.

## 2. 기존 시험 기준과 현재 정책의 충돌

기존 [K8S canary 계획](https://github.com/321Team/infra-kubernetes/blob/b4303f2df512a8791d2421203cf159567d076b2a/docs/change/P1-MON-01/P1_MON_01_IF06B_WORKER03_CANARY_20261002.md)의 T2는 **monitor01에 SYN이 도착**하고 SYN-ACK이 없는 관측을 요구한다. 그런데 #151의 gateway 정책은 일반 신규 non-DNAT tcp8443을 그 앞에서 DROP하도록 구성돼 있다.

따라서 기존 절차를 그대로 반복하면 monitor01 SYN0으로 다시 끝날 수 있다. 이를 성공처럼 보이게 하려고 gateway에8443을 열거나 기존 AC를 '아무 곳에서 막히면 PASS'로 바꾸지 않는다. 기존 정책을 유지한 **gateway 구간 귀속 관측**을 권장 검토안으로 올리되, 어떤 증거가 잔여 요구를 충족하는지는 MON/SEC가 먼저 확정해야 한다. 특정 규칙 귀속이 필수라면 승인된 별도 관측 수단이 필요하다.

## 3. 권장 1회 관측안 — 아래 수치는 제안, 실행 GO 아님

### 대상과 준비

| 위치 | 기존 역할/경로 | 실행 전 확보할 입력 |
|---|---|---|
| control01 | 기존 관리 API로 worker03 HEP/GNP 조회 및 승인 시 임시 canary 생성·회수 | 현재 UID/RV/spec·같은 selector/order 충돌·후보 명시적 NotFound·exact manifest/hash·회수 담당/콘솔 |
| worker03 `.108` | 기존 정상 `server07` 콘솔/승인 경로에서 요청 | route src `.108`·출발 인터페이스·CA 검증·도구 버전·회차별 출발 TCP 포트2개 가용성 |
| mgmt-gw01 `.58` | 기존 `server01_mgmt-gw` + 승인된 sudo/콘솔 | physical/management 인터페이스 실제 대응·현재 정책/routing/NAT·카운터 유무·정확한 관측 프로세스 소유권 |
| monitor01 `.30` | 기존 `server01_monitor` + 승인된 sudo/콘솔 | listener8443 존재·nginx/TLS 설정의 현재 승인 형상·firewalld runtime/permanent·수신 인터페이스·정상 remote write/heartbeat |

10/8 gateway 비밀번호 SSH/sudo는 그때의 수집 인증이다. 오늘 인증·콘솔 인수 가능성을 확인한 것으로 재사용하지 않는다. 현재 도구가 확인하지 않은 monitor01 SSH 키/권한도 가정하지 않는다.

### 순서와 요청 상한

1. 원본과 정책 기준을 고정하고 위 입력·복구 인수 및 회차 GO를 연결한다. 기존 worker03 host GNP는 호스트 발생 요청을 차단하므로, 필요 시 기존 **worker03 한 대·`.30:443/8443` 한정 임시 canary**를 검토된 절차로 생성/회수한다. 사용자 공간 Pod나 다른 계정으로 우회하지 않는다. gateway/monitor01 정책 변경은 이 안에 포함하지 않는다.
2. 제안 관측 시간은 **최대120초**, 첫20초는 무시험 배경 구간이다. worker03 송신·gateway ingress/egress·monitor01 ingress의 양방향 TCP 제어 헤더를 동시에 관측한다. 실제 도구 준비 표시·시각·rc·kernel drop·필터와 인터페이스를 기록하고 준비 실패면 요청0건으로 종료한다. pcap/본문/Authorization·Secret 값은 남기지 않는다.
3. **443 양성 대조1회:** 정상 CA/IP SAN 검증을 유지한 GET `/`를 후보로 둔다. 승인 nginx 소스는 이 경로에404를 정의하므로 TLS 성공·HTTP404·동일5-tuple의 gateway 양방향 통과/receiver 도착을 대조한다. 이는 인증401 재시험이나 정상 remote-write204 재시험이 아니다. 실제 live 설정이 다르면 이 기대값을 강제하지 않고 STOP한다.
4. **8443 음성 연결1회:** 별도 고정 출발 포트로 새 TCP 연결을 한 번 시도한다. 연결 상한5초, 앱 자동 재시도0. 커널 SYN 재전송은 같은 연결로 구분한다. 응답/timeout·errno·5-tuple·양방향 헤더를 보존한다. 두 요청 전체는20초 이내 후보로 두며, 성공 모양을 얻으려고 두 번째 터미널에서 반복하지 않는다.
5. 요청 후20초 관측과 기존 정상 remote write/Target/heartbeat 확인을 마친다. 보존한 UID/RV precondition으로 해당 회차 canary만 삭제하고 명시적 NotFound·기존 HEP/GNP/firewalld/NAT 불변·관측 프로세스 종료를 확인한다. 임시 canary 최대 존속180초를 제안하되, 실행 전에 독립적인 만료 회수·콘솔 실패 복구가 실제 동작하도록 검토해야 한다. 이 문서는 자동 회수 기능을 구현하거나 실행한 것이 아니다.

## 4. 판정과 중단·복구

| 관측 | 허용되는 결론 |
|---|---|
| worker 송신이 없거나 gateway ingress에 없음 | gateway 차단 귀속 불가. 상류/캡처/경로 조사 대상으로 유지 |
| gateway ingress SYN 있음·egress 없음, 같은 관측창443 양방향 유효·누락/drop0, 정책/route 불변 | **gateway 구간에서 소실되는 것과 정합**. 특정 nft rule에 의한 DROP 확정은 아님 |
| gateway egress SYN 있음·monitor01 ingress 없음 | 두 지점 사이 또는 관측 공백. monitor01 방화벽 PASS 아님 |
| monitor01 SYN 도착·SYN-ACK 없음 | 수신 노드 단계 조사 가능. 단순 패킷만으로 특정 firewalld 규칙 귀속 확정 불가 |
| 연결 성공·SYN-ACK/예상 외 응답·관측 불능 | 정상 차단 PASS 아님. 실패 원본 보존·추가 요청 중단·canary 회수 |

counter 없는 기존 규칙에 `counter`·로그·nftrace를 추가하는 행위, nft reset/flush·firewalld reload·conntrack 초기화는 순수 조회가 아니다. 특정 rule 귀속이 요구되면 별도 정확한 변경·부하/정보노출·원복·리뷰/GO를 준비하며 이 안에 몰래 포함하지 않는다. 배경 트래픽과 분리되지 않는 공용 counter 증가만으로도 특정 연결을 입증할 수 없다.

MON 건강 악화·Source/정책 drift·소유 UID 불일치·시간 초과면 다음 요청을 중단한다. 회수409는 force/이름만 삭제로 우회하지 않고 콘솔 인수자에게 넘긴다. 관리망 또는 모니터링 재시작으로 결과를 복구하지 않는다. 회수 실패·권한 부족은 원본으로 남기며 성공으로 보정하지 않는다.

## 5. 실행을 위해 남은 결정

1. MON/SEC: **gateway 구간 귀속**으로 잔여 목적을 충족할 수 있는지, **특정 규칙 귀속**까지 필요한지 확정. 기존 monitor01 SYN 도착 기준 변경이 필요하면 정식 판단을 연결.
2. K8S/SEC·MON: 정확한 source/manifest, 임시 canary 생성·독립 만료 회수 방식, 이번 회차 대상·시간·관측 및 복구 인수자 확인. 현재 문서는 실행 번들 승인이 아님.
3. gateway/monitor01 기존 정상 계정의 이번 회차 콘솔·sudo 인증 경로 확보. 암호·키는 공유하지 않음.

그 전에는 문서·원본 검증까지만 진행한다. 이전1회 GO를 재사용하거나 새 예외·완료·병합을 선언하지 않는다.
