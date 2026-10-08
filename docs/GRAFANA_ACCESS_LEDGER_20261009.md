# Grafana 관리·비상 접근 기록 — 2026-10-09

작성 지원 이권욱 / MON Lead 이재환 / SEC Review Owner 이하영. 현재 조회 근거는 [evidence#175](https://github.com/321Team/fds-project-evidence/pull/175) HEAD `8bdba54d1ed199e1b78e4ecf64ab9ee53dabe3a3`의 00:26 KST projection이다. 이 증적은 작성 시 편입 리뷰 대기다. 과거 승인 단말 회차는 병합된 [evidence#130](https://github.com/321Team/fds-project-evidence/pull/130)을 참조한다.

**현재 판정: 승인 관리 경로의 과거 성공은 있지만, 승인 단말만 접근할 수 있다는 배타성은 미입증이다.** 아래 표는 조회 사실과 추가로 받아야 할 자료를 구분한 인계 기록이며, 관리 권한 신설·제거, 새 시험 GO, 예외 승인 또는 #17 AC 판정이 아니다. 철회된 #17/#30 예외 제안의 기한·처분을 재사용하지 않는다.

## 1. 경로별 확인 상태

| 경로 | 확인된 위치·주체·범위 | 감사·회수 근거 | 남은 정보 |
|---|---|---|---|
| 승인 단말의 제한 port-forward — 과거1회 | 10/6 cicd-runner01 `10.250.10.20`, OS `server01_cicd-runner`, API 주체 `system:serviceaccount:monitoring-api:p1-mon-pf-verify` → API LB `.109:6443` → 고정 Grafana Pod3000. `127.0.0.1:13000`에 바인딩. 운영자 이재환. PC `.29`는 GitHub 상태 조회·전달을 맡았으며 직접 PF 출발지로 혼동하지 않음 | #130에서 whoami/can-i6개, health200/무인증 search401, SA/Role/Binding UID 삭제, 옛 토큰 만료 전 DENIED, `/dev/shm` kubeconfig·시험 kubectl·PF 프로세스 정리, Runner online 복구 | 이 회차는 종료됨. 새 회차 단말·사용자·TokenRequest audience/TTL/GO를 과거 값으로 자동 승인하지 않음 |
| 정상 Grafana Service | 현재 monitoring-api/grafana는 ClusterIP `10.111.143.44:3000`, Ingress0, NodePort/LoadBalancer/externalIPs 없음. worker03의 Grafana Pod hostNetwork/hostPort 없음 | Kubernetes 조회와 UID/resourceVersion·수집 시각이 #175에 있음. namespace default-deny가 ingress를 선택하며 수집 NetworkPolicy에 Grafana ingress allow 없음 | CNI·호스트·API tunnel·관리 예외를 포함한 전체 경로 차단 입증은 아님. 현재 외부 음성 시험을 새로 수행하지 않음 |
| control01의 관리 kubeconfig 보관 | `/etc/kubernetes/admin.conf`, `/etc/kubernetes/super-admin.conf` 존재, root:root0600. 이번 조회자는 기존 svc_ansible→sudo 읽기 전용 접근 | stat 메타데이터만 수집. 파일 내용·개인키·토큰은 읽거나 게시하지 않음 | 인증서 주체·현재 유효성, 인적 보유자, 원격/콘솔 사용조건, 다른 사본 위치, sudo·API 감사 원본 및 회수 절차 **미확인**. 파일 존재가 특정 사람의 사용 승인이나 인증 성공을 뜻하지 않음 |
| 광범위 관리자 API 권한 | live ClusterRoleBinding `cluster-admin`→Group `system:masters`, `kubeadm:cluster-admins`→동명 Group. 둘 다 cluster-admin wildcard 권한 | 정적 Role/Binding 원문 projection 보존. 새로운 권한 생성 없음 | 그룹에 속한 인증 주체·인적 소유자·현재 유효 credential/단말 목록 미확인. RBAC binding만으로 승인 단말 제한을 입증할 수 없음 |
| 시스템 controller GET 후보 | generic-garbage-collector·namespace-controller의 get + wildcard resource 규칙 | #175 분석은 CREATE_OR_WILDCARD와 GET_ONLY_CANDIDATE를 구분 | 실제 PF 연결 방식/인가 결과 **미시험**. 실제 사용 가능한 관리 경로라고 단정하지 않음 |
| 다른 control-plane/관리 PC/비상 콘솔 | 이번 수집 범위 밖 | 과거 기록과 최신 실물 메타데이터의 연결 필요 | 사본·principal·접근 Source·조건·감사·회수 전부 **미확인**. 존재/부재를 추정하지 않음 |

10/6 임시 Role은 해당 Grafana Pod 이름의 get와 pods/portforward create만 허용했고, 임시 SA/Role/Binding을 삭제했다. 해당 과거 성공을 현재 상시 역할이나 무기한 접근 승인으로 바꾸지 않는다. #175의 현재 RBAC 목록에서도 그 회차의 임시 binding은 보이지 않는다.

## 2. Lead 인계 입력 — 비밀값 없이 작성

각 실제 경로에 다음 기록을 연결한다. 공개 저장소/이슈에 kubeconfig·개인키·토큰·비밀번호·토큰 해시를 붙이지 않는다. 비공개 보관 자료는 승인된 보관 위치의 식별자와 접근 책임자만 연결한다.

| 항목 | 필요한 자료·완료 기준 | 판단/제공 책임 |
|---|---|---|
| 정상 관리 경로 | 운영자 풀네임, 승인 단말/Source, 실제 API principal, 대상 namespace/Pod, 기존 승인 근거, 허용 목적·시간. #130의 과거1회와 신규 상시 절차 구분 | 이재환이 MON 운영 경로 작성, 이하영이 권한 경계 검토 |
| 관리·비상 credential 보관 | 경로별 호스트/파일 위치 또는 비공개 보관 식별자, owner/mode, 인적 보유자, 유효기간과 발급/회수 주체. 현재 존재만 확인된 control01 두 파일부터 연결 | 이하영이 SEC/클러스터 credential 정책·보유자 확인, 해당 보유자가 실물 메타데이터 제공 |
| 사용조건 | 언제 누가 비상 경로를 사용하고 어떤 사전/사후 기록을 남기는지, 운영 경로와 다른 권한·접근 Source가 있는지 | 이재환·이하영이 각 책임 범위에서 확정. Support가 임의 예외 승인하지 않음 |
| 감사 | 실제 API audit/호스트 로그인·sudo 기록의 시각·principal·Source·행위·대상 연결, 보관 위치와 보존/열람 책임. 수집 불가 시 그 한계 명시 | 관련 원본 보유자 제공, 이권욱은 수신·정합성 대조 지원 |
| 종료·회수 | 임시 PF 프로세스/리스너 종료, 해당 회차 소유 credential/임시 RBAC 정리와 무효화 확인. 장기 관리 인증은 별도 발급·폐기 정책과 연결 | 실행 회차 Lead와 credential 발급/회수 책임자. 관리자 권한 일괄 삭제로 대체하지 않음 |
| 최종 처분 | 요구에 맞게 경로 통제를 보완할지, 명시된 범위·조건의 예외 절차가 필요한지 판단 근거와 결과 기록 | MON Lead/SEC Review Owner 및 기존 프로젝트 처분 절차 |

이 문서에 새 Due나 정책 TTL을 확정하지 않는다. 이미 기록된 사실은 반복 수집하지 않고 남은 소유/운영 정보부터 보완한다.

## 3. 후속 확인의 실행 경계

1. 위 인계 입력과 #175 독립 증적 리뷰를 먼저 연결한다. #130의 성공·회수 결과를 다시 만들기 위한 단순 재시험은 하지 않는다.
2. 추가 조회가 필요하면 호스트·파일/로그 경로·시각 범위·필요 메타데이터만 고정하고 기존 계정으로 읽는다. 무차별 홈 디렉터리/비밀 내용 검색·일괄 kubeconfig 수집은 하지 않는다.
3. 새 PF 또는 음성 접근 시험이 필요하다고 판단한 경우에만 `ops/pf-retest`의 승인 코드·해당 회차 입력·시작 Gate·Runner 비중첩·정리/복구 인수를 다시 고정한다. 이전 토큰과 회차 GO를 재사용하지 않는다.
4. 미확인 주체·외부 노출·소유 불명 임시 리소스를 발견하면 새 변경을 중단하고 Lead에게 증거와 영향을 연결한다. 서비스·관리 접근을 임의 차단하거나 기존 credential을 삭제하지 않는다.
5. 이 문서 자체는 서버 명령/설정을 바꾸지 않아 Runtime 원복이 없다. 후속 실행 중 실패 시 해당 승인 회차의 소유 리소스만 정리하고 기존 관리 접근을 보존한다.

## 근거

- [#17 PMO/QA 리뷰](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-6035136512), [현재 조회 결과](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-6063439125)
- [#130 원본 README](https://github.com/321Team/fds-project-evidence/blob/dfb2521a8de77686c6566e8752899772f61eb8a1/evidence/P1-MON-01/pf-retest-run3-20261006T1310Z/README.md), 같은 폴더 `control01/run-20261006T2200/08-role.yaml`·`08-rolebinding.yaml`
- [#175 정확한 HEAD의 조회 결과](https://github.com/321Team/fds-project-evidence/blob/8bdba54d1ed199e1b78e4ecf64ab9ee53dabe3a3/evidence/P1-APP-01/app-mon-readonly-20261009T002630/README.md)
- [기존 구축/복구 Runbook](RUNBOOK_P1_MON_01_20261002.md), [승인 PF 재시험 도구](../ops/pf-retest/README.md)

CODEX_ASSISTED. STATIC 문서 대조 / 신규 Runtime 시험 NOT_RUN / 정책 예외 NOT_APPROVED / AC·Close UNCHANGED.
