# MON 소스·현장 정합 적용 절차 — 2026-09-24

상태: **절차 초안 / Runtime NOT RUN**. 실행 여부와 시점은 각 Lead가 결정한다. 이 문서는 적용 지시나 승인 기록이 아니다. 책임: [#17](https://github.com/321Team/fds-project-baseline/issues/17) MON Lead 이재환, [#75](https://github.com/321Team/fds-project-baseline/issues/75) Lead 이하영.

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

## B. 현장 형상의 소스 반영분 적용 (이 PR)

이 PR은 현장에 이미 적용된 상태를 소스로 옮긴다. 따라서 **이상적인 적용 결과는 "변경 없음"**이다. 차이가 생기면 소스와 현장 중 어느 쪽이 맞는지 먼저 판정한다.

1. 대상은 `alertmanager-deploy.yaml`, `alertmanager-config.yaml`, `grafana.yaml`, `prometheus.yaml`, `kube-state-metrics.yaml`, `node-exporter.yaml`이다. 각각 `kubectl diff -f <파일>`로 비교한다.
2. 예상되는 차이와 판정:

   | 객체 | 예상 차이 | 조치 |
   |---|---|---|
   | Deployment 4개 / DaemonSet 1개 | image·imagePullSecrets 차이 없음 | 차이가 있으면 중단하고 현장 값을 확인 |
   | alertmanager Deployment | Secret volume 이름이 현장과 다를 수 있음. 이 PR은 `discord-webhook`을 쓰며, 현장 volume 이름은 수집하지 않았음 | 이름만 다르면 소스를 현장 이름에 맞춰 수정할지, 적용 시 롤링을 감수할지 Lead가 결정 |
   | alertmanager-config CM | 현장 hash와 같은지 확인하지 않음. #75 보고의 형상으로 작성함 | diff 원문을 대조한다. 현장에만 있는 내용은 덮어쓰지 말고 소스에 반영 |
   | grafana Secret·PVC·다른 CM | 이 PR 범위 밖 | 적용하지 않음 |

3. diff가 없거나, Lead가 수용한 차이만 남았을 때 파일 단위로 적용한다. Deployment spec이 바뀌면 Pod가 재시작된다. Alertmanager와 Prometheus는 `Recreate` 전략이라 잠시 공백이 생기므로 알림 공백 시간을 기록한다.
4. **실패 시 복구**: 적용 전에 `kubectl get <kind> <name> -o yaml`로 백업하고, 백업본을 재적용한다. Git revert만으로는 현장 복구가 되지 않는다.

## 이 문서가 다루지 않는 것

- 4개 workload의 승인 digest 확정. HBR/CICD Trivy Gate를 거친 digest가 확정되면 별도 PR로 tag를 digest로 바꾼다.
- Grafana dashboard CM([PR10](https://github.com/321Team/infra-monitoring/pull/10))과 fds-overview 잔여 차이
- `allow-prometheus-egress-scrape` 현장 `fds` 잔존, 무관리 NP 8개의 관리 주체 정리
- monitor01 콘솔 수집(`ops/mon-followup/MONITOR01_CONSOLE.md`), IF-06B remote_write
