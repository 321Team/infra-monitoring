# P1-MON-01 Prometheus v3.15.0 이미지 공급 Handoff — 2026-09-30

상태: **HBR_MIRROR_APPROVED / HARBOR_TLS_RESTORED / MIRROR RUNTIME NOT RUN**  
책임 티켓: [P1-MON-01 #17](https://github.com/321Team/fds-project-baseline/issues/17)  
실행 책임: **MON Lead 이재환 (@supreme33-kr)**  
HBR 최종 대조: **이하영 (@hayeounglee)**  
Support: 이권욱 (@GWONUK)

## 1. 적용 결정과 현재 상태

1. 프로젝트 종료까지 Harbor Runtime은 **v2.13.1로 고정**한다. 이번 P1-MON-01 이미지 공급 과정에서 Harbor v2.15.2 업그레이드는 수행하지 않는다.
2. 2026-09-30 harbor01에서 기존 v2.13.1 offline bundle로 `install.sh --with-trivy`를 적용했다.
   - 기존 Harbor 서비스: healthy
   - `trivy-adapter`: `goharbor/trivy-adapter-photon:v2.13.1`, healthy, restart 0
   - Harbor default scanner: Trivy v0.62.1 / healthy
   - 실제 `fds/prometheus` artifact scan job: SUCCESS
3. 기존 receiver 후보:
   - Harbor: `10.1.93.54/fds/prometheus@sha256:b77f9cee82fd1c61521634d2d6b192fc526ffd938e904b8e6836b6c0cf8d875a`
   - Prometheus: **v3.14.0**
   - Harbor Trivy: **CRITICAL=0 / HIGH=3**
   - 판정: **REJECTED_FOR_ICR / HOLD**. 삭제하지 않고 변경 사유 증적으로 보존하며 monitor01 공급·기동에 사용하지 않는다.
4. 신규 receiver 후보는 공식 `prom/prometheus:v3.15.0`으로 한다. **tag는 승인값이 아니며**, upstream immutable digest와 Harbor immutable digest를 각각 기록한다. 2026-09-30 HBR #13에서 HBR Lead가 **v3.15.0 신규 candidate mirror를 승인**했다. 이후 harbor01 외부 TLS Leaf의 self-signed 회귀를 복구했으며, 17:20 KST Runtime 재검증에서 `FDS Project Root CA 2026` 서명 Leaf, IP SAN `10.1.93.54`, SHA256 fingerprint `61:61:7A:F3:57:4F:37:C7:0A:2D:9C:7F:28:4A:75:F8:2C:84:4A:E3:EA:F5:99:CB:3D:0E:C6:49:12:6E:BE:AF`, TLS verify code 0, Harbor API healthy, Trivy healthy/restart 0을 확인했다. 따라서 서버 측 TLS 복구 차단은 해소됐다.
5. upstream Prometheus v3.15.0 `go.mod` 확인상 현재 v3.14.0에서 HIGH를 유발한 주요 모듈은 다음 수준으로 갱신돼 있다.
   - `golang.org/x/crypto`: v0.54.0 → **v0.56.0**
   - `google.golang.org/grpc`: v1.82.1 → **v1.83.2**
   - OpenTelemetry: v1.44.0 → **v1.46.0**
   이 사실은 **후보 선정 근거**일 뿐이며 Harbor Trivy 0/0을 대신하지 않는다.

## 2. 완료 목표

아래 체인을 하나의 이미지에 대해 끊김 없이 확보한다.

```text
official prom/prometheus:v3.15.0
  -> upstream immutable digest
  -> approved transfer path
  -> Harbor fds/prometheus candidate
  -> Harbor immutable digest
  -> Harbor Trivy CRITICAL=0 / HIGH=0
  -> HBR digest cross-check
  -> Harbor digest pull
  -> tar export + SHA256
  -> ansible01 -> monitor01
  -> podman load
  -> local image ID = approved config digest (layer diff_ids 9/9)
  -> promtool/config/rule precheck
  -> monitor01 receiver Runtime
```

## 3. 실행 순서

### Gate A — upstream 후보 identity 고정

실행 host는 **ansible01**로 고정한다. ansible01에서 공식 `prom/prometheus:v3.15.0`을 조회하고 source identity를 고정한다.

필수 기록:
- source registry/repository
- tag `v3.15.0`
- **upstream full RepoDigest**
- image ID/config digest
- `prometheus --version` 출력
- 실행 host/account/KST 시각
- 사용 명령과 RC

중단:
- full `sha256:<64hex>` digest를 확보하지 못함
- 실제 버전이 3.15.0이 아님
- source가 공식 `prom/prometheus`가 아님
- TLS 검증을 우회해야만 접근 가능

### Gate B — Harbor candidate mirror

실행 host는 **control01**로 고정한다. 기존 승인 supply path(ansible01에서 source 확보/고정 → tar 전달 → control01에서 Harbor Push)를 사용한다.

**선행 승인:** HBR #13의 @hayeounglee **Prometheus v3.15.0 신규 mirror 승인**은 완료됐고, 승인 조건이던 harbor01 **CA 서명 Leaf 복구도 2026-09-30 17:20 KST Runtime 검증 PASS**로 충족됐다. Gate B는 서버 TLS 차단이 해소됐지만, 아래 control01 CA trust 및 `latest` digest 사전검사를 통과한 뒤에만 Push한다.

HBR 승인 credential을 사용하며 Secret은 명령행·로그·Git에 남기지 않는다.

대상 repository:
`10.1.93.54/fds/prometheus`

candidate tag는 식별용으로만 사용하며 최종 승인·배포는 digest를 사용한다.

**태그 안전장치:**
- candidate에 `latest` 또는 현재 클러스터 매니페스트가 참조하는 태그를 **사용하지 않는다**.
- candidate tag 예시: `v3.15.0-candidate-20260930`.
- Push 전 Harbor `fds/prometheus:latest`의 full digest를 기록한다. 현재 기준 기대값은 `sha256:b77f9cee82fd1c61521634d2d6b192fc526ffd938e904b8e6836b6c0cf8d875a`이며, 실행 시 값이 다르면 STOP하고 최신 상태를 재대조한다.
- Push 후 `latest` full digest가 Push 전 값과 **완전 동일**한지 재확인한다. 달라졌으면 candidate 검증을 중단하고 HBR/MON에 즉시 보고한다.

**TLS/CA 선행 확인:**
- control01의 Podman/registry client가 Harbor Private CA를 신뢰하는지 먼저 확인한다. 승인된 CA 위치/설정만 사용한다.
- CA trust가 없거나 certificate verification이 실패하면 **STOP**하고 HBR에서 승인된 CA 배치 절차를 확인한다.
- `--tls-verify=false`, `-k`, insecure registry로 우회하지 않는다.

필수 확인:
- Gate B 시작 전 HBR mirror 승인 근거와 **TLS 복구 확인 근거** URL/코멘트 ID 기록
- Push 전/후 `latest` digest 불변 확인
- Push 후 Harbor candidate artifact의 **full immutable digest** 수집
- upstream digest와 Harbor digest가 다른 경우 manifest 형식/재포장 여부를 설명하고 실제 공급 artifact를 Harbor digest로 추적

### Gate C — Harbor Trivy

Harbor artifact 상세에서 정확한 신규 digest를 Scan한다.

PASS:
- scan status = success/complete
- scanner = Trivy
- **CRITICAL=0**
- **HIGH=0**

필수 증적:
- repository
- full Harbor digest
- Prometheus version
- scanner/version
- scan timestamp
- Critical/High count
- 가능하면 원본 vulnerability report/export 또는 Harbor API 응답

STOP:
- CRITICAL > 0
- HIGH > 0
- scan error / unsupported / DB error
- scan한 digest와 공급 digest 불일치
- moving tag만 식별 가능

예외/allowlist로 0/0 Gate를 우회하지 않는다.

### Gate D — HBR 최종 digest 대조

@hayeounglee가 제출된 Harbor artifact/digest와 Scan 결과를 대조해 승인 digest를 확정한다.

확정 전:
- monitor01용 tar 생성 금지
- 기존 v3.14.0 `b77f9cee...` 재사용 금지
- receiver Runtime 기동 금지

### Gate E — 승인 digest 재-pull / tar / SHA256

**확정된 Harbor digest를 다시 pull**하여 tar를 만든다. 기존 source-host local image를 그대로 export하지 않는다.

필수 산출물:
- `HARBOR_IMAGE=10.1.93.54/fds/prometheus@sha256:<approved>`
- tar filename
- tar size
- tar SHA256
- 생성 host/account/KST 시각
- pull/export 명령과 RC

전달:
`Harbor digest pull -> tar -> ansible01 -> monitor01 -> podman load`

각 hop에서 SHA256을 검증하고 값이 하나라도 다르면 STOP한다.

### Gate F — monitor01 load 및 Runtime 전 precheck

동일성 기준은 **config 동일성 체인(A안)** 이다([#17 MON Lead 결정 5924380025](https://github.com/321Team/fds-project-baseline/issues/17#issuecomment-5924380025)).

```text
승인 Harbor manifest digest -> config.digest -> docker-archive config -> monitor01 로컬 이미지 ID
```

docker-archive로 저장·로드하면 local RepoDigest가 새로 계산된다(v3.15.0 실측 `b3526e4e…`). 이 값은 **전송 과정의 local 값으로 기록만** 하고 동일성 판정에 쓰지 않는다.

monitor01에서:
- tar SHA256 재검증
- `podman load`
- **layer 대조(읽기 전용):** archive의 layer tar SHA256이 config `rootfs.diff_ids`와 전부 일치(v3.15.0은 9/9)
- `runtime_launch_local.py verify-image --image <승인 Harbor digest> --config-digest <예상 config digest>` → `IMAGE_IDENTITY_MATCH`
  - 실행기는 `podman image inspect <config digest hex>`의 `Id`가 예상 config digest와 정확히 같을 때만 통과한다. 미적재·불일치면 STOP하고 pull을 시도하지 않는다.
- 실제 v3.15.0 확인
- 승인 이미지의 `promtool check config` / `check rules` 수행
- 기존 receiver/blackbox stopped container나 direct-pull 이미지를 승인 공급물로 재사용하지 않음

모든 항목 PASS 후에만 `runtime_launch_local.py start`에 **승인 Harbor digest와 예상 config digest를 함께** 전달한다. 실행기는 위와 같은 대조를 다시 한 뒤 **그 이미지 ID로 `--pull=never`** 기동하고, 불일치면 컨테이너를 만들지 않고 STOP한다. Harbor digest 참조로 직접 `podman run`하지 않는다(로컬에 그 RepoDigest가 없어 pull을 시도하고, monitor01에는 Harbor 경로가 없다).

같은 기준을 blackbox(`start`의 `--blackbox-*` 인자)와 nginx(기동 전 `verify-image`)에도 적용한다. 클러스터 Prometheus는 Harbor에서 직접 pull하므로 해당하지 않는다.

## 4. 기록해야 할 최종 인계값

```text
COMPONENT=receiver-prometheus
VERSION=3.15.0
UPSTREAM_IMAGE=prom/prometheus@sha256:<full>
HARBOR_IMAGE=10.1.93.54/fds/prometheus@sha256:<full>
SCANNER=Trivy
TRIVY_VERSION=<actual>
SCAN_TIMESTAMP_KST=<actual>
TRIVY_CRITICAL=0
TRIVY_HIGH=0
TAR_FILE=<actual>
TAR_SHA256=<64hex>
EXPECTED_CONFIG_DIGEST=sha256:<full>
MONITOR01_LOCAL_IMAGE_ID=sha256:<full>
MONITOR01_LOCAL_REPODIGEST=<transfer-local, 기록만>
LAYER_DIFF_ID_MATCH=<n>/<n>
IMAGE_IDENTITY_MATCH=PASS
```

## 5. 경계

- 2026-09-30 HBR #13에서 Prometheus v3.15.0 신규 mirror는 승인됐고, 조건이던 harbor01 승인 CA 서명 Leaf 복구/TLS 재검증은 17:20 KST PASS했다. 이는 실제 v3.15.0 mirror/scan 완료를 의미하지 않는다.
- Harbor v2.13.1 유지 결정은 현재 프로젝트 종료까지의 실행 기준이며, v2.15.2 업그레이드 완료를 의미하지 않는다.
- 이번 문서는 candidate supply/runbook이다. PR 병합만으로 Harbor mirror, Scan, tar 생성, monitor01 load 또는 Runtime 완료를 선언하지 않는다.
- v3.15.0 upstream dependency 수준은 후보 선정 근거다. 실제 Harbor Trivy 결과만 0/0 Gate를 판정한다.
- Prometheus v3.14.0 `b77f9cee...` artifact와 HIGH=3 결과는 변경 이력/회귀 비교를 위해 보존한다.
