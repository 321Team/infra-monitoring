# MON 후속 수집 수신·배포 차이 판정 — 2026-09-24 05:59 KST

이 문서는 실행 결과의 분석 기록이며 배포 입력이 아니다. 책임 [#17](https://github.com/321Team/fds-project-baseline/issues/17), 경로 지원 [#14](https://github.com/321Team/fds-project-baseline/issues/14), 알림 [#75](https://github.com/321Team/fds-project-baseline/issues/75). 기존 Lead/Support·AC·일정을 유지한다.

## 수신 검증

| 항목 | 확인 |
|---|---|
| 사용자 archive | MON_FOLLOWUP.yZ8m3YyG.tar.gz / 21,078 bytes |
| archive SHA256 | 2664cf594db597ec42bfd8318f8a8b74942584c23fcab67f230439c37b5dc2a4 |
| 외부 sidecar / 내부 SHA256SUMS | 일치 / 10개 전부 일치, 중복·누락·경로 이탈 없음 |
| 실행 source SHA | 9746f521612669572adeb8749f6afaaf0a256cbe |
| 실제 포함된 source | 5개 바이트 및 고정 Git tree blob SHA 일치 |
| 관측 시간 | 2026-09-24 05:59:38.295069–05:59:38.698476 +09:00 |
| 대상·계정 근거 | k8s-control01, uid1001, 기존 Ansible svc_ansible 경로 |
| 조회 | 11/11 성공, 48객체 |
| Ansible / collector | failed0 / unreachable0 / COLLECTION_RC0 |
| changed1 | localhost에 결과를 저장한 copy task. 대상 서버 변경 증거 아님 |
| 비교 재현 | 검토한 source로 comparison.json 동일 결과 재현 |
| Runtime 변경 | NOT RUN |

원본 archive는 사용자 첨부를 수신한 자료다. 이 문서 추가는 fds-project-evidence 원본 편입·독립 검토 완료를 뜻하지 않는다. 원본을 수정하지 않았다.

## 이번 관측에서 확인된 상태

- monitoring-api Pod4개와 monitoring-node node-exporter Pod3개 모두 Running, 각 container ready=true: **7/7**.
- Deployment4개 ready/available1, node-exporter DaemonSet desired3/ready3.
- PVC3개 모두 Bound, fds-local-storage/RWO. Prometheus20Gi, Grafana5Gi, Alertmanager2Gi. 선언·binding 확인이며 데이터 복구/보존 재시험이 아니다.
- Service5개 모두 ClusterIP, nodePorts 없음. 실제 비승인 외부 접근 실패나 Grafana port-forward 성공을 뜻하지 않는다.
- node-exporter3개는 동일 digest. Prometheus Pod UID는 기존 05:00 관측과 동일하다.
- 새 Target API·TLS·scrape 결과는 수집하지 않았다. Pod Ready를 UP/CA+SA/AC PASS로 확대하지 않는다.

### 이미지 관측값

| workload | 현재 spec image | 현재 Pod imageID의 sha256 |
|---|---|---|
| alertmanager | 10.1.93.54/fds/alertmanager:latest | babefaac616bdb9fb5037a2b70a3c0ffa988c68e96443621dd7360e60781ab67 |
| grafana | 10.1.93.54/fds/grafana:latest | 7a1ff54408c90357ff1c76189e5bbc24f898531cb771fbbfe6a477f00de37d5b |
| kube-state-metrics | 10.1.93.54/fds/kube-state-metrics:v2.13.0 | 8ca59a9893ecaebbea478099d99a9ffc9daa9f285a715adfa945246b111322a1 |
| prometheus | 10.1.93.54/fds/prometheus:latest | b77f9cee82fd1c61521634d2d6b192fc526ffd938e904b8e6836b6c0cf8d875a |
| node-exporter | 10.1.93.54/fds/node-exporter@sha256:56566542aacd5be06add01d3456cd6279e2f7ddb4b24237fc8cdfbc3cc5f699f | 56566542aacd5be06add01d3456cd6279e2f7ddb4b24237fc8cdfbc3cc5f699f |

선택한 workload5개 모두 imagePullSecrets에 harbor-pull-secret을 참조한다. Secret 값은 읽지 않았다. 네 workload의 spec은 tag 참조이며, 현재 imageID 관측을 승인 artifact/취약점 검사 또는 다음 pull의 동일성 보증으로 표시하지 않는다. MON/HBR의 기존 승인 digest와 대조한 뒤 형상화한다.

## main과 차이

기준 main `a885cef2358682214095590baf69b77062978778`, manifest20파일/선택32객체 중 **24 MATCH_SELECTED_FIELDS / 8 DIFF / 누락0**. 이는 선택 필드만의 비교이며 전체 객체 동일성 판정이 아니다.

| 차이 객체 | 실제 차이·판정 |
|---|---|
| Deployment4 + node-exporter DS1 | Harbor image 및 harbor-pull-secret. Alertmanager는 Discord Secret mount/volume 추가. 새로 설정하는 대신 기존 승인 형상에 연결 |
| alertmanager-config CM | alertmanager.yml hash 다름. 실제 Discord 전송 보고와 함께 추적하되 hash만으로 loaded receiver/config를 확정하지 않음 |
| grafana-dashboards CM | fds-overview.json과 kubernetes-workload.json 두 key hash 다름. application-fds.json/node-monitoring-health.json 일치 |
| allow-prometheus-egress-scrape NP | main의 fds-app과 달리 현장은 namespace label 값 fds. PR7의 이 객체 수정은 현장에 아직 반영되지 않은 상태 |

현장에는 별도 `prometheus-allow`가 fds-app의 transaction-api:9091/fds-engine:9090을 허용한다. [Kubernetes NetworkPolicy는 허용 규칙의 합집합](https://kubernetes.io/docs/concepts/services-networking/network-policies/#the-two-sorts-of-pod-isolation)으로 적용되므로, stale NP 한 개만으로 앱 scrape 실패를 단정하지 않는다. Pod 실제 labels·수신 정책·Calico HEP/GNP·통신은 이번 수집 범위 밖이다. 대조된 NP만 제거하거나 전체 networkpolicy.yaml을 재적용하지 않는다.

### Grafana 후속 후보

저장소의 두 Dashboard JSON에는 fds namespace 선택자가 총8곳 남아 있다. [수정 Draft PR10](https://github.com/321Team/infra-monitoring/pull/10), HEAD `ba7834d73fcf44e2ad2480d4ab0fb0d743f2e8fc`를 별도 준비했다. 운영 CM 변경이라 Pre-check PR9에 섞지 않았다.

- 정확 일치 선택자7개와 regex 선택자1개만 fds-app으로 수정. YAML3문서/JSON4개 파싱, JSON 의미 대조에서 다른 변경0.
- 수정한 kubernetes-workload.json hash는 `3d0ef2d1a85fb5217fc0724d0211ab5912be0d5c3133ec2e185e36bba8667a9a`로 현장 key hash와 일치한다. 현재 CM 바이트 정합성 근거이며 Grafana가 로드/쿼리한 증거가 아니다.
- fds-overview.json은 이 수정만으로 현장 hash와 일치하지 않는다. 추가 내용은 미확인이므로 CM 전체 덮어쓰기를 지시하지 않는다. MON Lead의 나머지 현장 변경 대조/형상화를 먼저 연결한다.
- PR10은 독립 리뷰·Lead 병합 판단·실제 적용 미완료. 기존 query/UID/패널 구조·이미지/Secret/PVC 변경 없음.

## #75 확인된 입력과 남은 조치

- Deployment와 현재 Alertmanager Pod 모두 `discord-webhook` Secret을 `/etc/alertmanager/secrets/discord`에 readOnly=true로 마운트한다. subPath/subPathExpr 없음, env Secret 참조 없음.
- 따라서 [일반 Secret volume의 비동기 갱신](https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-files-from-a-pod) 대상 형태다. v0.34.1 Notify의 알림별 파일 읽기 근거와 연결하되 실제 바이너리 버전·loaded file 경로·Secret immutable/회전 전파·새 endpoint 알림 도착은 미확인이다. 지금 회전/재시작/Secret 조회를 하지 않았다.
- 현장 `alertmanager-egress`는 proxy `10.1.93.56/32:3128 TCP`를 허용한다. **DNS rule의 namespaceSelector는 {}**, podSelector는 k8s-app=kube-dns, TCP/UDP53이다. 이 peer는 kube-system으로 제한되지 않는다. 실제 타 namespace 연결 허용/악용 시험은 하지 않았다. #75 Lead가 승인 DNS 범위와 대조해 기존 정책을 제한하는 변경을 준비해야 한다.
- [PR5](https://github.com/321Team/infra-monitoring/pull/5)의 새 이름 `allow-alertmanager-egress-proxy`를 추가하는 것만으로 기존 `alertmanager-egress`의 넓은 DNS peer가 사라지지는 않는다. 현장 객체와 PR5의 소스·이관/회수 범위를 함께 정리한다. default-deny/DNS 정책을 일괄 삭제하지 않는다.
- 그 외 대조 기준 밖 NP는 총8개다: monitoring-api의 alertmanager-allow, alertmanager-egress, grafana-allow, kube-state-metrics-allow, monitoring-api-dns-allow, prometheus-allow, prometheus-remote-write-allow 및 monitoring-node/node-exporter-allow. 다른 저장소의 관리 대상일 수 있으므로 모두 무관리/불필요 정책으로 판정하지 않는다.
- 추가 ConfigMap kube-root-ca.crt는 일반 자동 주입 객체이며 source 누락 결함으로 표시하지 않는다.

## monitor01 / IF-06B

현재 `prometheus-remote-write-allow`는 monitor01 `10.250.10.30/32:443 TCP` egress를 선언한다. 그러나 수집된 prometheus-config의 prometheus.yml hash는 main과 일치하고, 그 내용의 top-level keys는 global/rule_files/alerting/scrape_configs이며 **remote_write 없음**을 확인했다. 네트워크 허용 준비와 송신 구성 완료를 구분한다. 실제 process load/Remote Write 통신 성공은 이번 수집으로 주장하지 않는다.

이번 archive에는 monitor01 호스트 결과가 없다. 기존 콘솔의 서비스/포트/용량 및 receiver 실행 모델·설정/data 경로·승인 artifact·Root/auth 참조가 다음 입력이다. 현재 receiver·443 존재를 추정하거나 새 계정을 만들지 않는다. 해당 입력과 실제 sender 준비 후 IF-06B Source/return path 관측을 연결한다.

## 이번 단계 종료와 후속

- PR9의 **control01 FIELD COLLECTION 완료**. 같은 K8s 묶음 재실행 불필요. monitor01 FIELD COLLECTION은 NOT RUN.
- MON Lead 이재환: image/digest 승인 연결, dashboard 나머지 차이, CM/참조 형상화와 monitor01 서비스 입력.
- SEC/K8S Lead 이하영: #75 DNS peer/PR5 현장 이름 정합성, 기존 PR31 serving TLS 리뷰/후속.
- ICR 이권욱: monitor01/IF-06B 경로 지원. 다른 채팅의 PR27·Grafana 정책 관측·증적 PR23을 중복 수행하지 않는다.
- 새 scrape UP/DOWN·Runtime AC·서비스 인수·독립 증적 편입 판정 없음. AI 사용: CODEX_ASSISTED.
