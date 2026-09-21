# E-CANON monitoring-api/monitoring-node 배포 후보

상태: **PR 준비 / 독립 REVIEW=PENDING / MERGE=NOT_DONE / RUNTIME=NOT_RUN / NOT_DEPLOYED**.
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
| monitoring-node PSA/privileged 금지 | `namespaces.yaml` 신규. monitoring-api는 `restricted` 적용. **monitoring-node는 의도적으로 라벨 미설정** — host 필드 허용과 privileged 컨테이너 금지를 네이티브 PSA로 동시에 표현할 수 없어 D-SEC-01 #7 보안 검토 필요(namespaces.yaml 주석 참조) |
| Grafana default password | `secretKeyRef`로 전환, Secret 자체는 이 리포에 없음(직접 생성 필요, grafana.yaml 주석의 명령 참조) |
| monitor01 TLS/receiver | 손대지 않음 — `../../monitor01/README.md`의 기존 DRAFT 범위를 그대로 따름 |
| E-K3S 시연 결과 재검증 | NOT RUN — 실 클러스터 kubectl 접근 있는 사람이 수행 |

## 이 PR이 하지 않는 것

- `kubectl apply` 실행, namespace 실제 생성, PVC bound 확인 — 전부 NOT RUN
- Harbor 승인 digest 조회·pin
- monitor01 실행모델·receiver 확정(별도 트랙, monitor01/README.md 참조)
- node-exporter DaemonSet 스케줄 노드 확인(CP taint 여부) — `prometheus.yaml`의 node-exporter
  스크레이프 타깃이 여전히 E-K3S placeholder(`10.1.93.50`)로 비어있는 이유
