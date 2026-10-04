# P1-MON-01 #17 승인 단말 port-forward 재시험 도구 (v4)

상태: REVIEW READY / RUNTIME NOT RUN. 리뷰·병합 전에는 운영 서버에서 실행하지 않는다.

근거: [#17 SEC·K8S 결정 5948143297](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5948143297) → [(A) cicd-runner01 승인 5948735665](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5948735665), PMO/QA 리뷰 [v1 5966473585](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5966473585) · [v2 5966632557](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5966632557) · [v3 5980682612](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5980682612).

v3까지는 붙여넣기 명령 묶음이었다. v3 리뷰(PF-01·PF-02)는 "앞 단계가 실패해도 다음 명령이 실행되는" 구조 결함이라, 단계마다 RC를 스스로 확인하는 스크립트로 바꿨다. `set -e`는 쓰지 않는다(정리 단계 전에 셸이 끝나면 안 되므로).

## 파일

| 파일 | 실행 위치 | 역할 |
|---|---|---|
| `pf_cp.sh` | control01 `server02` | `pre` 사전 조회 · `create` 임시 SA/Role/RoleBinding · `token` TokenRequest·실제 TTL 판정·kubeconfig 출력 · `recheck` Grafana Pod 재확인 · `delete` UID precondition 삭제 |
| `pf_runner.sh` | cicd-runner01 `server01_cicd-runner` | `pre` · `stop` runner 정지 · `install` kubectl 설치(체크섬) · `place` kubeconfig 배치(stdin) · `verify` route·whoami·can-i · `pftest` port-forward 시험 · `cleanup` 공통 정리·Restore Gate · `restore` runner 재기동 |
| `pf_gh.sh` | PC(GitHub API) | `pre` / `after_stop` / `post_restore` runner 상태 raw JSON·시각·endpoint·RC 기록과 판정 |
| `test_pf_retest.sh` | 어디서나(CI 포함) | 가짜 kubectl·curl·systemctl·sudo·pgrep·ss·ip·getent로 실패 경로를 재현하는 오프라인 MOCK 시험 |

모든 판정은 각 회차 폴더의 `status.txt`에 `KEY=VALUE`로 남는다. 토큰 원문은 어떤 파일에도 쓰지 않는다(control01은 표준출력으로만 내보내고, runner는 `/dev/shm`의 회차 전용 경로에 0600으로 둔 뒤 정리 단계에서 지운다).

## 실행 순서

`RUN` 이름은 회차마다 새로 만든다(예: `~/pf-test/run-20261006T0900`). 이미 있으면 `pre`가 멈춘다.

| # | 위치 | 명령 | 다음으로 가는 조건 / 실패 시 |
|---|---|---|---|
| 1 | PC | `pf_gh.sh pre DIR` | `RESULT=PASS`(online·busy=false·queued 0·in_progress 0). 아니면 시작하지 않음 |
| 2 | control01 | `pf_cp.sh pre RUN` | `PRE=PASS`. 출력된 `GRAFANA_POD`·`OTHER_POD`를 runner 단계에 사용 |
| 3 | runner | `pf_runner.sh pre RUN` → `stop RUN` | `RUNNER_STOPPED_LOCAL=PASS`. 실패하면 `restore` 없이 중단(객체 생성 전) |
| 4 | PC | `pf_gh.sh after_stop DIR` | `runner_status=offline`. 아니면 runner `cleanup NOT_CREATED` → `restore` |
| 5 | runner | `pf_runner.sh install RUN` | `KUBECTL_INSTALLED=PASS`. 실패하면 → 13번(정리, G0=`NOT_CREATED`) |
| 6 | control01 | `pf_cp.sh create RUN` | `TEMP_RBAC_CREATED=PASS`. 실패·부분 생성이면 → 12번 |
| 7 | control01 | `pf_cp.sh token RUN` | `TOKEN_ACTUAL_TTL_LE_900=PASS`이면 `TOKEN_EXP=…`와 kubeconfig가 출력됨. 실패면 → 12번 |
| 8 | runner | `pf_runner.sh place RUN <TOKEN_EXP>` 후 kubeconfig 붙여넣기, Ctrl-D | `KUBECONFIG_PLACED=PASS`. 그 뒤 control01 토큰 화면은 캡처하지 않고 터미널 세션을 닫는다 |
| 9 | runner | `pf_runner.sh verify RUN <GRAFANA_POD> <OTHER_POD>` | `AUTHZ=PASS`·`ROUTE_SRC_10.250.10.20=PASS`·`AUTH_IDENTITY_EXPECTED=PASS`. 하나라도 아니면 → 12번 |
| 10 | control01 | `pf_cp.sh recheck RUN` | `POD_RECHECK=PASS`. Pod가 바뀌었으면 권한을 넓히지 않고 → 12번, 새 회차 |
| 11 | runner | `pf_runner.sh pftest RUN <GRAFANA_POD>` | `GRAFANA_HEALTH_200`·`GRAFANA_UNAUTH_401`·`PF_PROCESS_STOPPED` PASS. 결과와 무관하게 → 12번 |
| 12 | control01 | `pf_cp.sh delete RUN` | 화면의 `TEMP_OBJECTS_REMOVED` 값(PASS / NOT_CREATED / FAIL)을 13번에 넘김 |
| 13 | runner | `pf_runner.sh cleanup RUN <12번 값>` | `RESTORE_GATE=PASS`일 때만 14번. BLOCKED면 runner offline 유지·#17 재검토 요청 |
| 14 | runner | `pf_runner.sh restore RUN` | `RUNNER_RESTORED_LOCAL=PASS`. Gate가 PASS가 아니면 스크립트가 거부한다 |
| 15 | PC | `pf_gh.sh post_restore DIR` | `runner_status=online` → `RUNNER_RESTORED=PASS` |

`pftest`가 중단되거나 셸이 끊겨도 12→13번은 그대로 실행한다. `cleanup`이 남은 port-forward를 찾아 회수한다.

## Restore Gate (`pf_runner.sh cleanup`)

| 값 | 허용(재기동 가능) | 차단 |
|---|---|---|
| `TEMP_OBJECTS_REMOVED_CP`(control01 12번) | `PASS`, `NOT_CREATED` | 그 외 |
| `PF_PROCESS_STOPPED` | `PASS`, `NOT_STARTED` | `FAIL_IDENTITY_MISMATCH`, `FAIL_ALIVE`, `FAIL_LISTENER` |
| `OLD_TOKEN_AUTH_AFTER_SA_DELETE` | `DENIED`(만료 전 Unauthorized), `EXPIRED_NOT_PROVEN`(만료 후 — 삭제 실증 아님으로 구분 기록), `NOT_TRANSFERRED`(runner에 전달 전) | `NOT_DENIED`, `NOT_VERIFIED_FILE_OR_TOOL_MISSING` |
| `KUBECONFIG_REMOVED` | `PASS`, `NOT_TRANSFERRED` | `FAIL` |
| `TEST_KUBECTL_REMOVED` | `PASS`, `NOT_INSTALLED` | `FAIL` |

`NOT_TRANSFERRED`는 스크립트가 `place` 성공 여부로 정하며 사람이 입력하지 않는다. 미전달을 `DENIED`로 바꿔 쓰는 우회는 불가능하다.

## 리뷰 지적 대응

| 지적 | 반영 |
|---|---|
| PF-01 체크섬 실패가 `tee`에 가려지고 `;` 뒤 실행이 계속됨 | `install`은 서브셸에서 각 curl·`sha256sum --check`(tee 없이 파일로)·chmod·version의 RC를 확인하고 실패 시 즉시 종료, 받은 파일을 지운다. 바이너리는 회차 전용 `RUN/bin`에만 받아 이전 파일을 재사용하지 않는다 |
| PF-01 dry-run 실패 → create 금지 | `create`는 dry-run RC 0일 때만 실제 create |
| PF-01 create 일부 실패 시 PASS 금지 | create RC 0 **그리고** 출력에 "created"로 나온 3개 객체의 UID 조회가 모두 될 때만 `TEMP_RBAC_CREATED=PASS`. 이번 회차가 만든 객체만 `created.env`에 소유 기록 |
| PF-01 JWT 파싱 실패·필수 claim 누락 | 파서 예외 RC 3, aud 없음·TTL>900 RC 4 → `TOKEN_ACTUAL_TTL_LE_900=STOP_RC_*`, kubeconfig를 출력하지 않음 |
| PF-02 공통 정리에 port-forward 종료 없음 | `cleanup` 첫 단계가 `stop_pf`(PID 종료→대기→생존·리스너 부재 확인). `PF_PROCESS_STOPPED`를 Gate에 포함 |
| PF-02 `kill %1`은 식별자 아님 | `pf.pid`에 PID 저장, 준비 확인 뒤 `/proc` cmdline+starttime을 `pf.ident`로 저장. 정리 때 일치할 때만 종료, 다르면 건드리지 않고 `FAIL_IDENTITY_MISMATCH` |
| PF-02 13000 선점 미확인 | `pre`·`pftest`에서 리스너가 있으면 종료시키지 않고 STOP |
| PF-02 미발급·미전달 구분 | `NOT_TRANSFERRED` 상태값, `--kubeconfig` 회차 경로 명시 |
| PF-02 만료 401과 삭제 무효화 구분 | `TOKEN_EXP`와 현재 시각 비교로 `DENIED` / `EXPIRED_NOT_PROVEN` |
| 비차단 P0 설명과 실제 저장 차이 | `pf_gh.sh`가 세 시점마다 raw JSON·KST·endpoint·RC를 저장하고, 판정은 저장한 JSON에서 읽음 |
| 비차단 Ingress 수 | `get ingress -A -o json`의 `items` 길이와 조회 RC로 판정 |
| 비차단 임시 객체 소유권 | 삭제는 소유 UID를 `DeleteOptions.preconditions.uid`로 건 raw DELETE. 같은 이름의 다른 UID는 삭제하지 않고 FAIL |

## MOCK 시험

`bash ops/pf-retest/test_pf_retest.sh` — 14개 시나리오, 65개 점검. CI `Source validation`에서도 실행한다.

| 시나리오 | 확인 내용 |
|---|---|
| S1 정상 | 전 단계 PASS, 토큰이 control01 파일에 남지 않음, SA 삭제 뒤 옛 토큰 DENIED, runner 재기동 |
| S2 다운로드 실패 | kubectl 실행 0회, create 호출 0회, Gate PASS(`NOT_TRANSFERRED`/`NOT_INSTALLED`) |
| S3 체크섬 불일치 | kubectl 실행 0회, `CHECKSUM_RC` 비0 기록, 받은 파일 삭제 |
| S4 dry-run 실패 | 실제 create 0회, 삭제 결과 `NOT_CREATED` |
| S5 부분 생성 | PASS 없음, 토큰 발급 거부, 이번 회차가 만든 SA만 삭제 |
| S6 JWT 파싱 실패 / TTL 3600 | STOP, kubeconfig 출력 없음 |
| S7 13000 선점 | STOP, 기존 리스너 유지, PID 기록 없음 |
| S8 port-forward 시작 실패 | `PF_START=FAIL`, 프로세스 회수 PASS |
| S9 HTTP timeout | 판정 FAIL, 프로세스·리스너 회수 |
| S10 시험 중 강제 종료 | 남은 port-forward를 `cleanup`이 회수, Gate PASS |
| S11 객체 삭제 실패 | Gate BLOCKED, `restore` 거부, runner offline 유지 |
| S12 PID가 무관한 프로세스 | 종료하지 않음(`FAIL_IDENTITY_MISMATCH`), Gate BLOCKED |
| S13 옛 토큰이 계속 인증됨 | `NOT_DENIED`, Gate BLOCKED |
| S14 RBAC가 넓음(list pods 허용) | `DENY_POD_LIST=FAIL`, `AUTHZ=FAIL` |

한계: MOCK은 스크립트의 분기와 RC 처리만 시험한다. 실제 RBAC 평가, kubectl port-forward의 WebSocket/SPDY 동작, API LB 경로, Grafana 응답, runner 서비스 동작은 NOT VERIFIED이며 Runtime 회차에서만 확인된다. Windows Git Bash에서는 NTFS 권한 표시 한계로 `stat -c %a`만 시험용으로 대체한다(Linux CI는 실제 `stat`).

## 서버 전달

control01과 runner 사이·PC와 서버 사이 파일 경로가 없으므로, 병합된 파일을 `gzip -9 | base64` 블록(각 2.5KB 이하)으로 원격 화면에 붙여넣고 받은 쪽에서 SHA-256을 대조한다. SHA가 병합 커밋의 파일과 다르면 실행하지 않는다.

AI 사용: CLAUDE_ASSISTED
