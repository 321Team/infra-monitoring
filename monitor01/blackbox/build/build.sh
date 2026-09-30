#!/bin/bash
# monitor01 blackbox-exporter 소스 빌드 (ansible01, server01_ansible, rootless podman).
# 입력(소스 tar·base 이미지 digest)이 BUILD.md 값과 다르면 즉시 멈춘다. 운영 서버·Harbor는 건드리지 않는다.
# 결과는 새 작업 폴더에만 남긴다. 사용: bash build.sh   (이 파일과 Containerfile이 같은 폴더에 있어야 한다)
# 끝나면 blackbox-exporter-065fc18.tar 와 SHA256SUMS 를 HBR(이하영)에 넘긴다 — push·Trivy는 HBR 절차.

REV=065fc188bd7609e41d9e28039dc4ee2cde5d5d74
SRC_SHA=952651a8e3a9944b856e2e96c0079610f18599277b7161591331170bbd66d86e
GO_IMG=docker.io/library/golang@sha256:54b6b88db6fe375c6676625d87d668273f85c6d09153635d0cbba89cba7a207a
BASE_IMG=cgr.dev/chainguard/static@sha256:c5fed92d0fda728930795cafb61192d8abc9e2f606b22996b212e0169f1d42e6
TAG=localhost/fds/blackbox-exporter:0.28.0-master.065fc18
KIT=$(cd "$(dirname "$0")" && pwd)
W=$HOME/bb-build-$(date +%Y%m%dT%H%M%S)

stop(){ echo "STOP: $*" | tee -a "$W/result.txt"; exit 1; }

mkdir "$W" || { echo "STOP: 작업 폴더 생성 실패 $W"; exit 1; }
cd "$W" || exit 1
{ echo "# $(date -Is) host=$(hostname) user=$(id -un)"; podman --version; } | tee meta.txt
cp "$KIT/Containerfile" "$KIT/build.sh" . || stop "kit 복사 실패"
sha256sum Containerfile build.sh | tee kit.sha256

echo "== 1. 소스 tar (github.com/prometheus/blackbox_exporter@$REV)"
curl -fsSL --proto '=https' -o "bb-src-$REV.tar.gz" "https://codeload.github.com/prometheus/blackbox_exporter/tar.gz/$REV" || stop "소스 다운로드 실패"
got=$(sha256sum "bb-src-$REV.tar.gz" | cut -d' ' -f1)
echo "$got  bb-src-$REV.tar.gz" | tee bb-src.sha256
[ "$got" = "$SRC_SHA" ] || stop "소스 tar SHA 불일치 got=$got want=$SRC_SHA"
mkdir src && tar xzf "bb-src-$REV.tar.gz" -C src --strip-components=1 || stop "소스 풀기 실패"

echo "== 2. base 이미지 (digest 고정)"
for img in "$GO_IMG" "$BASE_IMG"; do
  podman pull "$img" > /dev/null || stop "pull 실패 $img"
  echo "$img $(podman image inspect --format '{{.Digest}}' "$img")" | tee -a build-inputs.txt
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
podman image inspect --format '{{.Id}}' "$TAG" | tee image-id.txt
podman image inspect --format '{{.Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$TAG" | tee image-config.txt
podman save --format docker-archive -o blackbox-exporter-065fc18.tar "$TAG" || stop "podman save 실패"
sha256sum blackbox-exporter-065fc18.tar "bb-src-$REV.tar.gz" Containerfile build.sh | tee SHA256SUMS
ls -l blackbox-exporter-065fc18.tar
echo "DONE dir=$W" | tee -a result.txt
