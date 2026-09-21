# E-CANON monitoring-api/monitoring-node 배포 후보

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

1. `fds` namespace와 그 안의 `transaction-api`/`fds-engine` 앱 pod가 이미 떠 있어야 한다.
   `headless-services.yaml`(파드 IP 노출)과 `networkpolicy.yaml`의 `allow-monitoring-scrape`
   (fds ns에 위치, monitoring-api로부터의 ingress 허용)는 앱이 존재한다는 전제다.
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
