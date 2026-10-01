#!/bin/bash
# monitor01 blackbox-exporter 소스 빌드 (ansible01, server01_ansible, rootless podman).
# 입력(소스 tar·base 이미지 digest)이 BUILD.md 값과 다르면 즉시 멈춘다. 운영 서버·Harbor는 건드리지 않는다.
# 결과는 새 작업 폴더에만 남긴다. 사용: bash build.sh   (이 파일과 Containerfile이 같은 폴더에 있어야 한다)
# HBR 인계물: 이미지 tar + 빌드 근거 묶음(build-evidence-*.tar.gz, 소스 tar 포함) + 그 sidecar(.sha256). BUILD.md "절차" 참고.
set -o pipefail

REV=065fc188bd7609e41d9e28039dc4ee2cde5d5d74
SRC_SHA=952651a8e3a9944b856e2e96c0079610f18599277b7161591331170bbd66d86e
GO_IMG=docker.io/library/golang@sha256:54b6b88db6fe375c6676625d87d668273f85c6d09153635d0cbba89cba7a207a
BASE_IMG=cgr.dev/chainguard/static@sha256:c5fed92d0fda728930795cafb61192d8abc9e2f606b22996b212e0169f1d42e6
TAG=localhost/fds/blackbox-exporter:0.28.0-master.065fc18
IMG_TAR=blackbox-exporter-065fc18.tar
EVB=build-evidence-065fc18.tar.gz
KIT=$(cd "$(dirname "$0")" && pwd)
W=$HOME/bb-build-$(date +%Y%m%dT%H%M%S)
# 빌드 근거 파일 — 모두 SHA256SUMS와 근거 묶음에 들어간다.
EVIDENCE="Containerfile build.sh kit.sha256 meta.txt bb-src.sha256 build-inputs.txt build.log version.txt image-id.txt image-config.txt result.txt"

stop(){ echo "STOP: $*" | tee -a "$W/result.txt"; exit 1; }

mkdir "$W" || { echo "STOP: 작업 폴더 생성 실패 $W"; exit 1; }
cd "$W" || exit 1
{ echo "# $(date -Is) host=$(hostname) user=$(id -un)"; podman --version; } | tee meta.txt || stop "meta 기록 실패(podman 없음?)"
cp "$KIT/Containerfile" "$KIT/build.sh" . || stop "kit 복사 실패"
sha256sum Containerfile build.sh | tee kit.sha256 || stop "kit SHA 기록 실패"

echo "== 1. 소스 tar (github.com/prometheus/blackbox_exporter@$REV)"
curl -fsSL --proto '=https' -o "bb-src-$REV.tar.gz" "https://codeload.github.com/prometheus/blackbox_exporter/tar.gz/$REV" || stop "소스 다운로드 실패"
got=$(sha256sum "bb-src-$REV.tar.gz" | cut -d' ' -f1)
echo "$got  bb-src-$REV.tar.gz" | tee bb-src.sha256
[ "$got" = "$SRC_SHA" ] || stop "소스 tar SHA 불일치 got=$got want=$SRC_SHA"
mkdir src && tar xzf "bb-src-$REV.tar.gz" -C src --strip-components=1 || stop "소스 풀기 실패"

echo "== 2. base 이미지 (digest 고정, 실제 pull digest 기록)"
for img in "$GO_IMG" "$BASE_IMG"; do
  podman pull "$img" > /dev/null || stop "pull 실패 $img"
  dg=$(podman image inspect --format '{{.Digest}}' "$img") || stop "digest 조회 실패 $img"
  [ -n "$dg" ] || stop "digest 비어 있음 $img"
  echo "$img $dg" | tee -a build-inputs.txt
done

echo "== 3. 빌드"
podman build --pull=never -f Containerfile -t "$TAG" . > build.log 2>&1
rc=$?
tail -20 build.log
[ "$rc" = 0 ] || stop "podman build rc=$rc (build.log)"

echo "== 4. 결과 확인"
podman run --rm "$TAG" --version > version.txt 2>&1 || stop "--version 실행 실패"
cat version.txt
grep -q "revision: $REV" version.txt || stop "version 출력에 revision $REV 없음"
iid=$(podman image inspect --format '{{.Id}}' "$TAG") || stop "image ID 조회 실패"
[ -n "$iid" ] || stop "image ID 비어 있음"
echo "$iid" | tee image-id.txt
podman image inspect --format '{{.Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$TAG" | tee image-config.txt || stop "image config 조회 실패"
podman save --format docker-archive -o "$IMG_TAR" "$TAG" || stop "podman save 실패"
ls -l "$IMG_TAR"

echo "== 5. 무결성 목록·빌드 근거 묶음"
echo "DONE $(date -Is) image=$IMG_TAR" | tee -a result.txt
# SHA256SUMS: 이미지 tar·소스 tar와 빌드 근거 파일 전부. 근거 묶음에는 소스 tar(실제 빌드 입력 바이트)와 SHA256SUMS를 함께 넣어,
# 근거 묶음 + 이미지 tar 두 파일만으로 `sha256sum -c SHA256SUMS`가 끝나게 한다.
sha256sum "$IMG_TAR" "bb-src-$REV.tar.gz" $EVIDENCE > SHA256SUMS || stop "SHA256SUMS 생성 실패"
cat SHA256SUMS
tar czf "$EVB" $EVIDENCE "bb-src-$REV.tar.gz" SHA256SUMS || stop "근거 묶음 생성 실패"
sha256sum "$EVB" | tee "$EVB.sha256" || stop "근거 묶음 SHA 기록 실패"
echo "HBR 인계: $W/$IMG_TAR, $W/$EVB, $W/$EVB.sha256"
