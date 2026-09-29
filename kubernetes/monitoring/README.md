# E-CANON monitoring-api/monitoring-node 배포 후보

## 2026-09-29 Resource·PVC 정의 (#17 핵심 요구 3절)

| 구성요소 | PVC (소스 파일) | 현장 PVC | requests (CPU / 메모리) | limits (CPU / 메모리) | 관측 최대 (CPU / working set) |
|---|---|---|---|---|---|
| Prometheus | `prometheus-data` 20Gi (`pv-monitoring-storage.yaml`) | Bound | 200m / 448Mi | 500m / 896Mi | 31.5m / 367.5MiB |
| Alertmanager | `alertmanager-data` 2Gi (`pv-monitoring-storage.yaml`) | Bound | 200m / 256Mi | 500m / 512Mi | 2.6m / 51.4MiB |
| Grafana | `grafana-data` 5Gi (`grafana-dashboards.yaml`) | Bound | 200m / 1152Mi (이전 256Mi) | 1 / 2304Mi (이전 1Gi) | 37.1m / 916.3MiB |

- 관측: 2026-09-26 23:47 ~ 09-29 18:25 KST(약 66.6시간), `job="kubelet-cadvisor"`. control01 수집 archive `p1-mon-res-20260929T182518.tgz` SHA-256 `6f0c4c0d50879cf2fbdb9e9b67a083e910bca38d78d4e8d78f9eb74418f32d0d`(서버 원본 보존, 증적 편입 예정).
- 산식: #15 결정안 v2 §6(프로젝트 내부 기준) — CPU request = p95 × 1.5(50m 올림, 최소 100m), CPU limit = 최대 × 2(100m 올림), 메모리 request = 최대 × 1.2(64Mi 올림), 메모리 limit = request × 2. 현재 적용 중인 값보다 낮추지 않는다.
- PVC 사용률: 세 PVC는 worker03 `/home` 한 파일시스템 위의 local PV라 `kubelet_volume_stats_*`가 파일시스템 전체(9/29 사용 4.3GiB / 166GiB)를 보여 준다. PVC별 사용량은 worker03 `du` 또는 `prometheus_tsdb_storage_blocks_bytes`(9/29 762MiB)로 본다.
- 현장 반영: 병합은 적용이 아니다. 세 Deployment 모두 `:latest`·imagePullPolicy Always라 재시작하면 이미지를 다시 받는다. [G3 원칙](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5885874627)대로 승인 digest 고정과 같은 재시작 창에서 반영하고, 그 전에 반영하려면 "현장 imageID = Harbor `latest` digest" 확인 조건으로 G3 확인을 먼저 받는다.

## 2026-09-23 저장소 정합성 보완

[E-CANON PR #4](https://github.com/321Team/infra-monitoring/pull/4)는 9/21 병합됐고, [MON Lead의 9/22 실행 보고](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5772337466)에서 monitoring-api/monitoring-node 실제 배포와 앱 namespace를 `fds-app`으로 현장 수정한 사실을 확인했다. 아래의 PR 미병합/NOT_DEPLOYED 표현은 최초 작성 당시 이력이다.

이번 변경은 main에 남은 앱 namespace drift만 정정한다. headless Service 2개와 앱 ingress NetworkPolicy의 namespace, Prometheus 앱 egress namespaceSelector, 앱 metrics DNS 2개를 `fds-app`으로 일치시킨다. 포트 9091/9090, podSelector, default deny, kubelet/node-exporter 규칙 및 Secret 참조는 유지한다. E-K3S 참고본은 당시 환경이므로 변경하지 않는다.

- 이번 작업: 소스 수정·로컬 YAML/참조 정합성 검사. 서버 apply/reload/rollout과 신규 Runtime 검증은 수행하지 않았다.
- 현장 완료 보고 재사용: MON 스택 Running, 앱·KSM Target UP. 이를 저장소 재배포 시험으로 표시하지 않는다.
- 잔여: 현재 적용본과 후보 diff 확인, 승인 artifact/digest 및 imagePullSecrets 형상화, node-exporter 이미지 고정의 담당자 작업 편입, 9100/10250 교차 노드 접근·kubelet CA/SAN, monitor01 IF-06B. 담당자가 준비 중인 이미지 수정과 겹치지 않도록 이번 PR에서는 namespace만 수정한다.
- 적용: 정확한 병합 SHA에서 현재 리소스/ConfigMap과 diff를 대조하고 MON Lead의 기존 배포 절차로 필요한 변경만 반영한다. 기존 현장 수정과 이미 같으면 무변경으로 종료한다. 전체 디렉터리를 재적용하거나 Pod를 재기동할 필요는 없다.
- 중단·복구: 예상 밖 diff 또는 연결 회귀 시 적용을 중단한다. 소스만 반영했다면 revert로 충분하며, 현장 변경을 했다면 직전 정상 `fds-app` 구성으로 복구한다. 잘못된 `fds` 참조를 운영에 복원하지 않는다.

---

상태: **PR 준비 / 독립 REVIEW=CHANGES_REQUESTED(1차, GWONUK) → 차단 4건 수정 완료, 재검토 대기 / MERGE=NOT_DONE / RUNTIME=NOT_RUN / NOT_DEPLOYED**.

1차 리뷰(GWONUK, [PR #4](https://github.com/321Team/infra-monitoring/pull/4))에서 지적된
차단 B1~B4와 비차단 권고 1~4·7을 반영했다: ServiceAccount/RBAC 누락(B1) 추가, DNS egress(B2)
허용 추가, node-exporter 타깃을 Worker 3대 실측 IP로 교체하고 k3s-hairpin 오표기 제거(B3),
monitoring-node PSA를 D33 결정대로 `enforce=privileged`+컨테이너 `privileged:false` 방어(B4).
정정: 최초 PR 본문의 "CI NOT RUN"은 틀렸다 — `tools/check_source.py`가 이미 SUCCESS로 실행됨
(GWONUK 리뷰 지적).
책임 티켓: [P1-MON-01 #17](https://github.com/321Team/fds-project-baseline/issues/17),
[D33 #63](https://github.com/321Team/fds-project-baseline/issues/63). Lead 이재환, Support
이권욱, 보안·K8S 검토 이하영.

`../../references/e-k3s/kubernetes/monitoring/`(E-K3S 임시 실증본, 원본 그대로 보존)를
출발점으로 [CANONICAL_GAPS.md](../../docs/CANONICAL_GAPS.md)를 해소하는 방향으로 수정한
E-CANON 후보다. `CANONICAL_POLICY.md`가 "정본과 참고본 차이를 해소한 E-CANON 구현 PR 없이는
references를 정본 배포 입력으로 사용하지 않는다"고 규정한 그 PR이 이 디렉터리다.

## Source

`supreme33-kr/fds-msa` `feature/dedicated-metrics-listener` 커밋
`8ca6707a1b608d127e62b3bd7eabb67e830245db` 위에 신규 커밋
`4d4c53e7075f4308cd81da07b35793a949584186`(namespace 이전·PVC·NetworkPolicy·포트 정정)을
얹은 뒤 이 저장소로 복사. 원본 리포는 archived(`fds-msa-legacy`)라 이 복사가 유일한 현재
소스다. Git 이력 자체는 옮기지 않았다(이 저장소의 다른 이관과 동일한 방식).

## CANONICAL_GAPS.md 대조

| 항목 | 이번 PR 처리 |
|---|---|
| fds namespace·업무 포트 | `monitoring-api`/`monitoring-node`로 이전, 앱 metrics 9091/9090(dns_sd_configs)로 전환 |
| latest 이미지·emptyDir | PVC/SC/PV(worker03 static local PV, Storage 인계 결정 #17)로 전환. **Harbor 승인 digest는 미해결** — `image:` 필드는 여전히 `:latest` |
| kubelet insecure_skip_verify | `ca_file`(ServiceAccount 기본 CA)로 전환. **TLS 긍정/부정 시험 NOT RUN** — 이 클러스터의 실제 kubelet 인증서 체인 미검증 |
| monitoring-node PSA/privileged 금지 | `namespaces.yaml`: monitoring-api는 `restricted`, monitoring-node는 D33 결정대로 `enforce=privileged`+`audit/warn=restricted`. node-exporter 컨테이너는 `privileged:false`+`seccompProfile` 명시로 실제 권한 행사는 방어(GWONUK 리뷰 B4 반영, 최초 커밋의 "라벨 생략" 판단은 정정됨) |
| Grafana default password | `secretKeyRef`로 전환, Secret 자체는 이 리포에 없음(직접 생성 필요, grafana.yaml 주석의 명령 참조) |
| monitor01 TLS/receiver | 손대지 않음 — `../../monitor01/README.md`의 기존 DRAFT 범위를 그대로 따름 |
| E-K3S 시연 결과 재검증 | NOT RUN — 실 클러스터 kubectl 접근 있는 사람이 수행 |

## 적용 순서 (GWONUK 리뷰 비차단#7 대응)

이 디렉터리는 자기 완결적이지 않다 — 적용 전 순서·전제:

1. `fds-app` namespace와 그 안의 `transaction-api`/`fds-engine` 앱 pod가 이미 떠 있어야 한다.
   `headless-services.yaml`(파드 IP 노출)과 `networkpolicy.yaml`의 `allow-monitoring-scrape`
   (fds-app ns에 위치, monitoring-api로부터의 ingress 허용)는 앱이 존재한다는 전제다.
2. 이 디렉터리 안에서는 `namespaces.yaml` → `rbac-kube-state-metrics.yaml`/`prometheus-rbac.yaml`
   → `pv-monitoring-storage.yaml`(PV/PVC) → 나머지(Deployment/DaemonSet/NetworkPolicy) 순서를
   권장한다. `kubectl apply -f kubernetes/monitoring/`로 한 번에 적용해도 K8s가 참조를 재시도해
   대체로 수렴하지만, 첫 apply에서 일부 리소스가 참조 미해결로 실패할 수 있다 — 재실행 권장.
3. Grafana admin Secret(`grafana-admin-credentials`)은 이 디렉터리에 없다 — 먼저 직접 생성.

## 이 PR이 하지 않는 것

- `kubectl apply` 실행, namespace 실제 생성, PVC bound 확인 — 전부 NOT RUN
- Harbor 승인 digest 조회·pin
- monitor01 실행모델·receiver 확정(별도 트랙, monitor01/README.md 참조)
- node-exporter DaemonSet이 실제로 Worker 3대(.105/.107/.108) 전부에 스케줄되는지 확인 —
  `prometheus.yaml`의 타깃은 이 3대로 채워졌지만(GWONUK 리뷰 B3), CP taint toleration이 없다는
  가정에 근거한 것이라 NOT VERIFIED
