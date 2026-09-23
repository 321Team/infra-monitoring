# #75 Secret 수명주기 초안 기술 검토 — 2026-09-24

상태: **검토 보완 제안 / Runtime NOT RUN / Lead 결정 대기**. 책임 [#75](https://github.com/321Team/fds-project-baseline/issues/75) Lead 이하영, Support 이재환 및 [#74](https://github.com/321Team/fds-project-baseline/issues/74) 서비스 인수 책임을 유지한다. AI 보조 기술 검토이며 사람의 독립 승인이나 운영 회전 실행 기록이 아니다.

## 기존 진행을 유지

[#75 실전송 보고](https://github.com/321Team/fds-project-baseline/issues/75#issuecomment-5776714563)는 9/22 NetworkPolicy·Secret mount·http_config.proxy_url 반영과 Discord 도착, 합성 rule 원복을 기록한다. [회전/폐기 초안](https://github.com/321Team/fds-project-baseline/issues/75#issuecomment-5776718228)도 이미 존재한다. 새 구축/시험으로 재기록하지 않는다.

조회한 infra-monitoring main `a885cef2358682214095590baf69b77062978778`은 `screen-only`, Alertmanager `latest`, Discord mount 없음이다. 이는 보고된 현장 구성과 소스 차이이며 승인된 현장을 main으로 되돌릴 근거가 아니다. [PR5](https://github.com/321Team/infra-monitoring/pull/5)는 NP만 다루는 Draft이고 현장 config/deployment 전체를 형상화한 PR이 아니다. 현재 imageID/digest·mount 및 CM byte hash를 `ops/mon-followup`으로 수집해 기존 MON Lead의 형상화 작업에 연결한다.

## 재시작 필요 여부의 소스 근거

보고 버전 Alertmanager v0.34.1의 release tag를 commit `73c6bfe7393929211294c1954f30d8ed78e4d0ad`로 확인했다. [Discord Notifier.Notify](https://github.com/prometheus/alertmanager/blob/73c6bfe7393929211294c1954f30d8ed78e4d0ad/notify/discord/discord.go)는 inline WebhookURL이 없을 때 **알림을 보낼 때마다 `os.ReadFile(WebhookURLFile)`**을 호출하고 공백을 제거한 URL을 사용한다. `http_config`는 Discord notifier의 HTTP client 생성에 사용된다.

이는 설정 파일 inotify 감시와 별개다. “Secret 교체는 무조건 rollout restart”로 일반화하지 않는다. 실제 배포 digest/바이너리가 이 버전인지, 실제 로드 receiver가 해당 file 경로인지 먼저 확인한다. 보고된 버전만으로 현재 바이너리 일치를 단정하지 않는다.

[Kubernetes Secret 문서](https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-files-from-a-pod)는 일반 볼륨의 갱신이 비동기적으로 전파되고 `subPath` mount는 자동 갱신되지 않는다고 명시한다. immutable Secret은 같은 객체 data 갱신이 불가능하다. 전파 지연이 있으므로 API 갱신 직후 새 값 사용을 즉시 PASS로 표시하지 않는다.

| 현장 입력 | 후속 판단 |
|---|---|
| v0.34.1 동작 확인 + 일반 Secret volume + 동일 file 경로 | 파일 전파가 확인된 뒤 다음 알림에서 새 URL을 읽을 것으로 판단. Secret 값 교체만으로 전체 Pod 재시작을 기본 요구하지 않음 |
| subPath / env 값 / 시작 시 별도 copy | 자동 전파를 가정하지 않음. 기존 배포 방식에 맞춘 재생성/통합 변경을 Lead가 준비 |
| immutable 또는 Secret 이름/file 경로/receiver 구조 변경 | 단순 값 교체와 다른 변경. source 형상화·parser 확인·영향/복구를 포함한 기존 리뷰 절차 적용 |
| 실제 버전·mount·loaded config 불명 | 재시작으로 추정을 덮지 않고 누락 입력만 확인 |

## 초안 보완 제안

1. **정기 회전과 유출 대응을 구분한다.** 정기 회전은 새 Webhook 준비 → 기존 권한의 Secret 전달 경로로 갱신 → mount 전파/허용 경로/새 endpoint 도착 확인 → 구 Webhook 폐기 순서를 제안한다. 구 Webhook 유지 시간은 Lead가 제한한다. 유출 의심 시는 구 Webhook 즉시 폐기를 우선하고 알림 공백과 대체 감시를 기록한다. 유출된 credential로 복구하지 않는다.
2. **URL을 명령 인자에 넣지 않는다.** 초안의 `--from-literal` 복사·붙여넣기는 실제 URL이 shell history/process argument/녹화에 남을 수 있다. 기존 승인된 Secret 주입 수단을 사용하거나 실행자 전용 파일/보호된 입력 경로를 선택한다. 실제 값·Secret YAML/base64·환경 전체·웹훅 URL을 Git, 티켓, 압축, 채팅에 싣지 않는다. 새 권한/저장소를 만드는 제안은 아니다.
3. **검증은 알림의 실제 도착까지다.** API 갱신 시각, Secret 이름·resourceVersion, Pod UID/imageID, mount 방식, 승인 채널의 알림 식별자/시각, 복구·구 Webhook 폐기 시각을 비밀값 없이 남긴다. 파일 전파 확인이 필요하면 해당 권한 내 현지 비교 결과만 출력하고 credential 원문을 반환하지 않는다. 현재 수집기는 Secret API/파일을 읽지 않으며 이 검증을 수행하지 않는다.
4. **기존 합성 rule을 재사용하되 별도 실행창에서 진행한다.** 회전 전후 bounded 시험과 rule 원복, 전송 중복/누락 여부를 확인한다. 이번 PR은 알림을 발송하지 않는다. 준비 실패 시 기존 정상 경로를 유지하며, 구 credential가 폐기/유출된 후에는 이를 되살리는 rollback을 하지 않는다.
5. **폐기는 외부 credential부터 무효화한다.** 이후 receiver/route·mount 참조를 검토된 소스에서 제거하고 남은 참조가 없을 때 Secret을 폐기한다. Alertmanager 전용 proxy allow를 제거할지는 해당 트래픽 필요성과 #74 Lead 판단으로 정한다. default-deny/DNS/다른 workload 정책을 함께 삭제하지 않는다. receiver 경로 제거를 검증하고 정상 화면 수신 등 잔존 기능을 확인한다.

## 아직 수용되지 않은 사항

- 현재 deploy의 승인 digest, readOnly/subPath/Secret 참조, 실제 loaded Discord file 경로. 수집 CM hash만으로 loaded config를 대신하지 않는다.
- #74 실제 client-source 근거·proxy 인증 요구·서비스 인수와 #75 `http_config` 정합성. 단순 `proxy_url` 문자열 존재는 인증/허용 정책 충족 증거가 아니다.
- Discord만 허용하는 예외에 대한 정식 Decision/D-ID 처리 및 담당 Lead 인수. 기존 구두 승인 보고를 지우거나 새 결정 완료로 승격하지 않는다.
- 회전·폐기 실제 실행/검증은 미수행. 기존 담당·AC·일정을 변경하지 않는다.

일반 절차 설명만 추가했고 배포 manifest·Secret·NetworkPolicy는 변경하지 않았다. 새 실행 로직/manifest가 필요하면 해당 소스 PR로 검토한다.
