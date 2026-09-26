# MON 소스·현장 정합 적용 절차 — 2026-09-24

상태: **§A는 2026-09-25 10:17–10:19 KST #75 Lead가 적용 완료**([실행 기록](https://github.com/321Team/fds-project-baseline/issues/75#issuecomment-5826812494)). **§B는 절차 초안 / Runtime NOT RUN**. 실행 여부와 시점은 각 Lead가 결정한다. 이 문서는 적용 지시나 승인 기록이 아니다. 책임: [#17](https://github.com/321Team/fds-project-baseline/issues/17) MON Lead 이재환, [#75](https://github.com/321Team/fds-project-baseline/issues/75) Lead 이하영.

공통 전제:
- 실행 위치는 기존 승인 kubectl 경로(control01)다. 새 계정·권한·Secret을 만들지 않는다.
- 적용 SHA를 고정한다. 코드 변경이므로 POLICY.md §3.1에 따라 **독립 리뷰가 완료된 SHA와 적용 SHA가 같은지** 실행 기록에 남긴다.
- 전체 디렉터리를 `kubectl apply -f kubernetes/monitoring/`로 일괄 적용하지 않는다. 아래 객체 단위로만 적용한다.
- Secret 값, webhook URL, `kubectl get secret -o yaml` 출력은 기록·채팅·Git에 남기지 않는다.

## A. `alertmanager-egress` DNS 규칙 제거 (#75, PR5 병합분)

main `1b1ef1b`의 `kubernetes/monitoring/alertmanager-egress.yaml`은 현장 객체에서 `namespaceSelector: {}` DNS 규칙만 뺀 형태다.

1. **사전 확인**
   - `kubectl -n monitoring-api get networkpolicy monitoring-api-dns-allow -o yaml` — `podSelector: {}`이고 DNS peer가 kube-system의 `k8s-app: kube-dns`, UDP/TCP 53으로 한정돼 있어야 한다. 아니면 **중단**한다. 이 정책이 DNS 허용을 대신한다.
   - 현장 원본을 백업한다: `kubectl -n monitoring-api get networkpolicy alertmanager-egress -o yaml > <작업폴더>/alertmanager-egress.before.yaml`
   - `kubectl diff -f kubernetes/monitoring/alertmanager-egress.yaml` — DNS egress 항목 1개만 제거돼야 한다. 다른 차이가 있으면 **중단**한다.
2. **적용**: `kubectl apply -f kubernetes/monitoring/alertmanager-egress.yaml`
3. **정상 판정** (모두 충족)
   - Alertmanager Pod에서 이름 해석이 된다. 이미지에 nslookup이 없으면, 아래 합성 알림이 도착하는 것으로 간접 확인한다.
   - 기존 합성 rule 절차(#75 9/22)로 Discord 도착과 Resolved를 확인하고, rule을 원복한다.
   - Alertmanager 로그에 `dial tcp` / `no such host` 오류가 새로 생기지 않는다.
4. **실패 시 복구**: `kubectl apply -f <작업폴더>/alertmanager-egress.before.yaml`. PR5 코멘트에 보존된 원본 YAML도 쓸 수 있다. 복구한 뒤 같은 합성 알림으로 다시 확인한다.
5. **기록**: 적용 SHA와 리뷰 SHA, KST 시각, diff 요약, Discord 도착 시각을 #75에 남긴다. webhook URL은 남기지 않는다.

## B. Alertmanager Discord 구성 적용 (이 PR)

이미지·`imagePullSecrets`·Probe는 [PR12](https://github.com/321Team/infra-monitoring/pull/12)(2026-09-26 병합)로 main에 반영됐다. 이 절은 이 PR에 남은 `alertmanager-deploy.yaml`의 Discord Secret mount와 `alertmanager-config.yaml`의 `discord-notifications` receiver만 다룬다.

1. **`alertmanager-config.yaml`은 route 분기 PR 반영 전에는 적용하지 않는다.** 현장 route는 이 파일과 다르다(2026-09-25 10:27 `NodeExporterDown`이 Discord로 도착). 또한 MON Lead가 발송 범위를 `severity: critical`만으로 결정했다([#75](https://github.com/321Team/fds-project-baseline/issues/75#issuecomment-5842829934)). 발송 범위는 #75 Lead의 route 분기 PR에서 확정·적용한다.
2. `alertmanager-deploy.yaml`은 `kubectl diff -f`로 비교한다. 기대 결과는 "변경 없음"이다. 차이가 나오면 **적용을 중단**하고 종류별로 Lead가 판단한다.
   - Secret volume 이름이 현장과 다른 경우: 이름을 현장에 맞출지, 롤링을 감수할지 결정한다. 현장 volume 이름은 아직 수집하지 않았다.
   - Probe 차이인 경우: PR12의 Probe는 현장에 `kubectl patch`로 먼저 들어갔고, startupProbe `timeoutSeconds: 3`은 그 뒤(`ee4f93f`)에 소스에만 추가됐다. 이 차이는 예상된 것이다. 적용하면 Pod가 재시작되므로 공백을 감수할지 판단한다.
   - 그 밖의 차이: 원인을 확인하기 전에는 적용하지 않는다.
3. Deployment spec이 바뀌면 Pod가 재시작된다. Alertmanager는 `Recreate` 전략이라 공백이 생기므로 알림 공백 시간을 기록한다.
4. **실패 시 복구:** 적용 전에 `kubectl get deploy alertmanager -n monitoring-api -o yaml`로 백업하고, 백업본을 재적용한다. Git revert만으로는 현장이 복구되지 않는다.

## 이 문서가 다루지 않는 것

- 4개 workload의 승인 digest 확정. HBR/CICD Trivy Gate를 거친 digest가 확정되면 별도 PR로 tag를 digest로 바꾼다.
- Grafana dashboard CM([PR10](https://github.com/321Team/infra-monitoring/pull/10))과 fds-overview 잔여 차이
- `allow-prometheus-egress-scrape` 현장 `fds` 잔존, 무관리 NP 8개의 관리 주체 정리
- monitor01 receiver 설계와 IF-06B remote_write. 콘솔 수집은 2026-09-25에 완료됐다([#17 기록](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5832054238))
