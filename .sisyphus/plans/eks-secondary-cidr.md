# EKS Automode Secondary CIDR NodeClass 설정

## TL;DR

> **Quick Summary**: EKS Automode의 `default` NodeClass 자동 롤백 문제를 해결하기 위해, `custom` NodeClass에 Secondary CIDR 설정(`podSubnetSelectorTerms` + `podSecurityGroupSelectorTerms`)을 추가하고, 모든 NodePool을 `custom` NodeClass를 참조하도록 변경한다. Built-in `general-purpose` NodePool도 비활성화한다.
>
> **Deliverables**:
> - `custom` NodeClass에 pod networking 설정 추가 (podSubnetSelectorTerms, podSecurityGroupSelectorTerms)
> - 3개 NodePool (default, gpu, neuron)의 nodeClassRef를 `custom`으로 변경
> - `compute_config.node_pools = []`로 built-in NodePool 비활성화
> - `pod_subnet_ids`, `pod_security_group_ids` 변수 추가 (모듈 + 루트)
>
> **Estimated Effort**: Quick
> **Parallel Execution**: YES - 2 waves
> **Critical Path**: Task 1 → Task 3 → Task 4 → F1-F4

---

## Context

### Original Request
EKS Automode에서 `default` NodeClass를 수동 수정하여 Secondary IP(podSubnetSelectorTerms, podSecurityGroupSelectorTerms)를 설정하면, 일정 시간 후 EKS 컨트롤러가 자동 롤백하여 설정이 원복되는 문제.

### Interview Summary
**Key Discussions**:
- `default` NodeClass는 EKS Automode가 관리하는 리소스로 수동 수정 불가
- 해결: `custom` NodeClass에 pod networking 설정을 Terraform으로 관리
- 대상: 전체 NodePool (default, gpu, neuron)
- 목적: VPC Secondary CIDR 서브넷의 IP를 Pod에 할당
- 변수화: 서브넷 ID / 보안그룹 ID를 variable로 주입
- 기존 custom NodePool은 유지

**Research Findings**:
- `compute_config.node_pools = ["general-purpose"]`가 AWS 관리형 built-in NodePool을 생성하며, 이는 항상 `default` NodeClass를 사용 → 비활성화 필요
- AWS API는 `podSubnetSelectorTerms`와 `podSecurityGroupSelectorTerms`를 반드시 함께 지정해야 함
- `kubectl_manifest`(alekc/kubectl)는 apiVersion+kind+name이 동일하면 in-place 업데이트 수행
- custom NodeClass는 EKS 컨트롤러의 reconcile 대상이 아님 (안전)

### Metis Review
**Identified Gaps** (addressed):
- Built-in `general-purpose` NodePool이 `default` NodeClass를 계속 사용하는 문제 → `node_pools = []`로 비활성화
- `podSubnetSelectorTerms`와 `podSecurityGroupSelectorTerms` 필수 쌍 → 항상 함께 생성
- 동적 리스트 interpolation → `%{ for ... }` 템플릿 디렉티브 사용
- 변수 validation → non-empty list 검증 추가
- ephemeralStorage 500Gi가 모든 워크로드에 적절한지 → 현재값 유지 (가장 단순)
- 기존 노드의 점진적 마이그레이션 → 수용 (기존 노드는 336h/14일 만료까지 Primary CIDR 사용)

---

## Work Objectives

### Core Objective
EKS Automode에서 Pod networking이 Secondary CIDR를 사용하도록 Terraform으로 영속적으로 관리되는 설정을 구성한다.

### Concrete Deliverables
- `modules/eks-auto-mode/eks-addons.tf`: custom NodeClass에 pod networking 추가, 3개 NodePool의 nodeClassRef 변경
- `modules/eks-auto-mode/eks.tf`: compute_config의 node_pools를 빈 리스트로 변경
- `modules/eks-auto-mode/variables.tf`: pod_subnet_ids, pod_security_group_ids 변수 추가
- `variables.tf` (root): 동일 변수 추가
- `eks.tf` (root): 모듈 호출에 새 변수 전달

### Definition of Done
- [ ] `terraform validate` 성공
- [ ] `terraform fmt -check -recursive` exit code 0
- [ ] `terraform plan`에서 정확히 5개 리소스 변경 (nodeclass 1 + nodepool 3 + eks module 1)
- [ ] `nodeClassRef: name: default`가 eks-addons.tf에 0회 등장 (모두 custom으로 변경)

### Must Have
- `podSubnetSelectorTerms`와 `podSecurityGroupSelectorTerms`가 항상 함께 존재
- 변수 validation: 빈 리스트 방지
- `%{ for ... }` 템플릿으로 동적 서브넷/SG ID 리스트 생성
- `compute_config.node_pools = []`로 built-in NodePool 비활성화
- 기존 `karpenter_nodepool_custom`의 taint 보존

### Must NOT Have (Guardrails)
- `default` NodeClass 수정 금지 (EKS 관리 리소스)
- 추가 NodeClass 리소스 생성 금지 (기존 `custom` 하나로 충분)
- `karpenter_nodepool_custom` 수정 금지 (이미 custom NodeClass 참조 중, taint 보존)
- disruption 설정, instance type, capacity type, taint 변경 금지 (NodePool 기능 변경 아님)
- VPC CNI 설정이나 ENIConfig 리소스 추가 금지 (EKS Automode가 관리)
- EFS, ALB/Ingress, StorageClass, Pod Identity 리소스 변경 금지

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: NO (Terraform 인프라 코드 — 단위 테스트 없음)
- **Automated tests**: None (Terraform validate/plan이 검증 수단)
- **Framework**: N/A

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Terraform validation**: Use Bash — `terraform validate`, `terraform fmt`, `terraform plan`
- **Content verification**: Use Grep — YAML 내용 검증, 변수 존재 확인
- **Structural verification**: Use Read — 파일 구조 및 interpolation 패턴 확인

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — foundation):
├── Task 1: 변수 추가 (module + root + wiring) [quick]
├── Task 2: Built-in NodePool 비활성화 (compute_config 변경) [quick]

Wave 2 (After Wave 1 — core changes):
├── Task 3: Custom NodeClass에 pod networking 설정 추가 [quick]
├── Task 4: 전체 NodePool의 nodeClassRef를 custom으로 변경 [quick]

Wave FINAL (After ALL tasks):
├── F1: Plan compliance audit (oracle)
├── F2: Code quality review (unspecified-high)
├── F3: Real manual QA (unspecified-high)
└── F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay
```

### Dependency Matrix

| Task | Depends On | Blocks |
|------|-----------|--------|
| 1 | — | 3 |
| 2 | — | — |
| 3 | 1 | 4 |
| 4 | 3 | F1-F4 |
| F1-F4 | 4 | — |

### Agent Dispatch Summary

- **Wave 1**: 2 tasks — T1 → `quick`, T2 → `quick`
- **Wave 2**: 2 tasks — T3 → `quick`, T4 → `quick`
- **FINAL**: 4 tasks — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] 1. Pod networking 변수 추가 (module + root + wiring)

  **What to do**:
  - `modules/eks-auto-mode/variables.tf`에 2개 변수 추가:
    ```hcl
    variable "pod_subnet_ids" {
      type = list(string)
      validation {
        condition     = length(var.pod_subnet_ids) > 0
        error_message = "At least one pod subnet ID is required."
      }
    }
    variable "pod_security_group_ids" {
      type = list(string)
      validation {
        condition     = length(var.pod_security_group_ids) > 0
        error_message = "At least one pod security group ID is required."
      }
    }
    ```
  - Root `variables.tf`에 동일한 2개 변수 추가 (같은 type + validation)
  - Root `eks.tf`의 module "eks_auto_mode" 블록에 2개 변수 전달 추가:
    ```hcl
    pod_subnet_ids         = var.pod_subnet_ids
    pod_security_group_ids = var.pod_security_group_ids
    ```

  **Must NOT do**:
  - default 값 설정 금지 (필수 변수)
  - 다른 변수 수정 금지

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 3개 파일에 변수 정의/전달만 추가하는 단순 작업
  - **Skills**: []
    - No specialized skills needed — standard Terraform variable wiring

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 2)
  - **Blocks**: Task 3
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - `modules/eks-auto-mode/variables.tf:1-10` — 기존 변수 정의 패턴 (type = list(string) 등)
  - `variables.tf:29-36` — Root 레벨 list(string) 변수 패턴 (`gpu_nodepool_capacity_type`, `gpu_nodepool_instance_family`)
  - `eks.tf:12-13` — Module 호출에서 변수 전달 패턴 (`gpu_nodepool_capacity_type = var.gpu_nodepool_capacity_type`)

  **WHY Each Reference Matters**:
  - `variables.tf` 패턴을 따라야 기존 코드와 일관성 유지 (naming convention, type declaration style)
  - Root `eks.tf`의 module 블록에 정확한 위치와 들여쓰기로 추가해야 함

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 변수가 올바르게 정의되었는지 확인
    Tool: Grep
    Preconditions: Task 1 완료
    Steps:
      1. Grep `modules/eks-auto-mode/variables.tf` for `pod_subnet_ids` → 1 match
      2. Grep `modules/eks-auto-mode/variables.tf` for `pod_security_group_ids` → 1 match
      3. Grep `variables.tf` (root) for `pod_subnet_ids` → 1 match
      4. Grep `variables.tf` (root) for `pod_security_group_ids` → 1 match
      5. Grep `eks.tf` (root) for `pod_subnet_ids` → 1 match
      6. Grep `eks.tf` (root) for `pod_security_group_ids` → 1 match
    Expected Result: 각 파일에서 정확히 1회씩 등장
    Failure Indicators: 변수가 누락되거나 중복 정의
    Evidence: .sisyphus/evidence/task-1-variables-defined.txt

  Scenario: validation 블록이 존재하는지 확인
    Tool: Grep
    Preconditions: Task 1 완료
    Steps:
      1. Grep `modules/eks-auto-mode/variables.tf` for `length(var.pod_subnet_ids)` → 1 match
      2. Grep `modules/eks-auto-mode/variables.tf` for `length(var.pod_security_group_ids)` → 1 match
      3. Grep `variables.tf` (root) for same patterns → 1 match each
    Expected Result: 4개 validation 조건 모두 존재
    Failure Indicators: validation 블록 누락
    Evidence: .sisyphus/evidence/task-1-validation-blocks.txt
  ```

  **Commit**: YES (groups with Task 2)
  - Message: `feat(eks): add pod networking variables and disable built-in nodepool`
  - Files: `modules/eks-auto-mode/variables.tf`, `variables.tf`, `eks.tf`
  - Pre-commit: `terraform fmt -check -recursive`

- [ ] 2. Built-in general-purpose NodePool 비활성화

  **What to do**:
  - `modules/eks-auto-mode/eks.tf` 의 `compute_config` 블록 변경:
    ```hcl
    compute_config = {
      enabled    = true
      node_pools = []
    }
    ```
  - 기존 `node_pools = ["general-purpose"]` → `node_pools = []`

  **Must NOT do**:
  - `compute_config.enabled`를 false로 변경하면 안 됨 (Automode 자체는 유지)
  - eks.tf의 다른 설정 (name, version, vpc, subnet 등) 변경 금지

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 한 파일에서 한 줄 변경하는 극히 단순한 작업
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 1)
  - **Blocks**: None (독립적)
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - `modules/eks-auto-mode/eks.tf:18-21` — 현재 compute_config 블록 (변경 대상)

  **External References**:
  - AWS EKS Automode 문서: compute_config.node_pools를 빈 배열로 설정하면 AWS 관리형 NodePool이 비활성화됨

  **WHY Each Reference Matters**:
  - 정확한 위치(18-21행)를 알아야 올바른 줄을 수정 가능
  - `enabled = true`는 반드시 유지해야 EKS Automode(ALB, EBS CSI 등)가 계속 동작

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: compute_config에서 node_pools가 빈 배열인지 확인
    Tool: Grep
    Preconditions: Task 2 완료
    Steps:
      1. Grep `modules/eks-auto-mode/eks.tf` for `node_pools` → content shows `[]`
      2. Grep `modules/eks-auto-mode/eks.tf` for `general-purpose` → 0 matches
      3. Grep `modules/eks-auto-mode/eks.tf` for `enabled.*=.*true` → 1 match (compute_config.enabled 유지)
    Expected Result: node_pools = [], general-purpose 제거, enabled = true 유지
    Failure Indicators: general-purpose가 남아있거나, enabled이 false로 변경됨
    Evidence: .sisyphus/evidence/task-2-compute-config.txt

  Scenario: eks.tf의 다른 설정이 변경되지 않았는지 확인
    Tool: Read
    Preconditions: Task 2 완료
    Steps:
      1. Read `modules/eks-auto-mode/eks.tf` lines 1-22
      2. Verify name, kubernetes_version, endpoint_*, authentication_mode, vpc_id, subnet_ids, enable_cluster_creator_admin_permissions are unchanged
    Expected Result: compute_config의 node_pools만 변경, 나머지 동일
    Failure Indicators: compute_config 이외의 설정이 변경됨
    Evidence: .sisyphus/evidence/task-2-no-side-effects.txt
  ```

  **Commit**: YES (groups with Task 1)
  - Message: `feat(eks): add pod networking variables and disable built-in nodepool`
  - Files: `modules/eks-auto-mode/eks.tf`
  - Pre-commit: `terraform fmt -check -recursive`

- [ ] 3. Custom NodeClass에 podSubnetSelectorTerms + podSecurityGroupSelectorTerms 추가

  **What to do**:
  - `modules/eks-auto-mode/eks-addons.tf`의 `karpenter_nodeclass_custom` 리소스(149-168행) 수정
  - `spec.ephemeralStorage` 이후에 `podSubnetSelectorTerms`와 `podSecurityGroupSelectorTerms` 추가
  - `%{ for ... }` 템플릿 디렉티브를 사용하여 동적 ID 리스트 생성:
    ```yaml
    spec:
      subnetSelectorTerms:
        - tags:
            Name: "${module.eks.cluster_name}-private-*"
      securityGroupSelectorTerms:
        - tags:
            "aws:eks:cluster-name": ${module.eks.cluster_name}
      role: ${module.eks.node_iam_role_name}
      ephemeralStorage:
        size: 500Gi
      podSubnetSelectorTerms:
    %{ for id in var.pod_subnet_ids ~}
        - id: ${id}
    %{ endfor ~}
      podSecurityGroupSelectorTerms:
    %{ for id in var.pod_security_group_ids ~}
        - id: ${id}
    %{ endfor ~}
    ```
  - **중요**: `podSubnetSelectorTerms`와 `podSecurityGroupSelectorTerms`는 반드시 함께 존재해야 함 (AWS API 요구사항)

  **Must NOT do**:
  - 기존 `subnetSelectorTerms`, `securityGroupSelectorTerms`, `role`, `ephemeralStorage` 변경 금지
  - `karpenter_nodepool_custom` 수정 금지
  - 다른 리소스 (NodePool, ALB, EFS 등) 수정 금지

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 한 리소스의 YAML heredoc에 필드 추가하는 작업
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 4
  - **Blocked By**: Task 1 (변수가 먼저 정의되어야 interpolation 가능)

  **References**:

  **Pattern References**:
  - `modules/eks-auto-mode/eks-addons.tf:149-168` — 현재 custom NodeClass 리소스 (수정 대상)
  - `modules/eks-auto-mode/eks-addons.tf:74-82` — `%{ for }` 대신 `join()` 사용 예시 (참고용이나 여기서는 `%{ for }` 패턴 사용)

  **API/Type References**:
  - EKS Automode NodeClass API (`eks.amazonaws.com/v1`): `podSubnetSelectorTerms`는 `- id: subnet-xxx` 형식의 배열
  - `podSecurityGroupSelectorTerms`도 동일한 `- id: sg-xxx` 형식

  **WHY Each Reference Matters**:
  - 149-168행의 기존 구조를 정확히 이해해야 `ephemeralStorage` 뒤에 올바르게 삽입 가능
  - YAML indentation(2-space)을 기존 패턴과 맞춰야 Kubernetes API가 파싱 가능

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: podSubnetSelectorTerms가 custom NodeClass에 존재하는지 확인
    Tool: Grep
    Preconditions: Task 3 완료
    Steps:
      1. Grep `modules/eks-auto-mode/eks-addons.tf` for `podSubnetSelectorTerms` → exactly 1 match
      2. Grep `modules/eks-auto-mode/eks-addons.tf` for `podSecurityGroupSelectorTerms` → exactly 1 match
      3. Grep `modules/eks-auto-mode/eks-addons.tf` for `pod_subnet_ids` → exactly 1 match (in for loop)
      4. Grep `modules/eks-auto-mode/eks-addons.tf` for `pod_security_group_ids` → exactly 1 match (in for loop)
    Expected Result: 각 패턴이 정확히 1회 등장
    Failure Indicators: 패턴 누락 또는 중복
    Evidence: .sisyphus/evidence/task-3-pod-networking-added.txt

  Scenario: 기존 NodeClass 필드가 보존되었는지 확인
    Tool: Read
    Preconditions: Task 3 완료
    Steps:
      1. Read `karpenter_nodeclass_custom` resource in eks-addons.tf
      2. Verify `subnetSelectorTerms` with tag `Name: "${module.eks.cluster_name}-private-*"` exists
      3. Verify `securityGroupSelectorTerms` with tag `aws:eks:cluster-name` exists
      4. Verify `role: ${module.eks.node_iam_role_name}` exists
      5. Verify `ephemeralStorage: size: 500Gi` exists
      6. Verify `depends_on = [module.eks]` exists
    Expected Result: 모든 기존 필드가 원본과 동일
    Failure Indicators: 기존 필드가 변경되거나 누락
    Evidence: .sisyphus/evidence/task-3-existing-fields-preserved.txt

  Scenario: %{ for } 템플릿이 올바른 YAML을 생성하는지 구조 확인
    Tool: Read
    Preconditions: Task 3 완료
    Steps:
      1. Read the podSubnetSelectorTerms section
      2. Verify `%{ for id in var.pod_subnet_ids ~}` pattern exists
      3. Verify `- id: ${id}` pattern exists inside the loop
      4. Verify `%{ endfor ~}` closes the loop
      5. Same verification for podSecurityGroupSelectorTerms
    Expected Result: 두 필드 모두 올바른 for-loop 구조
    Failure Indicators: 잘못된 들여쓰기, 누락된 endfor, 또는 잘못된 변수 참조
    Evidence: .sisyphus/evidence/task-3-template-structure.txt
  ```

  **Commit**: YES (groups with Task 4)
  - Message: `feat(eks): configure secondary CIDR on custom nodeclass and switch nodepools`
  - Files: `modules/eks-auto-mode/eks-addons.tf`
  - Pre-commit: `terraform fmt -check -recursive`

- [ ] 4. 전체 NodePool의 nodeClassRef를 default → custom으로 변경

  **What to do**:
  - `modules/eks-auto-mode/eks-addons.tf`에서 3개 NodePool의 `nodeClassRef.name` 변경:
    - `karpenter_nodepool_default` (2-44행): `name: default` → `name: custom`
    - `karpenter_nodepool_gpu` (46-97행): `name: default` → `name: custom`
    - `karpenter_nodepool_neuron` (99-147행): `name: default` → `name: custom`
  - 각 NodePool의 `nodeClassRef` 블록에서 `name` 필드만 변경:
    ```yaml
    nodeClassRef:
      group: eks.amazonaws.com
      kind: NodeClass
      name: custom    # was: default
    ```

  **Must NOT do**:
  - `group`, `kind` 필드 변경 금지 (eks.amazonaws.com, NodeClass 유지)
  - NodePool의 다른 설정 변경 금지 (requirements, disruption, taints, limits, weight 등)
  - `karpenter_nodepool_custom` 수정 금지 (이미 `name: custom` 참조 중)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 한 파일에서 3곳의 동일한 패턴을 변경하는 단순 반복 작업
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 2 (after Task 3)
  - **Blocks**: F1-F4
  - **Blocked By**: Task 3 (NodeClass에 pod networking이 추가된 후 전환해야 함)

  **References**:

  **Pattern References**:
  - `modules/eks-auto-mode/eks-addons.tf:20-23` — default NodePool의 nodeClassRef (변경 대상 1)
  - `modules/eks-auto-mode/eks-addons.tf:69-72` — gpu NodePool의 nodeClassRef (변경 대상 2)
  - `modules/eks-auto-mode/eks-addons.tf:123-125` — neuron NodePool의 nodeClassRef (변경 대상 3)
  - `modules/eks-auto-mode/eks-addons.tf:192-194` — custom NodePool의 nodeClassRef (참고 — 이미 `name: custom`)

  **WHY Each Reference Matters**:
  - 정확한 행 번호를 알아야 올바른 위치의 `name: default`만 변경 가능
  - custom NodePool의 참조를 확인하여 동일한 패턴을 따르도록 보장
  - 각 NodePool의 `nodeClassRef` 블록은 동일한 구조이므로 일관된 변경 가능

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: nodeClassRef: name: default가 완전히 제거되었는지 확인
    Tool: Grep
    Preconditions: Task 4 완료
    Steps:
      1. Grep `modules/eks-auto-mode/eks-addons.tf` for `name: default` (in nodeClassRef context)
         → 0 matches (모든 NodePool에서 default 참조 제거)
      2. Grep for exact pattern `name: custom` → 4 matches (default, gpu, neuron, custom pools)
    Expected Result: default 참조 0회, custom 참조 4회
    Failure Indicators: name: default가 남아있거나, custom 참조가 4개 미만
    Evidence: .sisyphus/evidence/task-4-nodeclass-refs.txt

  Scenario: NodePool의 다른 설정이 변경되지 않았는지 확인
    Tool: Grep
    Preconditions: Task 4 완료
    Steps:
      1. Grep for `weight: 100` → 1 match (default pool)
      2. Grep for `nvidia.com/gpu` taint → 1 match (gpu pool)
      3. Grep for `aws.amazon.com/neuron` taint → 1 match (neuron pool)
      4. Grep for `karpenter.sh/nodepool.*custom` taint → 1 match (custom pool)
      5. Grep for `spot.*on-demand` capacity values → matches preserved
    Expected Result: 모든 기존 설정이 원본과 동일
    Failure Indicators: taint, weight, capacity type 등이 변경됨
    Evidence: .sisyphus/evidence/task-4-no-side-effects.txt

  Scenario: karpenter_nodepool_custom이 수정되지 않았는지 확인
    Tool: Read
    Preconditions: Task 4 완료
    Steps:
      1. Read `karpenter_nodepool_custom` resource (lines 170-213)
      2. Compare with original: nodeClassRef name: custom, taint karpenter.sh/nodepool=custom:NoSchedule
      3. Verify no changes from original
    Expected Result: custom NodePool은 완전히 원본 상태 유지
    Failure Indicators: custom NodePool에 어떤 변경이든 있음
    Evidence: .sisyphus/evidence/task-4-custom-pool-preserved.txt
  ```

  **Commit**: YES (groups with Task 3)
  - Message: `feat(eks): configure secondary CIDR on custom nodeclass and switch nodepools`
  - Files: `modules/eks-auto-mode/eks-addons.tf`
  - Pre-commit: `terraform fmt -check -recursive`

---

## Final Verification Wave

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (grep for podSubnetSelectorTerms, podSecurityGroupSelectorTerms, node_pools = [], validation blocks). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `terraform fmt -check -recursive` + `terraform validate`. Review all changed files for: hardcoded values that should be variables, inconsistent naming, missing validation blocks, YAML indentation errors, interpolation syntax issues. Check for scope creep: any changes outside eks-addons.tf, eks.tf, variables.tf.
  Output: `Format [PASS/FAIL] | Validate [PASS/FAIL] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Verify YAML content integrity: Read each modified resource's yaml_body and validate structure manually. Confirm `%{ for ... }` template directives generate correct YAML for sample inputs (e.g., 3 subnet IDs). Verify nodeClassRef: name is `custom` in all 4 NodePools. Verify `podSubnetSelectorTerms` and `podSecurityGroupSelectorTerms` both exist in custom NodeClass.
  Output: `YAML [VALID/INVALID] | NodeClassRef [4/4] | Pod networking [PASS/FAIL] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git diff). Verify 1:1 — everything in spec was built, nothing beyond spec was built. Check "Must NOT do" compliance: no changes to karpenter_nodepool_custom, no changes to EFS/ALB/StorageClass/Pod Identity resources, no additional NodeClass resources. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

| Commit | Message | Files | Pre-commit |
|--------|---------|-------|-----------|
| 1 | `feat(eks): add pod networking variables and disable built-in nodepool` | `modules/eks-auto-mode/variables.tf`, `variables.tf`, `eks.tf`, `modules/eks-auto-mode/eks.tf` | `terraform validate` |
| 2 | `feat(eks): configure secondary CIDR on custom nodeclass and switch nodepools` | `modules/eks-auto-mode/eks-addons.tf` | `terraform validate` + grep verification |

---

## Success Criteria

### Verification Commands
```bash
terraform fmt -check -recursive  # Expected: exit code 0
terraform validate               # Expected: Success! The configuration is valid.
```

### Final Checklist
- [ ] `podSubnetSelectorTerms` + `podSecurityGroupSelectorTerms` present in custom NodeClass
- [ ] All 4 NodePools reference `nodeClassRef: name: custom`
- [ ] `nodeClassRef: name: default` appears 0 times in eks-addons.tf
- [ ] `compute_config.node_pools` is `[]`
- [ ] `pod_subnet_ids` / `pod_security_group_ids` variables exist at both levels with validation
- [ ] `karpenter_nodepool_custom` taint preserved unchanged
- [ ] No changes to EFS, ALB, StorageClass, Pod Identity resources
