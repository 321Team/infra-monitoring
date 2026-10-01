# monitoring-node node-exporter 소스 빌드 — `v1.12.1` + `golang.org/x/crypto v0.56.0`

클러스터 `monitoring-node` DaemonSet(`../../node-exporter.yaml`)에 쓸 node-exporter 이미지를 upstream 소스에서 빌드한다. 이 폴더는 **빌드 입력과 절차의 정본**이다. 결과 이미지의 채택은 HBR 절차(Harbor push → Trivy CRITICAL 0 / HIGH 0 → digest 확정)로 따로 판정한다. 이 폴더에는 Kubernetes 매니페스트가 없다(`kubectl apply -f kubernetes/monitoring/`로 적용되는 파일 없음).

## 왜 소스 빌드인가

| 후보 | Harbor/Trivy 결과 | 판정 |
|---|---|---|
| 현재 `fds/node-exporter@sha256:56566542aacd5be06add01d3456cd6279e2f7ddb4b24237fc8cdfbc3cc5f699f`(공식 v1.12.1, 2026-09-22 push) | Trivy v0.62.1 2026-10-01 12:28 KST: **CRITICAL 0 / HIGH 9** — Go stdlib v1.26.5 8건(수정 1.26.6 이상), `golang.org/x/crypto` v0.54.0 1건(CVE-2026-56854, 수정 v0.55.0). Medium 2(x/crypto, 수정 v0.56.0), Unknown 1 ([#13 5924275301](https://github.com/321Team/fds-project-baseline/issues/13#issuecomment-5924275301)) | 미달. HBR 승인 기록 없음 |
| 공식 최신 릴리스 | v1.12.1이 최신(2026-07-14). upstream master도 x/crypto v0.54.0 | 공식 이미지 교체로는 해결되지 않음 |
| **v1.12.1 소스 + Go 1.26.8 + x/crypto v0.56.0** | — | 이 폴더. Harbor 검사 필요 |

- 코드는 upstream v1.12.1 그대로이고 바꾸는 것은 **빌드 Go 버전과 x/crypto 버전 두 가지**다. 다른 의존성은 `go get`·`go mod tidy`가 x/crypto 요구에 맞춰 올리는 것만 바뀐다(결과 diff는 근거 묶음 `gomod.diff`).
- Go 1.26.8: x/crypto v0.56.0이 `go 1.26.0`을 요구한다. 또 Go 1.25는 1.27 출시로 지원이 끝났다(2026-10-01 go.dev 기준 지원 버전 1.27.1·1.26.8). upstream도 1.26 계열로 빌드한다(`.promu.yml` `go.version: 1.26`).
- x/crypto v0.56.0: High 1건(v0.55.0에서 수정)과 Medium 2건(v0.56.0에서 수정)을 함께 없애는 가장 낮은 버전이다. Unknown 1건(GO-2026-5932)은 수정 버전이 없다.
- 실행 base는 blackbox 빌드([infra-monitoring#30](https://github.com/321Team/infra-monitoring/pull/30))와 같은 Chainguard static이다. upstream 공식 이미지(busybox)와 달리 shell이 없다. DaemonSet은 exec·shell을 쓰지 않는다(probe는 httpGet).

## 입력 (모두 고정값)

| 입력 | 값 |
|---|---|
| 소스 | `github.com/prometheus/node_exporter` tag `v1.12.1` → commit `6044da783597cc3b57aef7580ddcdcff58a4ee99`(현재 이미지 `--version`의 revision과 같음) |
| 소스 tar | `https://codeload.github.com/prometheus/node_exporter/tar.gz/6044da78…` SHA-256 `cfec7478aa9bfd011f29df084584b7c7b68dfef85a24d28e9d6d5f88224f83c3`(2026-10-01 두 번 받아 같음, 415,720 B) |
| 빌드 이미지 | `docker.io/library/golang@sha256:0f063af2d465d8dcae54cce04278ada488b96f77b42449c8d071e47d016cc65a`(tag `1.26.8` index, linux/amd64 config `GOLANG_VERSION=1.26.8`·`GOTOOLCHAIN=local`) |
| 실행 base | `cgr.dev/chainguard/static@sha256:c5fed92d0fda728930795cafb61192d8abc9e2f606b22996b212e0169f1d42e6`(#30과 같음) |
| x/crypto | `v0.56.0`. go.sum 두 줄은 sum.golang.org 조회값으로 고정(`build.sh` `XCRYPTO_SUM`·`XCRYPTO_MOD`) |
| Go 모듈 | 3단계 `go get`·`go mod tidy`·`go mod verify`(`GOTOOLCHAIN=local`, 기본 GOPROXY·GOSUMDB) 뒤 빌드는 `GOFLAGS=-mod=readonly`로 그 go.sum만 쓴다 |
| 버전 표기 | `1.12.1-fds.1`, revision `6044da78…`, branch `v1.12.1`(ldflags). upstream 릴리스와 구분하려고 `-fds.1`을 붙인다 |
| 실행 사용자 | `65534:65534`(upstream 공식 이미지 `USER nobody`와 같음) |

## 절차

1. **빌드 — MON Lead, ansible01(`server01_ansible`, 인터넷 가능·Harbor 불가):** 이 폴더의 `Containerfile`·`build.sh`를 같은 폴더에 두고 `bash build.sh`
   - `pipefail`로 실행한다. 소스 tar SHA, pull·실제 pull digest 기록, `go get`/`tidy`/`verify`, x/crypto go.mod·go.sum 고정값, build, 바이너리 buildinfo(`go version -m`의 Go·x/crypto), `--version`(revision·Go), image ID/config 조회 중 하나라도 어긋나면 멈춘다(`result.txt`에 STOP 사유, 근거 묶음은 만들지 않음).
   - 결과(`~/ne-build-<시각>/`):
     - 이미지 `node-exporter-1.12.1-fds.1.tar`(docker-archive)
     - 빌드 근거 파일: `Containerfile`·`build.sh`·`kit.sha256`·`meta.txt`·`ne-src.sha256`·`build-inputs.txt`(실제 pull digest)·`gomod.log`·`gomod.diff`(원본 대비 go.mod·go.sum 변경)·`go.mod.updated`·`go.sum.updated`·`build.log`(buildinfo 포함)·`version.txt`·`image-id.txt`·`image-config.txt`·`result.txt`(DONE)
     - `SHA256SUMS`: 이미지 tar·소스 tar·빌드 근거 파일 **전부**
     - **빌드 근거 묶음** `build-evidence-node-exporter-1.12.1-fds.1.tar.gz`(근거 파일 + 소스 tar + `SHA256SUMS`)와 sidecar `.sha256`
   - 운영 서버·Harbor는 건드리지 않는다.
2. **전달:** ansible01 → control01(`server02`) — 2026-10-01 blackbox와 같은 경로(ansible01에서 `scp`). 인계물 3개(이미지 tar, 근거 묶음, sidecar)의 SHA-256을 #13에 적는다.
3. **Harbor 반입·검사 — HBR 승인 범위(2026-10-01 회의 구두 승인: push `robot$push`, 조회·스캔):**
   - 인수 검증(전달물 3개만으로):
     ```bash
     sha256sum -c build-evidence-node-exporter-1.12.1-fds.1.tar.gz.sha256
     mkdir v && tar xzf build-evidence-node-exporter-1.12.1-fds.1.tar.gz -C v && cp node-exporter-1.12.1-fds.1.tar v/ && cd v
     LC_ALL=C sha256sum -c SHA256SUMS   # 이미지 tar·소스 tar·근거 파일 전부 OK
     ```
     이어서 소스 tar SHA가 입력 표 값과 같은지, `podman load` 뒤 image ID가 `image-id.txt`와 같은지, `version.txt` revision·Go, `build-inputs.txt` digest가 입력 표와 같은지 대조한다.
   - `10.1.93.54/fds/node-exporter:1.12.1-fds.1-candidate-<날짜>`로 push(TLS 검증 `--cert-dir`) → Harbor manifest `config.digest` = image ID 확인 → Trivy CRITICAL 0 / HIGH 0 확인 → HBR Lead 대조·확정. `latest`·기존 태그는 쓰지 않고, 기존 `56566542…`는 원복용으로 지우지 않는다.
4. **클러스터 적용 — MON Lead, 별도 PR:** 확정 digest로 `../../node-exporter.yaml` 이미지 한 줄만 바꾼다(args·securityContext·probe 변경 없음). 병합 뒤 변경 창에서 apply → DaemonSet RollingUpdate(노드별 순차) → 3/3 Ready·`up{job=~".*node.*"}` 3/3·Collector 8개 확인. 원복은 이미지 줄을 `56566542…`로 되돌린다.

## 확인할 결과

- `version.txt`: `node_exporter, version 1.12.1-fds.1 (branch: v1.12.1, revision: 6044da783597cc3b57aef7580ddcdcff58a4ee99)`, `go version: go1.26.8`
- `build.log`의 `go version -m`: `/out/node_exporter: go1.26.8`, `dep golang.org/x/crypto v0.56.0`
- `image-config.txt`: User `65534:65534`, Entrypoint `["/bin/node_exporter"]`
- 이 빌드는 byte 단위 재현을 보장하지 않는다. 채택하는 결과물은 **Harbor digest로 최종 고정**한다.
