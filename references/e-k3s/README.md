# 병합된 임시 관측 소스 — 실행 금지 참고 snapshot

원본 directory 관계를 보존한 E-K3S 참고본이다. 정본(E-CANON) 배포본이 아니며 `kubectl apply -R` 대상이 아니다. 시연 스크립트는 자원을 scale/patch/apply하고 앱 거래를 생성할 수 있다. 정적 검토만 수행한다.

prometheus의 insecure_skip_verify, 외부 Prometheus라는 옛 설명, fds namespace·업무포트 scrape·latest·emptyDir, monitoring-node PSA 불일치는 현재 정책으로 채택하지 않는다. grafana 기본 암호는 명시적인 비실행 placeholder로 가렸다. 이 변경 외 원본 bytes는 manifest로 대조한다.
