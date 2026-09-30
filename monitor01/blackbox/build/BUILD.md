# monitor01 blackbox-exporter 소스 빌드 — `065fc188`

monitor01 IF-06A Probe(`blackbox.yml`, `tcp_connect`)에 쓸 blackbox-exporter 이미지를 upstream 소스에서 빌드한다. 이 폴더는 **빌드 입력과 절차의 정본**이다. 결과 이미지의 채택은 HBR 절차(Harbor push → Trivy CRITICAL 0 / HIGH 0 → digest 확정)로 따로 판정한다.

## 왜 소스 빌드인가

| 후보 | Harbor/Trivy 결과 | 판정 |
|---|---|---|
| 공식 `prom/blackbox-exporter:v0.27.0`(`a50c4c0e…`) | CRITICAL 2 / HIGH 41 ([#13 5908279001](https://github.com/321Team/fds-project-baseline/issues/13#issuecomment-5908279001)) | 미달 |
| 공식 `v0.28.0`(최신 릴리스) | CRITICAL 2 / HIGH 39 (2026-09-27 monitor01 Trivy 0.74.0, evidence `P1-MON-01/received-20260927T0530Z/monitor01-lb-probe/trivy-summary.txt`) | 미달 |
| upstream master `065fc188` 소스 빌드 | CRITICAL 0 / HIGH 0 (같은 날 같은 방식) | 후보. Harbor 재검사 필요 |

- 공식 릴리스에는 master에서 이미 고친 의존성이 반영되지 않았다(upstream [issue #1668](https://github.com/prometheus/blackbox_exporter/issues/1668) "Request a patch release" open).
- Chainguard의 blackbox 이미지는 무료로 제공되지 않는다(2026-09-27 pull 403).
- 2026-09-27 monitor01 빌드본(`localhost/fds/blackbox-exporter:0.28.0-master.065fc18`)은 Harbor를 거치지 않고 monitor01에서 직접 만들어 **무효**다(ICR 절차 위반, 재사용 금지 — `PROMETHEUS_V315_HANDOFF_20260930.md`). 이번에는 같은 입력을 승인 경로로 다시 만든다.
- `065fc188`로 고정하는 이유: 2026-09-27 검사를 통과한 커밋이고, [#13 회신 5906464802](https://github.com/321Team/fds-project-baseline/issues/13#issuecomment-5906464802)에서 이 커밋으로 약속했다. 그 뒤 master에 들어온 의존성·Go 갱신(2026-09-29 `2bd1bf8` 등)은 평가하지 않았으므로 섞지 않는다. Harbor Trivy에서 미달이면 새 커밋을 따로 제안한다.

## 입력 (모두 고정값)

| 입력 | 값 |
|---|---|
| 소스 | `github.com/prometheus/blackbox_exporter` commit `065fc188bd7609e41d9e28039dc4ee2cde5d5d74`(2026-09-25, PR #1673 병합) |
| 소스 tar | `https://codeload.github.com/prometheus/blackbox_exporter/tar.gz/065fc188…` SHA-256 `952651a8e3a9944b856e2e96c0079610f18599277b7161591331170bbd66d86e`(2026-09-27 받은 값) |
| 빌드 이미지 | `docker.io/library/golang@sha256:54b6b88db6fe375c6676625d87d668273f85c6d09153635d0cbba89cba7a207a`(go1.25.14) |
| 실행 base | `cgr.dev/chainguard/static@sha256:c5fed92d0fda728930795cafb61192d8abc9e2f606b22996b212e0169f1d42e6` |
| Go 모듈 | 소스의 `go.sum`으로 검증(`GOFLAGS=-mod=readonly`), toolchain 자동 다운로드 금지(`GOTOOLCHAIN=local`) |
| 버전 표기 | `0.28.0-master.065fc18`, revision `065fc188…`, branch `master`(ldflags) |

## 절차

1. **빌드 — MON Lead, ansible01(`server01_ansible`, 인터넷 가능·Harbor 불가):** 이 폴더의 `Containerfile`·`build.sh`를 같은 폴더에 두고 `bash build.sh`
   - 소스 tar SHA가 위 값과 다르거나, pull·build·`--version` 확인이 실패하면 멈춘다(`result.txt`에 STOP 사유).
   - 결과: `~/bb-build-<시각>/`에 `blackbox-exporter-065fc18.tar`(docker-archive), `SHA256SUMS`, `build.log`, `build-inputs.txt`(실제 pull digest), `version.txt`, `image-id.txt`, `image-config.txt`
   - 운영 서버·Harbor·monitor01은 건드리지 않는다.
2. **Harbor 반입·검사 — HBR(이하영), 기존 미러링 절차와 같음:** tar를 control01로 옮겨 `podman load` → `10.1.93.54/fds/blackbox-exporter:0.28.0-master.065fc18-candidate-<날짜>`로 push → Harbor Trivy CRITICAL 0 / HIGH 0 확인 → Harbor digest 기록 → 승인 digest 재-pull·tar·SHA256을 ansible01에 둔다. `latest`나 기존 태그는 쓰지 않는다.
3. **monitor01 기동 — MON Lead:** `DEPLOY_PLAN_20260929.md`와 `runtime_launch_local.py`대로 Harbor digest만 받아 기동한다. 실행 인자는 실행기가 정한다(`--config.file=/etc/blackbox/blackbox.yml`, `--web.listen-address=127.0.0.1:9115`).

## 확인할 결과

- `version.txt`: `blackbox_exporter, version 0.28.0-master.065fc18 (branch: master, revision: 065fc188bd7609e41d9e28039dc4ee2cde5d5d74)`, go1.25.14
- `image-config.txt`: User `65532:65532`, Entrypoint `["/bin/blackbox_exporter"]`
- 이미지 ID는 빌드 시각 때문에 2026-09-27 값(`8d75253e…`)과 다를 수 있다. 입력 digest·소스 SHA·version 출력이 같으면 같은 빌드로 본다.
