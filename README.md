# infra-monitoring

Phase 1~2 monitoring/observability source, Kubernetes 내부 관측 Stack과 monitor01 외부 Watchdog 구성을 관리한다.

**상태: 이미 병합된 E-K3S 참고 소스의 이관 PR. E-CANON 배포 가능한 구성은 아직 편입하지 않았다.**

| 경로 | 역할 |
|---|---|
| `references/e-k3s/kubernetes/monitoring/` | 기존 Prometheus/Alertmanager/Grafana/규칙/대시보드 등 |
| `references/e-k3s/kubernetes/d-sec-01/` | 기존 exporter·KSM RBAC 참고본 |
| `references/e-k3s/scripts/demo/` | S7a/S7b/S8 시연 코드. 일부는 scale/apply를 수행하므로 자동 실행 금지 |
| `references/e-k3s/docs/runbooks/` | 당시 시연 절차, 현재 Runtime 승인 아님 |
| `docs/CANONICAL_GAPS.md` | 정본과의 차이 및 후속 인계 |
| `docs/POLICY.md`, `docs/MIGRATION.md` | 운영 정책, 출처 및 전환 조건 |

P1-MON-01 Lead는 이재환, Support는 이권욱이다. 이하영은 PSA/RBAC/NetworkPolicy/Host Firewall 및 exporter 예외를 검토한다. 코드 소유와 보안 정책 승인 책임을 혼동하지 않는다.

정본(D33/#63)은 monitoring-api의 Prometheus·Alertmanager·Grafana·KSM, monitoring-node의 통제된 node-exporter와 monitor01의 독립 Watchdog이다. Grafana 등 내부 서비스는 ClusterIP와 승인 관리 단말 port-forward로 한정한다. monitor01 Remote Write는 승인된 heartbeat/self/target-health만 허용한다. 전체 업무 metric 복제·보안 예외 확대·미승인 외부 노출을 추가하지 않는다.

공통 VM/계정/Ansible inventory, Squid egress role은 infra-ansible에 유지한다. 클러스터 bootstrap/Calico/Host Firewall·공통 보안 정책은 infra-kubernetes, CA lifecycle은 infra-pki, 실제 증적은 fds-project-evidence에 둔다. 이관된 스크립트를 실제 클러스터에서 실행하지 않았다.
