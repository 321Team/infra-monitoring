# monitor01 콘솔 입력 점검

책임: MON #17 Lead 이재환, ICR #14 이권욱의 경로 지원. 기존 단발성 reader `public_inventory.py`의 monitor01 조회 범위를 콘솔용 Bash 진입점으로 준비했다. K8s 수집을 반복하지 않는다. 모니터01의 현재 Ansible inventory/SSH 권한을 새로 가정하지 않는다.

## 위치와 준비

- **실행 호스트: monitor01 (10.250.10.30)**. ansible01이나 K8s 노드에서 실행하지 않는다.
- 기존 `server01_monitor` 또는 승인 콘솔 계정을 사용한다. Bash/coreutils/iproute/systemctl 등 이미 설치된 도구만 사용한다. 설치하지 않는다.
- `monitor01-console.sh`와 `SHA256SUMS`를 실행자 홈의 새 작업 폴더에 둔다. 기존 경로를 비우거나 덮지 않는다. 파일 전달이 어려우면 같은 공개 스크립트의 내용을 VM 콘솔에 붙여넣어 저장할 수 있다. 이 자료에 실제 Secret/개인키/Password는 없다.

```bash
umask 077
MON_WORK_DIR=$(mktemp -d "$HOME/MON_CONSOLE_WORK.XXXXXXXX")
printf 'WORK_DIR=%s\n' "$MON_WORK_DIR"
cd "$MON_WORK_DIR"
# 전달받은 monitor01-console.sh와 SHA256SUMS를 이 폴더에 둔 후:
sha256sum -c SHA256SUMS
bash monitor01-console.sh
```

기존 sudo가 password 확인을 요구하면 승인된 계정에서 `sudo -v`로 인증한 뒤 실행할 수 있다. 이는 기존 권한의 인증이며 새 sudoers 권한을 부여하지 않는다. 인증할 수 없으면 해당 항목은 rc와 함께 미완료로 남긴다. 비밀번호를 명령 인자·파일·채팅에 넣지 않는다.

## 수집·판정

스크립트는 host/IP를 확인한 뒤 `$HOME/MON_HOST_INPUTS.XXXXXXXX/`를 자동 생성한다. identity/account/IP/listen, 알려진 nginx/Prometheus/Blackbox/Docker/Podman/Cockpit unit, 용량/SELinux, worker3대·ansible01의 후보 route, 기존 인증서/개인키 **metadata**, rootful container의 이름/이미지/상태/포트만 조회한다. 각 조회 timeout20초. 개인키 내용, Secret, env/args, 전체 unit/config/log는 읽지 않는다. 출력은 실행자 결과 폴더에만 작성한다.

- 결과: `checks.tsv`에 각 command rc, `result.txt`에 nonzero count, 원본 stdout/stderr, 수집기 사본, 내부 SHA256SUMS, 외부 `.tar.gz.sha256`.
- **CHECKS=16**. rc0은 해당 조회가 성공했다는 의미다. 서비스 active·443/receiver 존재를 그 숫자만으로 판정하지 않는다. `LoadState=not-found`도 내용으로 해석한다.
- 없는 docker/podman·미배치 인증서·기존 sudo 부족은 nonzero로 보존한다. 실패가 있어도 나머지 항목과 archive를 만들고 최종 nonzero로 종료한다. 자동 재설치/서비스 시작/복구는 없다.
- custom unit·rootless container는 이 고정 목록으로 누락될 수 있다. directory 용량·route 후보는 승인 receiver data path/실제 송신 Source의 확정값이 아니다.
- shell prompt로 돌아온 뒤 표시된 `.tar.gz`와 `.tar.gz.sha256`을 함께 제출한다. host/IP 불일치 시는 결과 폴더 생성 전에 중단하므로 대상부터 확인한다.

## 이번에 하지 않는 작업

PKI 발급·Secret 갱신, 서비스 설치/재시작/reload, 방화벽·SELinux·NetworkPolicy 변경, 네트워크 probe/packet capture, remote_write 적용은 하지 않는다. 결과로 receiver 실행 모델/port·dir·계정·artifact·Root/auth 참조의 누락을 좁힌 후 기존 MON Lead의 배포 통합으로 연결한다.

분류: 순수 Pre-check. REVIEW=NOT PERFORMED (Pre-check). 실행 준비·현장 수집·Runtime 인수는 구분한다. 기존 source의 모의8건/CP 수집 성공을 이 콘솔 진입점의 현장 성공으로 승계하지 않는다.
