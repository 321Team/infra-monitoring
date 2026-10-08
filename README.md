# infra-monitoring

Phase 1~2 monitoring/observability source, Kubernetes 내부 관측 Stack과 monitor01 외부 Watchdog 구성을 관리한다.

**상태: 병합된 E-K3S 참고 소스와 monitor01 TLS/receiver 구성 후보를 관리한다. monitor01 후보는 설정 생성·검토 단계이며 E-CANON 운영 배포 완료가 아니다.**

| 경로 | 역할 |
|---|---|
| `monitor01/` | TLS proxy·localhost receiver·heartbeat-only 송신 구성 후보와 입력 검증기. 설치·서비스 변경 없음 |
| `references/e-k3s/kubernetes/monitoring/` | 기존 Prometheus/Alertmanager/Grafana/규칙/대시보드 등 |
| `references/e-k3s/kubernetes/d-sec-01/` | 기존 exporter·KSM RBAC 참고본 |
| `references/e-k3s/scripts/demo/` | S7a/S7b/S8 시연 코드. 일부는 scale/apply를 수행하므로 자동 실행 금지 |
| `references/e-k3s/docs/runbooks/` | 당시 시연 절차, 현재 Runtime 승인 아님 |
| `docs/CANONICAL_GAPS.md` | 정본과의 차이 및 후속 인계 |
| `docs/GRAFANA_ACCESS_LEDGER_20261009.md` | Grafana 승인/비상 경로의 과거 증적·현재 조회·미확인 운영 정보 구분 |
| `docs/POLICY.md`, `docs/MIGRATION.md` | 운영 정책, 출처 및 전환 조건 |

P1-MON-01 Lead는 이재환, Support는 이권욱이다. 이하영은 PSA/RBAC/NetworkPolicy/Host Firewall 및 exporter 예외를 검토한다. 코드 소유와 보안 정책 승인 책임을 혼동하지 않는다.

정본(D33/#63)은 monitoring-api의 Prometheus·Alertmanager·Grafana·KSM, monitoring-node의 통제된 node-exporter와 monitor01의 독립 Watchdog이다. Grafana 등 내부 서비스는 ClusterIP와 승인 관리 단말 port-forward로 한정한다. monitor01 Remote Write는 승인된 heartbeat/self/target-health만 허용한다. 전체 업무 metric 복제·보안 예외 확대·미승인 외부 노출을 추가하지 않는다.

공통 VM/계정/Ansible inventory, Squid egress role은 infra-ansible에 유지한다. 클러스터 bootstrap/Calico/Host Firewall·공통 보안 정책은 infra-kubernetes, CA lifecycle은 infra-pki, 실제 증적은 fds-project-evidence에 둔다. 이관된 스크립트를 실제 클러스터에서 실행하지 않았다.

## 정본에 따른 운영 결정

[운영 정책](docs/POLICY.md)과 [정본 대응·책임 경계](docs/CANONICAL_POLICY.md)를 적용한다. Private/main을 유지하고, 이번 소스 이관은 로컬 검증 증적과 독립 검토 후 수동 병합으로 판단한다. Actions 활성화는 이관의 새 필수 AC가 아니며 CI 미실행은 NOT RUN으로 기록한다. 중앙 Delivery는 기존 infra-cicd 전용 Runner 경계를 유지한다.

2026-09-18 승인 절차 개정: **코드/실행 설정을 포함한 PR 병합만 독립 리뷰**를 거친다. 문서·증적만 변경한 PR과 Runtime 실행·인수·종결은 해당 Lead가 판단하며 동일 코드의 실행마다 독립 승인을 반복하지 않는다. 이번 이관 PR은 코드를 포함하므로 독립 리뷰를 유지한다. [공통 변경결정](https://github.com/321Team/fds-project-baseline/blob/38f682141c279807050c5b1ea1b4e2b58ee22d63/governance/REVIEW_AUTHORITY_POLICY.md)과 [운영 정책](docs/POLICY.md)을 따른다.
