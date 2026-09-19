# monitor01 TLS/receiver 구성 후보

상태: **DRAFT / RENDER_ONLY / NOT_DEPLOYED**. 책임 티켓은 [P1-MON-01 #17](https://github.com/321Team/fds-project-baseline/issues/17)이다. Lead 이재환, Support 이권욱, 보안 검토 이하영을 유지한다. 이번 후보는 서비스 설치·시작·중지, 방화벽/SELinux 변경, K8s apply, CA 재발급을 수행하지 않는다.

## 이미 확인한 PKI 인계

2026-09-19 사용자 콘솔 자료에서 CA 서명, 공개 반환 checksum, monitor01의 `PUBLIC_KEY_MATCH=PASS`·`CHAIN_IP_SERVER_PURPOSE=PASS`, ca01 `fds-ca is inactive`를 확인했다. CA VM 전원 OFF는 미확인이다. 스크린샷은 사용자 제출 증적이며 도구가 서버에 직접 접속한 로그가 아니다. [증적 편입 Draft PR #18](https://github.com/321Team/fds-project-evidence/pull/18), [고정 수신 기록](https://github.com/321Team/fds-project-evidence/tree/74745237108830e0c19912e960b2e26f0957f04b/evidence/P1-MON-01/monitor01-pki-20260919)에 원본 화면 9개·공개 PEM·해시와 제한을 보존했다. 편입 독립 리뷰·병합은 대기다.

| 항목 | 인계값 |
|---|---|
| monitor01 | `10.250.10.30`, `server01_monitor` |
| Leaf | `/home/server01_monitor/monitor01.crt` |
| 현지 개인키 | `/etc/fds/pki/monitor01/request/monitor01.key` (반출 없음) |
| 반환 Root | `/home/server01_monitor/fds-root-ca.crt` |
| Serial | `1001` (hex) |
| 유효기간 KST | 2026-09-19 19:57:32 ~ 2027-09-19 19:57:32 |
| SAN / EKU | IP `10.250.10.30` / serverAuth |

Root certificate SHA256: `6a75baf4dbe03ef24cce944e616384d318f7ca919cd7bd914624b4cebac06b10`.
Leaf certificate SHA256: `98424fca698e250c72c3c1c0fb7bc3de84f34926fc1fc3ebf82e2d059efdf7a4`.
CSR SHA256: `37fda6d9fb99f101bf213a8e6a070c3e6dce3ba5238b54f178d9c62c8ddd3fa1`.

이 경로는 현재 인계 위치다. 실제 서비스 파일 권한·소유권·SELinux label·상위 디렉터리 접근권한은 배포 통합에서 검증한다. 홈 디렉터리 인증서를 서비스 최종 위치로 확정한 것이 아니다. 검증된 개인키를 새로 생성하거나 출력·복사해 외부로 전달하지 않는다.

## 구성 선택과 미확정 입력

기존 확정 요구사항: `.30:443`, 프로젝트 CA/전용 IP SAN, TLS 1.2 이상, Remote Write 전용 경로, localhost receiver, heartbeat=1, `absent_over_time(fds_monitoring_heartbeat[5m])`, IF-24 부재. 기존 14개 Runtime AC와 보조 2항목을 유지한다.

이번 구현 후보: NGINX TLS reverse proxy + Basic Auth 파일 + 관측한 Source IPv4 개별 allowlist, Prometheus receiver, 송신측 heartbeat-only relabel. NGINX/Basic Auth 선택과 파일 배치는 구현 제안이며 기존 승인 설계로 표시하지 않는다. 인증 형식은 Lead·보안 검토에서 서비스 통합과 함께 수용한다.

| 아직 필요한 실제 입력 | 확정·확인 범위 |
|---|---|
| IF-06B 실제 송신 Source IPv4 및 반환 경로 | K8S/Network·MON 공동 실측. Worker 주소나 Pod CIDR로 추정하지 않음 |
| receiver 로컬 port, 설정·data 경로/용량, 실행 모델 | MON Lead. 예전 관측의 Cockpit 9090을 중지하지 않음. 9090과 Blackbox 9115는 후보 입력에서 제외 |
| NGINX/Prometheus 승인 버전·Harbor digest·취약점 결과 | MON/HBR 인계. latest 및 미확인 digest를 작성하지 않음 |
| Basic Auth 사용자명, proxy 암호 파일, sender Secret mount·Root mount | MON/SEC. 입력 파일에는 비밀번호·hash를 넣지 않고 경로만 기록 |
| 서비스 계정/권한, unit 또는 컨테이너, SELinux, Host Firewall | 해당 기존 소유자와 통합. 자동 보안 우회 없음 |

## 로컬 생성

Python 3 표준 라이브러리만 사용한다. 저장소 루트에서 `inputs.example.json`을 별도 로컬 입력 파일로 복사하고 null/빈 목록을 실제 인계값으로 채운다. 예제의 Leaf/key는 알려진 인계 경로이며 필요하면 승인한 최종 현지 경로로 변경한다. `source_ipv4`는 실제로 관측한 개별 IPv4만 받는다. 입력 검증은 관측·승인 사실을 증명하지 않는다.

```bash
python3 monitor01/render_candidate.py --inputs /absolute/path/monitor01-inputs.json
python3 monitor01/render_candidate.py --inputs /absolute/path/monitor01-inputs.json --output-dir /absolute/existing/parent/new-candidate
```

기본 동작은 입력 검사뿐이다. `--output-dir`을 주면 새 폴더(0700)에 후보 파일(0600)을 생성한다. 이미 존재하는 출력 경로, 미확정 입력, CIDR/전체 허용, 설정문 주입, 비밀값 필드는 중단한다. 출력 폴더를 `/etc` 등 활성 설정 위치로 지정하지 않는다. 파일 생성 결과는 `CANDIDATE_RENDERED_NOT_DEPLOYED`이며 운영 준비/승인 PASS가 아니다. 파일 생성 중 I/O 오류가 나면 부분 생성 폴더를 활성 설정에 사용하지 않고 원인을 해결한 후 다른 새 후보 폴더에서 재생성한다.

| 출력 파일 | 통합할 위치·용도 |
|---|---|
| `nginx-monitor01.conf` | 승인 NGINX의 `http` context include 후보. 정확한 POST `/api/v1/write`만 통과 |
| `receiver.prometheus.json` / `receiver.argv.json` | receiver 설정과 실행 인자 목록. `127.0.0.1:<port>` / remote-write-receiver 활성화 |
| `sender.remote-write.fragment.json` | in-cluster Prometheus의 기존 설정에 병합할 조각. 전체 설정을 대체하지 않음 |
| `sender.heartbeat.rules.json` | in-cluster Prometheus에만 1회 로드. receiver에 넣으면 단절을 숨기므로 금지 |
| `watchdog.rules.json` | receiver 설정의 `rule_files` 위치에 연결 |
| `CANDIDATE.json` | 생성 상태와 잔여 통합 작업 기록 |

JSON 출력은 YAML의 부분집합이지만 실제 승인 버전의 `promtool check config`/`check rules`로 파싱해야 한다. receiver argv는 실행 스크립트가 아니며 바이너리·unit·컨테이너·retention/data 용량·권한을 따로 통합해야 한다. 생성기는 개인키/Secret 파일을 읽지 않는다.

## Payload·TLS 통제 범위

송신 `write_relabel_configs`는 `fds_monitoring_heartbeat`만 보내고 `__name__` 이외 label을 제거한다. P0의 단일 sender에서 `vector(1)` recording rule을 중복 없이 사용한다. 승인 self/target-health metric은 구체 allowlist 인계 후 추가하며 전체 업무 metric 복제를 허용하지 않는다.

**Payload allowlist의 집행 위치는 송신 Prometheus다.** NGINX는 IP·TLS·인증·HTTP 경로/메서드를 검사하며 protobuf metric 본문을 검증하지 않는다. 유효 인증정보를 가진 임의 클라이언트가 송신 relabel을 우회할 수 있다는 경계를 보안 검토·인수에서 명시한다. receiver측 metric 검사 PASS로 표현하지 않는다. 인증정보는 Secret/현지 파일로 주입하며 root/인증서/key path 접근과 실제 소유권은 현장에서 확인한다.

## 검증·적용 순서와 중단/복구

1. 입력과 승인 artifact/digest·후보 source SHA를 고정하고 native parser를 실행한다. NGINX에는 기존 http context와 다른 server block의 영향도 포함해 `nginx -t`를 수행한다. receiver/sender 전체 config와 rule은 실제 버전의 `promtool`로 확인한다. 실패하면 서비스 변경 없이 수정한다.
2. 현재 service/config·활성 포트·방화벽·SELinux와 data 상태를 배포 범위에 맞춰 백업한다. 과거 현황을 현재값으로 간주하지 않는다. 범용 현황 수집을 다시 요구하지 않고 변경 대상만 확인한다.
3. Lead의 기존 운영 절차에서 localhost receiver → TLS proxy → sender 통합 순으로 적용한다. 새 서비스 통합 코드/실행 설정은 코드 PR 독립 리뷰 대상이다. 이 PR에 installer는 없으며 후보 파일 복사만으로 배포 완료가 아니다.
4. 아래 Runtime 시험의 실제 source·시각·SHA/digest·명령·결과를 수집한다. 실패하면 sender 추가 변경을 되돌리고 이번 proxy/receiver 변경만 직전 구성으로 복구한다. 기존 data/CA/개인키·Cockpit은 삭제/초기화하지 않는다. 신규 receiver는 중지하고 생성 data는 증적으로 보존한다.

| 시험 | 정상 판정 |
|---|---|
| 실제 sender → `.30:443` TLS/유효 인증/정상 Remote Write | 2xx와 receiver에서 heartbeat=1 확인; 빈 curl POST의 400을 성공으로 보지 않음 |
| 같은 허용 Source의 무인증/틀린 암호 | 401 |
| 비허용 Source의 유효 인증 | Host Firewall 차단 또는 proxy 403; `X-Forwarded-For` 조작으로 대신하지 않음 |
| GET write 경로 / 다른 경로 | 405 / 404 또는 상위 방화벽 차단 |
| 잘못된 CA·IP / TLS 1.0·1.1 | 검증/handshake 실패; `-k` 사용 금지 |
| receiver 외부 접근 / receiver listen | 외부 차단 / `127.0.0.1:<port>`만 확인 |
| sender payload | 실제 receiver series에서 heartbeat만, 개인정보·업무 label 부재 확인 |
| sender 중단·복구 | 5분 이내 단절 감지, 재개 후 정상 전환 원본 기록 |
| IF-06A Blackbox | 별도 통합에서 edge01 HTTPS/API LB TCP 실패·복구 검증 |

`absent_over_time(...[5m])`에는 추가 `for: 5m`을 넣지 않았다. 평가 주기(후보 15s)·전송 지연 때문에 5분 이내 AC를 정적으로 보증하지 않는다. 중단/마지막 sample/첫 감지 시각을 실측하고 기준을 초과하면 미통과로 남긴다. 시간 기준을 편의상 5분+평가주기로 완화하지 않는다. receiver는 알림 상태를 평가하며 외부 통보 채널 또는 IF-24를 추가하지 않는다.

## 기술 근거

- [Prometheus 설정](https://prometheus.io/docs/prometheus/latest/configuration/configuration/): Remote Write, relabel, 파일 기반 인증 참조.
- [Prometheus 실행 인자](https://prometheus.io/docs/prometheus/latest/command-line/prometheus/): listen 주소와 receiver 활성화.
- [NGINX Basic Auth](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html): 암호 파일과 `satisfy` 결합.

문서 확인: 2026-09-19. 최신 문서는 API 참고이며 미확정 운영 버전의 parser/runtime 통과를 대신하지 않는다.
