# 정본 대응과 저장소 책임

기준 확인: 2026-09-17 KST. 발행 정본 `docs-v3.1.18`, 승인 source `72599ae49342b0fb8dbd3d8ee60314afb9f907bb`. 이 문서는 정본을 새로 발행하거나 기술 AC를 변경하지 않는다. 승인 절차는 [2026-09-18 사용자 변경결정](https://github.com/321Team/fds-project-baseline/blob/38f682141c279807050c5b1ea1b4e2b58ee22d63/governance/REVIEW_AUTHORITY_POLICY.md)을 우선 적용한다.

| 정책 | 직접 근거 | 적용 성격 |
|---|---|---|
| Private, PR, 수동 merge, CI 미실행 표기; 독립 리뷰는 코드 병합에 한정 | [2026-09-18 Lead 위임 정책](https://github.com/321Team/fds-project-baseline/blob/38f682141c279807050c5b1ea1b4e2b58ee22d63/governance/REVIEW_AUTHORITY_POLICY.md), 기존 RELEASE_POLICY | 기존 검증 통제 유지, 독립 승인 적용 범위 개정 |
| 코드 외 실행·증적 수용·인수·종결은 해당 Lead 판단 | [2026-09-18 사용자 변경결정](https://github.com/321Team/fds-project-baseline/blob/38f682141c279807050c5b1ea1b4e2b58ee22d63/governance/REVIEW_AUTHORITY_POLICY.md); 기존 Baseline §3.4·§17의 일반적 승인 절차를 개정 | 필수 AC·시험·증적 유지, Support 별도 승인은 상시 필수 아님 |
| 기존 운영 담당과 정본 승인 역할 구분 | [Baseline §3](https://github.com/321Team/fds-project-baseline/blob/72599ae49342b0fb8dbd3d8ee60314afb9f907bb/baseline/FDS_Project_Implementation_Baseline_v3.1.18.md), [Identity Map](https://github.com/321Team/fds-project-baseline/blob/121fb744f0d816b3910a0bb07cf2bbe0d8883a16/governance/GITHUB_IDENTITY_MAP.md) | 기존 역할 유지, 권한 변경 없음 |
| 중앙 Delivery와 단순 소스 검증 분리 | [Baseline §5·§10](https://github.com/321Team/fds-project-baseline/blob/72599ae49342b0fb8dbd3d8ee60314afb9f907bb/baseline/FDS_Project_Implementation_Baseline_v3.1.18.md), [병합된 infra-cicd README/운영 기준](https://github.com/321Team/infra-cicd/blob/90f2f37d9e1ab77252b50e80bca339cfef48bd51/README.md) | Runner 접근 확대 없음 |
| 3개 저장소 이름, snapshot-copy, 폴더, 브랜치 접두어 | 이번 사용자 개설·정본 기준 정책·이관 요청 | 이번 운영 세칙, 정본의 원문 강제 사항으로 표시하지 않음 |

## 해당 저장소의 필수 경계

- 책임: P1-MON-01 [#17](https://github.com/321Team/fds-project-baseline/issues/17), D33 [#63](https://github.com/321Team/fds-project-baseline/issues/63), [Baseline §8·§11·IF-05/06](https://github.com/321Team/fds-project-baseline/blob/72599ae49342b0fb8dbd3d8ee60314afb9f907bb/baseline/FDS_Project_Implementation_Baseline_v3.1.18.md). Lead 이재환, Support 이권욱. 이하영의 보안·K8S 영향 검토를 연결한다.
- 배치: monitoring-api에 Prometheus/Alertmanager/Grafana/kube-state-metrics, monitoring-node에 node-exporter, monitor01에는 독립 Watchdog. 전체 관측을 한 장애영역에 두지 않는다.
- 노출/보안: 내부 서비스 ClusterIP, Grafana 승인 관리 단말 port-forward, 최소 읽기 RBAC·Default Deny, 이미지 승인 Digest, 기본 관리자 암호·Anonymous·Sign-up 금지. node-exporter Namespace 예외를 Container privileged=true 허용으로 해석하지 않는다.
- Storage: Prometheus/Grafana/Alertmanager PVC, static local PV·WaitForFirstConsumer·Retain. PV/Host Directory는 P1-K8S, PVC/Retention/Persistence는 P1-MON, SecurityContext/fsGroup은 P1-SEC 책임이다. 15일은 목표이며 retention.size는 PVC의 최대 80%, 단일 Worker/Replica는 Known Limitation이다.
- monitor01: HTTPS Remote Write는 승인 heartbeat/self/target-health만 허용, 전체 앱 Metric/업무 Payload/개인정보 Label 복제 금지. 전용 CA Leaf/Trust와 5분 heartbeat 장애 탐지·복구를 검증한다.
- Runtime 완료는 정본 §11.6의 14개 AC와 §11.7의 필수 보조 2항목(컴포넌트 Probe, IF-06B/IF-24 통제)을 구분하여 모두 추적한다. E-K3S 참고 파일 이관은 이 AC의 PASS가 아니다.
- 외부 Discord 알림 [#74](https://github.com/321Team/fds-project-baseline/issues/74)/[#75](https://github.com/321Team/fds-project-baseline/issues/75)는 프록시 서비스 인수 후 운영 적용한다. 정책 초안은 병행 가능하다. 이 P1 후속을 이번 소스 이관이나 전체 P0의 새 차단조건으로 확대하지 않는다.
- P1-MON-02의 HA/장기 보존과 Phase 2 관측 확장은 별도 범위다. [정본과 참고본 차이](CANONICAL_GAPS.md)를 해소한 E-CANON 구현 PR 없이는 references를 정본 배포 입력으로 사용하지 않는다.

## 이관의 판정 범위

정본 AC의 값·담당·기한·상태를 변경하지 않는다. 초기 이관은 출처·무결성·의존성·비밀정보·적용 가능한 소스 검증과 독립 검토로 판단하며, 미실행 CI/Runtime은 각각 그대로 기록한다. 상세 Gate는 [운영 정책](POLICY.md)을 따른다.
