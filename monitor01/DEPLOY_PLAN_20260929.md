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
| `source_ipv4` | **비움.** 9/30 실측 후 채운다 | README 원칙: 추정 입력 금지 |

## 이미지 (NOT RUN)
- receiver: `10.1.93.54/fds/prometheus@sha256:b77f9cee82fd1c61521634d2d6b192fc526ffd938e904b8e6836b6c0cf8d875a`(클러스터와 같은 digest)
- blackbox-exporter, nginx: Harbor 미러링은 HBR(이하영) 승인이 필요하다(#17 요청). 승인되면 9/22와 같은 경로(ansible01 → tar → push)를 쓰고, digest를 기록한다.
- monitor01에는 Harbor 경로가 없으므로, 같은 tar를 ansible01 → monitor01(관리망)로 `scp`한 뒤 `podman load`한다. load 후 `podman images --digests`로 digest를 대조한다.

## 9/29(화) — receiver·Blackbox 기동, LB Probe 실패·복구
1. **사전 조회:** `podman images`, `ss -ltnp`, `firewall-cmd --list-all`, `getenforce`, `df -h /var`
2. **디렉터리 준비:** 위 경로를 만들고, 데이터 디렉터리는 `65534:65534`(prometheus 이미지 사용자)로 둔다. SELinux는 볼륨 `:Z`로 처리한다. 키 디렉터리는 relabel하지 않는다.
3. **설정 생성:** 이 시점에는 `render_candidate.py`가 `source_ipv4` 부재로 중단된다. 그래서 첫날에는 receiver 설정을 다음 조합으로 직접 만든다.
   - `watchdog.rules.json`: README의 `absent_over_time(fds_monitoring_heartbeat[5m])` 규칙과 같다
   - `blackbox/receiver-scrape-blackbox.json`을 `scrape_configs`에 넣는다
   - `promtool check config` / `check rules`를 같은 이미지로 실행한다
4. **기동:** blackbox를 `127.0.0.1:9115`, receiver를 `127.0.0.1:19090`(`--web.enable-remote-write-receiver`)으로 띄운다.
5. **LB Probe 시험(#17 AC "API LB TCP Probe 실패·복구")**
   - 정상: `probe_success{instance="10.1.93.109:6443"}` = 1을 2회 이상 확인한다.
   - 실패 유도: **monitor01에서만** firewalld direct rule로 `.109:6443` 출력을 3분간 거부한다. 클러스터와 LB에는 영향이 없다. `probe_success`가 0이 되는지 확인한다.
   - 복구: 규칙을 제거한 뒤 1로 돌아오는지 확인한다.
   - 기록: query_range 원문, 시각, 규칙 추가·삭제 명령. 이 방식은 "monitor01 관점의 Probe 실패·복구"다. LB 자체 장애 시험은 P1-LB-01(이권욱) 범위다.
6. **복구 절차:** `podman rm -f`로 이번에 만든 컨테이너만 지우고, 설정·데이터는 증적으로 보존한다. cockpit·인증서·키는 건드리지 않는다.

## 9/30(수) — sender 연결과 출발지 실측 (ICR 공동)
1. 클러스터 Secret 2개를 만든다(값 비기록). CA는 공개 인증서, auth password는 monitor01 htpasswd와 짝을 맞춘다.
2. `sender.remote-write.fragment.json`과 `sender.heartbeat.rules.json`을 in-cluster Prometheus에 반영한다. 별도 코드 PR로 독립 리뷰를 받는다.
3. monitor01에서 `tcpdump -ni ens160 tcp port 443`으로 실제 SYN 출발지를 관측한다(ICR 입회). 그 값을 `source_ipv4`에 넣고 `render_candidate.py`로 nginx 설정을 생성한다.
4. monitor01 firewalld에 **관측 출발지 /32 → 443만** rich rule로 허용하고, nginx를 기동한다.

## 10/1(목) — 인수 시험 (README 표 기준)
- 정상 전송 2xx와 receiver `fds_monitoring_heartbeat` 수신
- 무인증 401, 비허용 출발지 차단, GET 405, 다른 경로 404, TLS 1.0·1.1 실패(`-k` 금지)
- payload는 heartbeat만 오는지 확인
- in-cluster Prometheus 중단(`scale 0`) → 5분 이내 `FDSMonitoringHeartbeatMissing` → 복구 후 해소. 중단·마지막 sample·첫 감지 시각을 실측한다.

## 알려진 제약
- podman 컨테이너 자동 기동(재부팅 지속성)은 9/29 기동 확인 뒤 `podman generate systemd` 또는 Quadlet으로 따로 처리한다.
- edge01 HTTPS Probe는 제외한다(edge01에 443 없음). AC는 "edge01 HTTPS **또는** API LB TCP Probe"라 LB로 충족을 시도한다.
