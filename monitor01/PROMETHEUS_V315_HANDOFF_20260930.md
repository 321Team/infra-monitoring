# P1-MON-01 Prometheus v3.15.0 이미지 공급 Handoff — 2026-09-30

상태: **READY_FOR_CANDIDATE_SUPPLY / RUNTIME NOT RUN**  
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
4. 신규 receiver 후보는 공식 `prom/prometheus:v3.15.0`으로 한다. **tag는 승인값이 아니며**, upstream immutable digest와 Harbor immutable digest를 각각 기록한다.
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
  -> local image digest match
  -> promtool/config/rule precheck
  -> monitor01 receiver Runtime
```

## 3. 실행 순서

### Gate A — upstream 후보 identity 고정

기존 승인된 외부 반입 위치에서 공식 `prom/prometheus:v3.15.0`을 조회한다.

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

기존 승인된 supply path와 HBR 승인 credential을 사용한다. Secret은 명령행·로그·Git에 남기지 않는다.

대상 repository:
`10.1.93.54/fds/prometheus`

candidate tag는 식별용으로만 사용하며 최종 승인·배포는 digest를 사용한다.

필수 확인:
- Harbor Private CA 검증 유지
- `--tls-verify=false`, `-k`, insecure registry 금지
- Push 후 Harbor artifact의 **full immutable digest** 수집
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

monitor01에서:
- tar SHA256 재검증
- `podman load`
- local image digest를 승인 Harbor digest와 대조
- 실제 v3.15.0 확인
- 승인 이미지의 `promtool check config` / `check rules` 수행
- 기존 receiver/blackbox stopped container나 direct-pull 이미지를 승인 공급물로 재사용하지 않음

모든 항목 PASS 후에만 `runtime_launch_local.py`의 receiver image 인자로 **승인 Harbor digest**를 전달한다.

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
MONITOR01_LOCAL_DIGEST=sha256:<full>
DIGEST_MATCH=PASS
```

## 5. 경계

- Harbor v2.13.1 유지 결정은 현재 프로젝트 종료까지의 실행 기준이며, v2.15.2 업그레이드 완료를 의미하지 않는다.
- 이번 문서는 candidate supply/runbook이다. PR 병합만으로 Harbor mirror, Scan, tar 생성, monitor01 load 또는 Runtime 완료를 선언하지 않는다.
- v3.15.0 upstream dependency 수준은 후보 선정 근거다. 실제 Harbor Trivy 결과만 0/0 Gate를 판정한다.
- Prometheus v3.14.0 `b77f9cee...` artifact와 HIGH=3 결과는 변경 이력/회귀 비교를 위해 보존한다.
