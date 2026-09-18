# E-CANON 인계 전 보완 조건

근거: baseline #17/#63의 2026-09-14 점검과 #75의 최신 HOLD 기록. 새 AC가 아니라 기존 인수조건의 source 인계 구분이다.

| 원본 참고본 상태 | 정본 적용 전에 필요한 조치 | 책임/근거 |
|---|---|---|
| fds namespace·업무 포트 수집 | monitoring-api/monitoring-node, 앱 metrics 9091/9090 및 endpoint별 수집 | P1-MON-01 #17 / 앱 #15 |
| latest 이미지·일부 emptyDir | 승인 Harbor digest와 Prometheus/Grafana/Alertmanager PVC, 실제 SC/PV/노드/권한 입력 | #17 / Storage 담당 |
| kubelet insecure_skip_verify | 승인 trust/SAN 경로와 TLS 긍정·부정 시험; 우회 금지 | #17 / #19 |
| monitoring-node baseline PSA 원본 | D33 통제 예외·privileged container 금지, read-only host 접근·9100 제한 | #63 / #19 |
| Grafana default password 원본 | Secret 참조와 승인 자격증명 주입, anonymous/signup 금지 | #17 / #19 |
| monitor01 구축 소스 없음 | 독립 Watchdog, TLS proxy/제한 receiver, heartbeat=1 및 5분 단절 검증 | #17 / #63 / #64 |
| E-K3S 시연 결과 | 정본의 Target/Alert/PVC/보안/장애·복구 Runtime 재검증 | #17 |
| 외부 알림 새 경로 미편입 | #74 서비스 인수·source 실측 및 #75 정책 승인 후 적용 | #74/#75 / k8s PR #12 |

HA/장기보존은 P1-MON-02 #25의 범위이며 초기 P0 이관 차단으로 확대하지 않는다. Phase 2 확장은 승인된 플랫폼/인터페이스로 추후 연결한다. 임시 파일을 이름만 바꿔 정본 배포본으로 승격하지 않는다.
