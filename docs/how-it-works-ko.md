# 이 프로젝트가 동작하는 방식

이 문서는 무엇을 설정했고, 왜 그렇게 설정했으며, 실제 변경이 어떤 순서로
AWS에 전달되는지를 설명한다. 명령어 암기보다 각 통제의 목적을 이해하는 것이 목표다.

## 1. 해결하려는 문제

여러 엔지니어가 같은 운영 데이터베이스를 직접 변경하면 다음 문제가 생긴다.

- 두 사람이 동시에 Terraform을 실행해 state를 덮어쓸 수 있다.
- 리뷰하지 않은 변경이 운영 DB에 바로 적용될 수 있다.
- 검토한 plan과 실제 적용한 내용이 달라질 수 있다.
- 개인 AWS access key가 GitHub에 장기간 저장될 수 있다.
- 업그레이드 실패 후 무엇을 되돌려야 하는지 불분명해질 수 있다.

이 프로젝트는 이를 다음 흐름으로 통제한다.

```text
코드 변경
→ PR 검사
→ 읽기 전용 PlanRole로 plan 생성
→ reviewer가 production 배포 승인
→ 제한된 ApplyRole로 승인된 동일 plan 적용
→ 사후 검증
```

Terraform은 DB 트랜잭션처럼 전체 작업의 원자적 rollback을 보장하지 않는다.
따라서 state lock 외에도 업그레이드 전 검사, Blue/Green, 수치 기반 gate와 사후
검증을 별도로 둔다.

## 2. 세 개의 Terraform 스택

### `bootstrap/`

Terraform state를 보관할 S3 bucket을 만든다.

- versioning: 잘못 변경된 state의 이전 버전을 복구한다.
- encryption: 저장된 state를 암호화한다.
- public access block: 인터넷 공개를 방지한다.
- TLS-only policy: 암호화되지 않은 전송을 거부한다.

state bucket을 `rds-upgrade/`와 분리한 이유는 DB 스택이 고장 나거나 삭제돼도
state 저장소는 독립적으로 남아야 하기 때문이다.

### `ci-iam/`

GitHub Actions가 사용할 역할과 신뢰 관계를 만든다.

| 역할 | 목적 | 운영 변경 권한 |
|---|---|---|
| `TerraformPlanRole` | PR 및 main에서 현재 상태를 읽고 plan 생성 | 없음 |
| `TerraformApplyRole` | 승인 후 필요한 리소스 변경 | 제한적으로 있음 |
| `TerraformStateAdminRole` | 예외적인 state 복구 | break-glass 용도 |

### `rds-upgrade/`

VPC, Aurora PostgreSQL, parameter group, 모니터링, private workload runner와
관측성 리소스를 관리한다.

## 3. S3 remote state와 lock

Terraform state는 “코드가 어떤 실제 AWS 리소스를 관리하는지” 기록한다. 이 파일이
각 노트북에 따로 있으면 같은 리소스를 서로 다르게 인식하므로 하나의 암호화된 S3
object를 공동 state로 사용한다.

`use_lockfile = true`이면 변경 작업 전에 S3에 `.tflock` object를 만든다.

```text
Runner A가 lock 획득
→ Runner B의 동시 변경 거부
→ Runner A 종료 후 lock 해제
```

실제로 GitHub runner가 lock을 보유하는 동안 로컬 `terraform untaint`가
`PreconditionFailed`로 차단됐다. `force-unlock`으로 우회하지 않고 runner가 정상
해제할 때까지 기다렸다. 이것은 state 동시성 보호의 실제 증거다.

lock은 state 동시 쓰기를 막지만 AWS API 호출 전체를 rollback해 주지는 않는다.

## 4. GitHub OIDC와 AWS 역할

GitHub에는 장기 AWS access key를 저장하지 않는다. Workflow 실행 시 GitHub가 짧은
수명의 OIDC token을 발급하고, AWS STS가 claim을 확인한 뒤 역할의 임시 자격증명을
발급한다.

```text
GitHub workflow
→ OIDC token
→ AWS trust policy 검증
→ 짧은 수명의 PlanRole 또는 ApplyRole 자격증명
```

trust policy는 저장소 이름뿐 아니라 GitHub owner ID와 repository ID가 포함된
immutable subject를 사용한다. 저장소 이름이 삭제된 후 다른 사람에게 재사용돼도
동일 역할을 탈취하기 어렵게 하기 위해서다.

PlanRole은 AWS 상태와 Terraform state를 읽을 수 있지만 운영 리소스를 변경할 수
없다. ApplyRole은 필요한 서비스만 변경하며 `iam:PassRole`도 정해진 workload와
모니터링 역할에만 허용된다.

## 5. PR plan과 production apply

PR workflow는 다음 검사를 실행한다.

1. Gitleaks secret scan
2. Terraform format 및 validate
3. TFLint
4. Checkov
5. 읽기 전용 PlanRole로 Terraform plan
6. plan을 PR과 artifact로 게시

main workflow는 binary saved plan을 만들고 commit SHA와 plan SHA-256을 기록한다.
승인 job은 같은 artifact를 내려받아 두 SHA를 검증한 뒤 그 파일을 그대로 적용한다.
승인 후 새 plan을 다시 만들지 않으므로 “검토한 plan”과 “적용한 plan”이 일치한다.

`production` Environment에 Required reviewer가 없으면 Environment 이름만으로는 승인
대기가 생기지 않는다. 이 프로젝트는 다른 GitHub 계정을 reviewer로 지정하고
가능하면 self-review와 administrator bypass를 차단하는 것을 전제로 한다.

## 6. GitHub Variables와 Secret

Repository Variables는 비민감 구성값이다.

| 이름 | 의미 |
|---|---|
| `AWS_TERRAFORM_PLAN_ROLE_ARN` | PlanRole 위치 |
| `AWS_TERRAFORM_APPLY_ROLE_ARN` | ApplyRole 위치 |
| `TF_STATE_BUCKET` | remote state bucket 이름 |
| `ENABLE_DATABASE` | DB 리소스를 plan에 포함할지 결정 |
| `UPGRADE_COMPLETE` | 현재 production이 PostgreSQL 16인지 결정 |

`ENABLE_DATABASE`나 `UPGRADE_COMPLETE`가 잘못되면 삭제 또는 downgrade처럼 보이는
plan이 만들어질 수 있다. apply 전에 plan을 검토해야 하는 이유다.

`EXTERNAL_MASTER_SECRET_ARN`은 Repository Secret으로 저장한다. 이것은 비밀번호가
아니라 Secrets Manager secret의 위치다. 실제 `SecretString`은 GitHub나 Terraform이
읽지 않는다. private workload runner만 필요한 순간 `GetSecretValue`를 수행한다.

CI는 `manage_master_user_password=false`를 강제한다. 값이 누락됐을 때 AWS 관리형
비밀번호로 되돌아가는 위험한 기본 동작 대신, external secret ARN이 없으면
precondition에서 실패하도록 fail-closed로 설계했다.

## 7. Blue/Green과 비밀번호 관리

초기 Aurora baseline은 RDS-managed master password로 만들 수 있다. 그러나 이
credential mode는 Aurora Blue/Green Deployment와 호환되지 않는다. 그래서
Blue/Green 생성 전에 한 번만 다음 전환을 수행했다.

```text
RDS-managed password
→ 독립 Secrets Manager secret 생성
→ live cluster password 변경
→ private runner에서 SELECT 1로 검증
→ Terraform에는 ARN만 전달
```

비밀번호 값은 Terraform variable, plan, state 또는 로그에 전달하지 않는다.

## 8. PostgreSQL 업그레이드 검증

업그레이드 전에 다음을 검사한다.

- 지원되는 15.10 → 16.8 경로
- 최근 snapshot과 backup retention
- `rds.logical_replication`
- PK 또는 `REPLICA IDENTITY FULL`
- invalid index
- publication, subscription, logical slot
- replica/always trigger
- extension 호환성
- 실행 중 DDL과 장기 transaction
- large object와 unlogged table

Blue와 Green의 SQL 비교에는 버전별 `queryid`를 직접 연결하지 않는다. 정규화된 SQL
텍스트를 hashing한 fingerprint로 대응시키고, 실행계획 JSON은 휘발성 시간·비용·
worker 필드를 제거하고 key를 정렬한 뒤 hash를 비교한다.

사용자 체감 지연시간은 p50/p95/p99로 별도 측정하며, DB 내부 통계와 외부 지연시간을
서로 다른 증거로 유지한다.

## 9. 관측성과 보안 통제

현재 설계에 포함된 통제는 다음과 같다.

- DB security group: 승인된 PostgreSQL ingress만 허용, 명시적 전체 egress 없음
- default security group: ingress와 egress 모두 제거
- PostgreSQL logging: 1초 이상 쿼리, DDL, 접속/종료, lock wait
- VPC Flow Logs: 전체 트래픽, 60초 집계, CloudWatch Logs
- CloudWatch Logs: 고객 관리 KMS 키 암호화, 365일 보존
- Performance Insights: 고객 관리 KMS 키로 암호화
- Enhanced Monitoring: 60초 간격, 전용 IAM 역할
- IAM DB Authentication: 활성화 대상으로 관리

`log_statement=all`은 모든 SQL과 literal을 로그에 남겨 비용과 민감정보 노출을
증가시키므로 사용하지 않는다. DDL 감사와 느린 쿼리 분석을 분리하는 현재 설정을
의도적으로 선택했다.

## 10. Checkov 예외의 의미

Checkov 예외는 검사를 끈 것이 아니라 해당 리소스 옆에 기술적 이유를 남긴 것이다.

- 기존 Aurora storage key는 in-place로 CMK 전환할 수 없어 snapshot restore 기반
  migration으로 별도 처리한다.
- minor version은 재현 가능한 성능 비교를 위해 고정하고 별도 PR로 적용한다.
- KMS key policy의 `Resource = "*"`는 이 key policy가 연결된 단일 키를 의미하는
  AWS KMS 문법이다.
- Query Logging은 조건부로 선택되는 versioned parameter group에 구현돼 있어
  scanner가 관계를 해석하지 못한다.
- AWS Backup plan과 실제 restore/RTO 측정은 아직 별도 DR 단계다.

예외는 “통과한 통제”로 과장하지 않고 scanner limitation 또는 향후 과제로 구분한다.

## 11. `tainted`가 발생한 이유

Terraform이 IAM 역할 생성에는 성공했지만 생성 직후 역할을 다시 읽을 권한이 없어
작업이 실패했다. Terraform은 리소스가 완전한지 확신할 수 없어 state에 `tainted`
표시를 남겼다.

```text
tainted = 다음 apply에서 삭제 후 재생성하라는 state 표시
```

AWS 역할 자체의 trust와 설정이 코드와 일치하는 것을 먼저 확인한 다음
`terraform untaint`로 표시만 제거했다. 그 결과 plan이 `2 destroy`에서
`0 destroy`로 바뀌었다. 확인 없이 untaint하거나 역할을 강제 삭제하면 안 된다.

## 12. 실패한 apply에서 배운 점

merge 당시 saved plan에는 tainted 역할 두 개의 교체가 포함돼 있었다. 이후 taint를
제거해 remote state가 변경됐으므로 이전 binary plan은 더 이상 현재 state와 일치하지
않는다. 해당 workflow의 apply는 실패했고, 사후 state와 AWS를 조회해 역할 교체와 DB
변경이 일어나지 않았음을 확인한 뒤 새 plan을 만들었다.

이 사례가 보여주는 통제는 다음과 같다.

- merge 가능 여부와 안전한 plan은 같은 의미가 아니다.
- GitHub check가 실패한 상태에서는 merge하지 않는다.
- plan 숫자뿐 아니라 replacement 대상과 민감한 attribute 변경도 읽는다.
- saved plan 이후 state가 바뀌면 plan을 새로 만든다.
- live lock을 `force-unlock`하지 않는다.

## 13. 현재 상태와 남은 작업

2026-08-04 기준으로 확인된 안전한 plan은 다음과 같다.

```text
3 to add, 2 to change, 0 to destroy
```

남은 생성:

- VPC Flow Log
- Flow Logs IAM inline policy
- Enhanced Monitoring 관리형 정책 attachment

남은 in-place 변경:

- IAM DB Authentication 활성화
- Performance Insights와 Enhanced Monitoring 활성화

완료 조건:

1. `production` Environment에 실제 다른 reviewer 등록
2. 새 workflow에서 `0 to destroy` 확인
3. reviewer 승인
4. 동일 saved plan apply 성공
5. AWS에서 Flow Logs, PI, Enhanced Monitoring, IAM DB Authentication 확인
6. 사후 Terraform plan이 `No changes`인지 확인

AWS Backup plan, restore test, 측정된 RTO/RPO, reader failover는 후속 DR/HA 단계이며
현재 완료됐다고 주장하지 않는다.
