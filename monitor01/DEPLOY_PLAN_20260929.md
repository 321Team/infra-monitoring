# monitor01 통합 실행 계획 — 2026-09-29(화) ~ 10-01(목)

상태: **PLAN / NOT RUN**. 책임: [P1-MON-01 #17](https://github.com/321Team/fds-project-baseline/issues/17) MON Lead 이재환(G8, 기한 10-02). 출발지·반환 경로는 ICR 이권욱([#14](https://github.com/321Team/fds-project-baseline/issues/14)), 보안 인수는 SEC 이하영([#19](https://github.com/321Team/fds-project-baseline/issues/19)).

## MON Lead 입력 결정 (`inputs.fds.json`)

| 항목 | 값 | 이유 |
|---|---|---|
| 실행 방식 | monitor01의 podman 6.1.0, `--network host` 컨테이너 3개(receiver·blackbox·nginx) | 인터넷·Harbor 경로가 없어 패키지 설치가 어렵다. 이미지는 digest로 고정한다 |
| receiver | `127.0.0.1:19090`, 설정 `/etc/fds/monitor01/receiver`, 데이터 `/var/lib/fds/monitor01/receiver` | 9090은 cockpit이 쓰고, 9115는 Blackbox용으로 예약했다 |
| Blackbox | `127.0.0.1:9115`, 설정 `/etc/fds/monitor01/blackbox` | localhost 전용 |
| TLS | leaf는 `/etc/fds/monitor01/tls/monitor01.crt`로 복사(공개 인증서). key는 기존 위치 `/etc/fds/pki/monitor01/request/monitor01.key`를 옮기지 않는다 | 키 반출·복사 금지 |
| Basic Auth | 사용자 `fds-heartbeat`. monitor01 `htpasswd`와 클러스터 Secret은 서버에서 생성하고, 값은 기록하지 않는다 | |
| `source_ipv4` | **`10.1.93.108`** | 2026-09-28 IF-06B 동기 tcpdump에서 worker03 source 보존 및 monitor01 ingress까지 실측. 추정값이 아니라 Runtime 관측값 |

## 이미지 Gate (2026-09-30 갱신 / Runtime NOT RUN)
- Harbor Runtime은 프로젝트 종료까지 **v2.13.1로 고정**한다. 2026-09-30 `--with-trivy` 재구성 후 Trivy adapter(v0.62.1) healthy/default scanner와 실제 artifact scan 성공을 확인했다. v2.15.2 업그레이드는 이번 P1-MON-01 이미지 공급 흐름에서 수행하지 않는다.
- receiver 기존 후보 `10.1.93.54/fds/prometheus@sha256:b77f9cee82fd1c61521634d2d6b192fc526ffd938e904b8e6836b6c0cf8d875a`는 Prometheus **v3.14.0**이며 Harbor Trivy 결과 **CRITICAL=0 / HIGH=3**으로 현재 Gate를 통과하지 못했다. 삭제하지 않고 실패 증적으로 보존하며 monitor01 공급/기동에 사용하지 않는다.
- receiver 신규 후보는 공식 `prom/prometheus:v3.15.0`이다. 태그 자체를 승인값으로 사용하지 않고 upstream immutable digest를 먼저 고정한 뒤 Harbor `fds/prometheus`로 mirror한다. **2026-09-30 HBR #13에서 v3.15.0 신규 mirror는 조건부 승인됐다. 다만 harbor01 TLS가 self-signed로 회귀해 승인 CA 서명 Leaf 복구 확인 전에는 Push하지 않는다.** candidate에는 `latest`를 사용하지 않고(예: `v3.15.0-candidate-20260930`), Push 전/후 기존 `fds/prometheus:latest` digest가 변하지 않았는지 확인한다. Harbor에서 다시 Scan하여 **CRITICAL=0 / HIGH=0**인 정확한 Harbor digest만 승인 후보가 된다.
- 세부 handoff와 중단 기준은 [PROMETHEUS_V315_HANDOFF_20260930.md](PROMETHEUS_V315_HANDOFF_20260930.md)를 따른다.
- blackbox-exporter, nginx는 기존 HBR 인계 절차를 유지한다. 승인된 source/digest를 Harbor `fds/`로 mirror하고 CRITICAL/HIGH=0을 확인한 뒤 immutable digest를 기록한다.
- monitor01에는 Harbor 경로가 없으므로, **승인 확정된 Harbor digest로 다시 pull한 tar**만 ansible01 → monitor01(관리망)로 전달하고 `podman load`한다. tar SHA256과 load 후 local image digest를 대조한다.

## 저장소 안전 실행기

- `monitor01/runtime_launch_local.py`: monitor01의 `server01_monitor`만 실행한다. Harbor **digest 참조만** 받고 receiver/Blackbox의 exact Podman argv를 저장소 코드로 고정한다. receiver는 `127.0.0.1:19090`, Blackbox는 `127.0.0.1:9115`를 강제하고, 기동 직후 `ss -ltnH` 결과가 localhost-only가 아니면 이번 두 컨테이너를 즉시 회수한다.
- `monitor01/runtime_fault_api_lb.py`: `server01_monitor`의 `sudo -n` 실행만 허용한다. 영향 범위는 **monitor01의 모든 OUTPUT TCP → 10.1.93.109:6443**이다. 동일 목적지의 기존 OUTPUT rule이 있으면 중단한다. firewalld direct rule을 넣기 전에 systemd transient timer로 동일 rule의 30~180초 자동 회수를 먼저 arm하고, 정상 종료 시 exact rule 제거와 timer 정리를 수행한다.
- 두 스크립트 모두 보안 통제를 해제하지 않는다. SELinux/firewalld 서비스 자체를 중지하거나 `--insecure` 옵션을 쓰지 않는다.

## 9/29(화) — receiver·Blackbox 기동, LB Probe 실패·복구
1. **사전 조회:** `podman images`, `ss -ltnp`, `firewall-cmd --list-all`, `getenforce`, `df -h /var`
2. **디렉터리 준비:** 위 경로를 만들고, 데이터 디렉터리는 `65534:65534`(prometheus 이미지 사용자)로 둔다. SELinux는 볼륨 `:Z`로 처리한다. 키 디렉터리는 relabel하지 않는다.
3. **설정 준비:** `source_ipv4=10.1.93.108`은 2026-09-28 IF-06B 동기 tcpdump 실측값을 사용한다. 첫날에는 NGINX/sender를 만들지 않는다. receiver 설정은 README의 heartbeat/watchdog + `blackbox/receiver-scrape-blackbox.json`만 합쳐 `/etc/fds/monitor01/receiver/prometheus.yml`에 두고, Blackbox 설정은 저장소 `blackbox.yml`과 byte/hash를 대조해 `/etc/fds/monitor01/blackbox/blackbox.yml`로 둔다. 실제 승인 이미지의 `promtool check config` / `check rules`를 먼저 통과해야 한다.
4. **localhost-only 기동:** Blackbox Harbor digest가 확정된 뒤 아래 저장소 실행기만 사용한다. 임의 `podman run` 재작성은 하지 않는다.
   - `python3 monitor01/runtime_launch_local.py start --receiver-image <approved-prometheus@sha256:...> --blackbox-image <approved-blackbox@sha256:...>`
   - 기존 Prometheus v3.14.0 `b77f9cee...`는 HIGH=3이므로 이 자리의 승인 digest로 사용할 수 없다.
   - 실행기는 비-digest 이미지, 기존 동명 컨테이너, 누락 config/data, root 실행을 거부한다.
   - 성공 기준은 `ss -ltnH`에서 19090·9115가 각각 `127.0.0.1`에만 존재하는 것이다. `0.0.0.0`, `::`, 관리망 IP listen이 하나라도 보이면 실행기가 두 컨테이너를 회수하고 STOP한다.
5. **LB Probe 시험(#17 AC "API LB TCP Probe 실패·복구")**
   - 정상: `probe_success{instance="10.1.93.109:6443"}` = 1을 2회 이상 확인한다.
   - 영향 경계: fault rule은 **monitor01 전체**의 `.109:6443` OUTPUT을 최대 180초 REJECT한다. 클러스터/LB 설정은 바꾸지 않지만 monitor01의 다른 API-LB 소비자도 영향을 받는다. 실행 직전 스크립트가 현재 연결을 원문으로 출력하므로 다른 업무 소비자가 있으면 중단한다.
   - 실행: `sudo -n python3 monitor01/runtime_fault_api_lb.py --ack-hostwide --duration 180 | tee <증적폴더>/fault-api-lb.jsonl`
   - 자동 회수: 스크립트는 rule 추가 전에 systemd transient timer로 **동일 comment tag의 exact rule 제거**를 arm한다. SSH/셸이 끊겨도 timer가 회수한다. 정상 종료 시에도 exact rule을 제거하고 timer를 중지한 뒤 해당 tag 부재를 재확인한다.
   - OOB/로컬 콘솔 회수: 자동 timer와 별개로 `sudo firewall-cmd --direct --get-all-rules | grep FDS_MON19_`에서 **이번 로그에 기록된 tag만** 찾는다. 다른 rule은 삭제하지 않는다.
     - exact 제거: `sudo firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -d 10.1.93.109/32 -p tcp --dport 6443 -m comment --comment <FDS_MON19_tag> -j REJECT`
     - timer 정리: `<FDS_MON19_tag>`를 소문자로 바꾼 unit에 대해 `sudo systemctl stop <unit>.timer <unit>.service`를 수행한다.
     - tag를 특정하지 못하면 임의 삭제하지 않고 OOB에서 `--get-all-rules` 원문과 fault 로그를 대조한 뒤 회수한다.
   - 실패 판정: fault 활성 중 `probe_success`가 0이 되지 않으면 시험 실패로 남기고 시간을 연장하거나 보안 통제를 완화하지 않는다.
   - 복구 판정: rule 부재 확인 후 `probe_success`가 1로 2회 이상 복귀해야 한다. pre/post `firewall-cmd --direct --get-all-rules`, 연결 목록, query_range, 시각, 실행 로그를 보존한다.
6. **서비스 복구:** `python3 monitor01/runtime_launch_local.py stop`으로 이번 두 이름의 컨테이너만 회수한다. 설정·receiver data는 증적으로 보존하고 cockpit·인증서·개인키·SELinux·firewalld 서비스는 건드리지 않는다.

## 9/30(수) — sender 연결과 출발지 실측 (ICR 공동)
1. 클러스터 Secret 2개를 만든다(값 비기록). CA는 공개 인증서, auth password는 monitor01 htpasswd와 짝을 맞춘다.
2. `sender.remote-write.fragment.json`과 `sender.heartbeat.rules.json`을 in-cluster Prometheus에 반영한다. 별도 코드 PR로 독립 리뷰를 받는다.
3. **출발지 실측은 2026-09-28 조기 완료했다.** monitor01 `ens160`에서 `10.1.93.108:* -> 10.250.10.30:443 SYN`을 반복 관측했고, mgmt-gw01에서도 ens160 In → ens224 Out 동일 source 보존을 확인했다. `source_ipv4=10.1.93.108`을 사용해 `render_candidate.py`로 nginx 설정을 생성한다.
4. monitor01 firewalld에 **관측 출발지 /32 → 443만** rich rule로 허용하고, nginx를 기동한다.

## 10/1(목) — 인수 시험 (README 표 기준)
- 정상 전송 2xx와 receiver `fds_monitoring_heartbeat` 수신
- 무인증 401, 비허용 출발지 차단, GET 405, 다른 경로 404, TLS 1.0·1.1 실패(`-k` 금지)
- payload는 heartbeat만 오는지 확인
- in-cluster Prometheus 중단(`scale 0`) → 5분 이내 `FDSMonitoringHeartbeatMissing` → 복구 후 해소. 중단·마지막 sample·첫 감지 시각을 실측한다.

## 알려진 제약
- podman 컨테이너 자동 기동(재부팅 지속성)은 9/29 기동 확인 뒤 `podman generate systemd` 또는 Quadlet으로 따로 처리한다.
- edge01 HTTPS Probe는 제외한다(edge01에 443 없음). AC는 "edge01 HTTPS **또는** API LB TCP Probe"라 LB로 충족을 시도한다.
