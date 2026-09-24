# MON 후속 입력 수집 — 순수 Pre-check

책임: [ICR #14](https://github.com/321Team/fds-project-baseline/issues/14)의 경로 준비 지원(이권욱), [MON #17](https://github.com/321Team/fds-project-baseline/issues/17)의 형상·서비스 인수(Lead 이재환). [#75](https://github.com/321Team/fds-project-baseline/issues/75)의 Lead 이하영/Support 이재환을 유지한다. 이 도구는 승인권·Runtime AC를 변경하지 않는다.

## 수집 범위

- 기존 ansible01 → svc_ansible@k8s-control01 → 기존 `sudo -n kubectl`·admin.conf API 경로로만 읽는다. API 주소/LB·inventory·계정을 바꾸지 않는다.
- monitoring-api/node의 Pod·Deployment/DaemonSet·Service·PVC·NetworkPolicy와 monitoring-api ConfigMap을 제한된 LIST 11회로 조회한다. 조회당 limit100, timeout15초, 추가 페이지가 있으면 미완료로 남긴다.
- 출력은 이미지/실제 imageID, SA/imagePullSecrets 이름, Secret·ConfigMap·PVC **참조**, mount/subPath, 준비 상태·IP, Service 노출, NP spec, ConfigMap key별 SHA256다. Secret API, env 값, args, 주석/annotation, 설정 원문, 로그, token, 비밀키는 출력하지 않는다. ConfigMap/Pod 응답 원문은 원격 프로세스 메모리에서만 투영한다.
- 소스 기준은 `a885cef2358682214095590baf69b77062978778`의 정본 monitoring manifest에서 생성한 `source-reference.json`이다. 파일 경로/Git blob SHA와 선택 필드를 함께 기록했다.
- **DIFF는 복구 명령이 아니다.** main의 `latest` 이미지·screen-only 설정으로 되돌리지 않는다. API default/순서 차이도 수동 대조하며, ConfigMap hash는 저장 바이트이지 실제 process load 증거가 아니다. 새 HBR digest의 승인·취약점 결과를 이 수집으로 대신하지 않는다.
- Pod 목록과 객체는 순차 시점 관측이다. 원자적 snapshot이나 이중 scrape 시험이 아니며, 변경 중이었다면 영향 객체만 다시 확인한다.

## 실행 — ansible01

PR에 게시한 정확한 source SHA를 사용한다. 기존 Lead 판단 아래 1회 조회하며, 리뷰/병합 상태를 현장 성공으로 표시하지 않는다. 새 패키지나 SSH/sudo 권한을 설치하지 않는다.

```bash
(
set -euo pipefail
umask 077
MON_FOLLOWUP_SHA='<PR에 게시한 40자리 source SHA>'
[[ "$MON_FOLLOWUP_SHA" =~ ^[0-9a-f]{40}$ ]]
MON_FOLLOWUP_BOOT=$(mktemp /home/server01_ansible/mon-followup-run.XXXXXXXX)
gh api "repos/321Team/infra-monitoring/contents/ops/mon-followup/run.sh?ref=$MON_FOLLOWUP_SHA" \
  -H 'Accept: application/vnd.github.raw+json' > "$MON_FOLLOWUP_BOOT"
bash "$MON_FOLLOWUP_BOOT" "$MON_FOLLOWUP_SHA"
)
```

결과는 `/home/server01_ansible/MON_FOLLOWUP.*/`와 `.tar.gz`, `.tar.gz.sha256`이다. 압축에는 선택 결과·소스·로그·내부 해시만 포함한다. inventory/env/Ansible 임시 파일은 포함하지 않는다. source5파일 검증과 전송용 hash는 증적 보조이며 배포 보안 게이트가 아니다. 원격 대상에는 파일을 만들지 않는다. `copy changed`는 controller 결과 파일 작성이다.

`COLLECTION_RC != 0`이면 안전한 JSON의 실패 check 이름을 확인한다. 실패/호스트 불일치/권한 부족을 고치려고 sudoers·RBAC·방화벽을 자동 변경하지 않는다. 미완료 archive도 보존한다. `-vvv`, `ANSIBLE_DEBUG=1`, raw register dump를 추가하지 않는다.

## monitor01 — 기존 콘솔에서 별도 1회

확인한 infra-ansible main inventory에는 monitor01이 없다. 새 inventory·svc_ansible 계정을 가정하지 않는다. 기존 `server01_monitor`/승인 콘솔 접근과 기존 sudo만 사용한다. 필요하면 같은 source SHA의 `public_inventory.py`를 승인된 경로로 실행자 작업 디렉터리에 전달하고 다음처럼 실행한다. gh/scp/WinSCP 설치나 새 접근 개방은 이 작업에 포함되지 않는다.

```bash
(
set -euo pipefail
umask 077
test "$(hostname -s)" = monitor01
# 현재 디렉터리는 고정 SHA public_inventory.py를 전달받은 실행자 작업 디렉터리.
test -r public_inventory.py
MON_HOST_DIR=$(mktemp -d "$HOME/MON_HOST_INPUTS.XXXXXXXX")
MON_HOST_RC=0
sha256sum public_inventory.py > "$MON_HOST_DIR/source.sha256"
python3 public_inventory.py monitor01 > "$MON_HOST_DIR/monitor01.json" || MON_HOST_RC=$?
printf 'COLLECTION_RC=%s\n' "$MON_HOST_RC" > "$MON_HOST_DIR/result.txt"
tar -czf "$MON_HOST_DIR.tar.gz" -C "$MON_HOST_DIR" source.sha256 monitor01.json result.txt
sha256sum "$MON_HOST_DIR.tar.gz" > "$MON_HOST_DIR.tar.gz.sha256"
printf 'ARCHIVE=%s.tar.gz\n' "$MON_HOST_DIR"
exit "$MON_HOST_RC"
)
```

monitor01에서는 host/IP, TCP listen, 알려진 nginx/Prometheus/Blackbox/Docker/Podman/Cockpit unit 상태, rootful 컨테이너의 이름/이미지/상태/포트, 디스크 용량, 기존 공개 인증서·개인키 **파일 metadata만**, workers/ansible01 대상 route를 읽는다. 없는 binary/unit·기존 sudo 부족은 해당 check 미완료다. custom/rootless 서비스 누락 가능성을 결과에 표시한다. route는 실제 IF-06B 수신 Source가 아니므로 allowlist에 자동 입력하지 않는다.

기존 PKI 발급/체인 시험, 05:00 TLS 입력, Source/SNAT·DROP counter는 반복하지 않는다. 서비스 설치/시작, 포트 probe·packet capture, Alert 발송·Secret 교체, CSR 승인·Pod 재시작·정책 적용은 없다.

## 수신 후 진행

1. MON Lead가 main↔배포 image/mount/PVC/config 차이를 현장 승인 근거와 대조한다. Alertmanager `discord-webhook`의 readOnly/subPath와 digest는 #75 후속 입력이다.
2. monitor01의 receiver port·실행 모델·서비스 UID/GID·data/config dir·용량/retention·승인 artifact·auth/root mount 참조를 기존 `monitor01/inputs.example.json`에 결정값으로 인계한다. 조회 결과만으로 포트/계정을 임의 선택하지 않는다.
3. 현재 sender/receiver 준비 후 별도 IF-06B 실제 Source와 return path를 관측한다. 아직 그 경로의 신규 probe를 실행하지 않는다.
4. Grafana Datasource Health/승인 dashboard·접근 차단·재시작 후 query는 기존 증적을 우선 연결한다. 이 metadata 조회로 해당 AC를 PASS 처리하지 않는다.

STATIC 및 모의시험은 PR에 기록한다. CI·FIELD COLLECTION·REVIEW·MERGE·Runtime ACCEPTANCE는 각각 표시한다.
