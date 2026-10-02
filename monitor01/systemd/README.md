# monitor01 재부팅 자동 기동 (P1-MON-01 #17)

monitor01은 rootless podman(`server01_monitor`)으로 receiver·blackbox·nginx를 실행한다. 이 폴더의 사용자 유닛은 재부팅 뒤 **저장소 실행기 `runtime_launch_local.py`를 그대로** 불러 같은 검증(이미지 ID = 승인 config digest, `--pull=never`, 고정 argv, listen 주소 확인)을 거쳐 다시 기동한다. 컨테이너 재시작 정책이나 Quadlet으로 실행 경로를 따로 만들지 않는다.

| 파일 | 설치 위치 | 내용 |
|---|---|---|
| `images.env` | `~/.config/fds-monitor01/images.env`(0600) | 승인 Harbor digest와 예상 config digest 6줄(비밀 아님) |
| `fds-monitor01-local.service` | `~/.config/systemd/user/` | `stop` → `start`(receiver·blackbox) |
| `fds-monitor01-nginx.service` | `~/.config/systemd/user/` | receiver 뒤 `stop-nginx` → `start-nginx` |

- 실행기는 `~/fds-mon-tools/current/runtime_launch_local.py`에서 부른다. `current`는 병합본 폴더(예: `~/fds-mon-tools/<merge sha>/`)를 가리키는 심볼릭 링크다. 실행기를 바꿀 때는 새 폴더에 받아 SHA를 대조한 뒤 링크만 바꾼다.
- 재부팅 뒤에는 이전 컨테이너가 Exited로 남는다. 실행기 `start`는 같은 이름이 있으면 STOP하므로, 기동 전에 같은 실행기의 `stop`/`stop-nginx`로 **이 세 이름만** 회수한다. 설정·데이터·인증서·키는 호스트 경로라 영향이 없다. 이전 컨테이너 로그는 이때 사라진다.
- 실패하면(예: 부팅 직후 `10.250.10.30`이 아직 없음) `Restart=on-failure`로 30초 뒤 다시 시도한다. 10분에 5회를 넘으면 멈춘다.
- 이 유닛은 재부팅 지속성만 다룬다. 실행 중 컨테이너가 죽었을 때의 자동 재시작은 범위 밖이다(Known Limitation).

## 설치 (MON Lead, monitor01 `server01_monitor`)

1. 실행기 병합본을 `~/fds-mon-tools/<merge sha>/`에 받아 SHA를 대조하고 `ln -sfn ~/fds-mon-tools/<merge sha> ~/fds-mon-tools/current`
2. `install -d -m 700 ~/.config/fds-monitor01 ~/.config/systemd/user`, `install -m 600 images.env ~/.config/fds-monitor01/`, `install -m 644 fds-monitor01-*.service ~/.config/systemd/user/`
3. `sudo loginctl enable-linger server01_monitor` → `loginctl show-user server01_monitor -p Linger`가 `Linger=yes`
4. `systemctl --user daemon-reload && systemctl --user enable fds-monitor01-local.service fds-monitor01-nginx.service`
5. 확인: 아래 둘 중 하나
   - 유닛 인수: `systemctl --user restart fds-monitor01-local.service fds-monitor01-nginx.service`. 컨테이너를 다시 만들므로 heartbeat 수신이 수십 초 끊기고, 마지막 샘플 뒤 5분 안이면 Watchdog은 firing되지 않는다.
   - 재부팅 시험: monitor01 재부팅 뒤 로그인 없이 세 컨테이너 Up, listener 3개, heartbeat 수신, `systemctl --user status` active(exited)

## 되돌리기

`systemctl --user disable --now fds-monitor01-nginx.service fds-monitor01-local.service`(컨테이너도 회수됨 → 필요하면 실행기로 수동 기동), `sudo loginctl disable-linger server01_monitor`, 설치한 유닛·`images.env` 삭제.
