#!/bin/bash
# monitoring-node node-exporter 소스 빌드 (ansible01, server01_ansible, rootless podman).
# 입력(소스 tar·base 이미지 digest·x/crypto go.sum 줄)이 BUILD.md 값과 다르면 즉시 멈춘다. 운영 서버·Harbor는 건드리지 않는다.
# 결과는 새 작업 폴더에만 남긴다. 사용: bash build.sh   (이 파일과 Containerfile이 같은 폴더에 있어야 한다)
# 인계물: 이미지 tar + 빌드 근거 묶음(build-evidence-*.tar.gz, 소스 tar 포함) + 그 sidecar(.sha256). BUILD.md "절차" 참고.
set -o pipefail

REV=6044da783597cc3b57aef7580ddcdcff58a4ee99
SRC_SHA=cfec7478aa9bfd011f29df084584b7c7b68dfef85a24d28e9d6d5f88224f83c3
GO_IMG=docker.io/library/golang@sha256:0f063af2d465d8dcae54cce04278ada488b96f77b42449c8d071e47d016cc65a
GO_VER=go1.26.8
BASE_IMG=cgr.dev/chainguard/static@sha256:c5fed92d0fda728930795cafb61192d8abc9e2f606b22996b212e0169f1d42e6
XCRYPTO=v0.56.0
# sum.golang.org/lookup/golang.org/x/crypto@v0.56.0 (2026-10-01 조회) — go get 결과 go.sum에 이 두 줄이 그대로 있어야 한다.
XCRYPTO_SUM="golang.org/x/crypto v0.56.0 h1:GUh5Ii4J5jtcseSMiRqr1jXCNHoxjeV9Fmekc2oLy6Y="
XCRYPTO_MOD="golang.org/x/crypto v0.56.0/go.mod h1:OMW5y6CY9l38uPLmxU6l6pwcXp1obtLo3e6gT7gQR2I="
VER=1.12.1-fds.1
TAG=localhost/fds/node-exporter:$VER
IMG_TAR=node-exporter-$VER.tar
EVB=build-evidence-node-exporter-$VER.tar.gz
KIT=$(cd "$(dirname "$0")" && pwd)
W=$HOME/ne-build-$(date +%Y%m%dT%H%M%S)
# 빌드 근거 파일 — 모두 SHA256SUMS와 근거 묶음에 들어간다.
EVIDENCE="Containerfile build.sh kit.sha256 meta.txt ne-src.sha256 build-inputs.txt gomod.log gomod.diff go.mod.updated go.sum.updated build.log version.txt image-id.txt image-config.txt result.txt"

stop(){ echo "STOP: $*" | tee -a "$W/result.txt"; exit 1; }

mkdir "$W" || { echo "STOP: 작업 폴더 생성 실패 $W"; exit 1; }
cd "$W" || exit 1
{ echo "# $(date -Is) host=$(hostname) user=$(id -un)"; podman --version; } | tee meta.txt || stop "meta 기록 실패(podman 없음?)"
cp "$KIT/Containerfile" "$KIT/build.sh" . || stop "kit 복사 실패"
sha256sum Containerfile build.sh | tee kit.sha256 || stop "kit SHA 기록 실패"

echo "== 1. 소스 tar (github.com/prometheus/node_exporter@$REV = v1.12.1)"
curl -fsSL --proto '=https' -o "ne-src-$REV.tar.gz" "https://codeload.github.com/prometheus/node_exporter/tar.gz/$REV" || stop "소스 다운로드 실패"
got=$(sha256sum "ne-src-$REV.tar.gz" | cut -d' ' -f1)
echo "$got  ne-src-$REV.tar.gz" | tee ne-src.sha256
[ "$got" = "$SRC_SHA" ] || stop "소스 tar SHA 불일치 got=$got want=$SRC_SHA"
mkdir src orig && tar xzf "ne-src-$REV.tar.gz" -C src --strip-components=1 || stop "소스 풀기 실패"
cp src/go.mod src/go.sum orig/ || stop "원본 go.mod·go.sum 보관 실패"

echo "== 2. base 이미지 (digest 고정, 실제 pull digest 기록)"
for img in "$GO_IMG" "$BASE_IMG"; do
  podman pull "$img" > /dev/null || stop "pull 실패 $img"
  dg=$(podman image inspect --format '{{.Digest}}' "$img") || stop "digest 조회 실패 $img"
  [ -n "$dg" ] || stop "digest 비어 있음 $img"
  echo "$img $dg" | tee -a build-inputs.txt
done

echo "== 3. 의존성: golang.org/x/crypto $XCRYPTO (go get + tidy + verify, go.sum은 sum.golang.org로 검증)"
podman run --rm --pull=never -v "$W/src:/src:Z" -w /src -e GOTOOLCHAIN=local -e GOFLAGS=-mod=mod "$GO_IMG" \
  sh -c "go version && go get golang.org/x/crypto@$XCRYPTO && go mod tidy && go mod verify" > gomod.log 2>&1
rc=$?
cat gomod.log
[ "$rc" = 0 ] || stop "go get/tidy/verify rc=$rc (gomod.log)"
grep -q "$GO_VER" gomod.log || stop "go version이 $GO_VER 아님 (gomod.log)"
cp src/go.mod go.mod.updated && cp src/go.sum go.sum.updated || stop "갱신 go.mod·go.sum 보관 실패"
{ diff -u orig/go.mod go.mod.updated; diff -u orig/go.sum go.sum.updated; } > gomod.diff
cat gomod.diff
grep -qE "^[[:space:]]*golang.org/x/crypto $XCRYPTO( |$)" go.mod.updated || stop "go.mod에 x/crypto $XCRYPTO 없음"
grep -qxF "$XCRYPTO_SUM" go.sum.updated || stop "go.sum x/crypto 줄이 고정값과 다름"
grep -qxF "$XCRYPTO_MOD" go.sum.updated || stop "go.sum x/crypto go.mod 줄이 고정값과 다름"

echo "== 4. 빌드"
podman build --pull=never -f Containerfile -t "$TAG" . > build.log 2>&1
rc=$?
tail -40 build.log
[ "$rc" = 0 ] || stop "podman build rc=$rc (build.log)"
grep -qE "dep[[:space:]]+golang.org/x/crypto[[:space:]]+$XCRYPTO" build.log || stop "바이너리 buildinfo에 x/crypto $XCRYPTO 없음 (build.log)"
grep -qF "/out/node_exporter: $GO_VER" build.log || stop "바이너리 buildinfo의 Go가 $GO_VER 아님 (build.log)"

echo "== 5. 결과 확인"
podman run --rm "$TAG" --version > version.txt 2>&1 || stop "--version 실행 실패"
cat version.txt
grep -q "revision: $REV" version.txt || stop "version 출력에 revision $REV 없음"
grep -q "$GO_VER" version.txt || stop "version 출력에 $GO_VER 없음"
iid=$(podman image inspect --format '{{.Id}}' "$TAG") || stop "image ID 조회 실패"
[ -n "$iid" ] || stop "image ID 비어 있음"
echo "$iid" | tee image-id.txt
podman image inspect --format '{{.Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$TAG" | tee image-config.txt || stop "image config 조회 실패"
podman save --format docker-archive -o "$IMG_TAR" "$TAG" || stop "podman save 실패"
ls -l "$IMG_TAR"

echo "== 6. 무결성 목록·빌드 근거 묶음"
echo "DONE $(date -Is) image=$IMG_TAR" | tee -a result.txt
# SHA256SUMS: 이미지 tar·소스 tar와 빌드 근거 파일 전부. 근거 묶음에는 소스 tar(실제 빌드 입력 바이트)와 SHA256SUMS를 함께 넣어,
# 근거 묶음 + 이미지 tar 두 파일만으로 `sha256sum -c SHA256SUMS`가 끝나게 한다.
sha256sum "$IMG_TAR" "ne-src-$REV.tar.gz" $EVIDENCE > SHA256SUMS || stop "SHA256SUMS 생성 실패"
cat SHA256SUMS
tar czf "$EVB" $EVIDENCE "ne-src-$REV.tar.gz" SHA256SUMS || stop "근거 묶음 생성 실패"
sha256sum "$EVB" | tee "$EVB.sha256" || stop "근거 묶음 SHA 기록 실패"
echo "인계: $W/$IMG_TAR, $W/$EVB, $W/$EVB.sha256"
