# terraform-aws-database

Creates an RDS for PostgreSQL instance, with optional read replicas in the same region and in other regions:

- **Private only:** runs in the private subnets from `terraform-aws-networking` and is never publicly accessible.
- **Credentials in Secrets Manager:** RDS generates the master password, stores it in Secrets Manager and rotates it every 7 days. The password never appears in Terraform code, plans or state.
- **Encrypted:** storage, snapshots, Performance Insights and the secret use a KMS key that the module creates. Clients must connect with SSL (`rds.force_ssl = 1`).
- **Locked-down security group:** inbound on 5432 only from the security groups and CIDRs you list, e.g. the EKS cluster from `terraform-aws-compute`.
- **Operations:** gp3 storage that grows automatically, automated backups with point-in-time recovery, automatic minor version upgrades in the maintenance window, Postgres logs in CloudWatch Logs, and Performance Insights.
- **Protection levels**: dev can be torn down, stg is hard to delete, and Terraform can't take prd down.
- **Read scaling and disaster recovery:** in-region read replicas, cross-region read replicas, and automated backups copied to another region. See [Replication and disaster recovery](#replication-and-disaster-recovery).

## Environments

There is one AWS account per environment. Each environment is one Terraform root with one state file.

| Environment | Instance | `protection` | Class | Multi-AZ | Storage | What it means |
|---|---|---|---|---|---|---|
| dev | `cluster1-dev-app` | `none` | `db.t4g.medium` | no | 20 to 100 GiB | `terraform destroy` works, with no final snapshot. |
| stg | `cluster1-stg-app` | `standard` | `db.m7g.large` | yes | 100 to 500 GiB | Deletion protection and a final snapshot. Destroying stg takes two deliberate steps. |
| prd | `cluster1-prd-app` | `strict` | `db.m7g.large` | yes | 100 to 500 GiB | Deletion protection, plus Terraform refuses any plan that would take the database down. |

stg is set up the same way as prd, except for `protection`, so changes are tested on a real copy of production.

### What each protection level blocks

| Change | `none` | `standard` | `strict` |
|---|---|---|---|
| `terraform destroy` or removing the module call | allowed, no final snapshot | fails at apply (RDS deletion protection) | **fails at plan** |
| A change that replaces the instance or its KMS key | allowed | fails at apply | **fails at plan** |
| Lowering `protection` | allowed | allowed | **fails at plan** |
| Resizing, storage, parameters, access rules, version upgrades | allowed | allowed | allowed |

`strict` works through a small `terraform_data` guard resource with `prevent_destroy` set (see [`protection.tf`](protection.tf)). Terraform can't plan to destroy it, so a bad PR shows up as a red `plan` check rather than data loss.

### Destroying stg

1. In a PR, set `protection = "none"` in `examples/cluster1/stg/main.tf`. Merge it to apply. This also turns off the final snapshot, so take a manual snapshot first if you need the data.
2. Destroy it from your machine with the stg apply role, or in a second PR that removes the module call.

With `standard`, a delete takes a final snapshot named `<name>-final`. Delete or rename that snapshot before the same instance name is deleted again.

### Decommissioning prd (break glass)

Terraform can't do this on its own, by design. In a reviewed change, someone with the prd apply role runs `terraform state rm 'module.database.terraform_data.guard[0]'`, then follows the stg steps.

## Usage

```hcl
module "database" {
  source = "git::https://github.com/<org>/terraform-aws-database.git?ref=v1.0.0"

  name       = "cluster1-prd-app"
  vpc_id     = data.aws_vpc.this.id
  subnet_ids = sort(data.aws_subnets.private.ids)
  protection = "strict"

  allowed_security_group_ids = [data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]

  engine_version = "17"
  instance_class = "db.m7g.large"
  database_name  = "app"
}
```

The module takes its region from the provider you pass it.

### Settings

| Setting | Default | Description |
|---|---|---|
| `name` | required | Instance identifier, usually `<cluster>-<environment>-<app>`. Max 50 characters. |
| `protection` | required | `none`, `standard` or `strict`. See [Environments](#environments). |
| `vpc_id` | required | VPC from `terraform-aws-networking`. |
| `subnet_ids` | required | Private subnets in at least two AZs. |
| `engine_version` | required | Postgres major version, e.g. `17`. |
| `instance_class` | required | e.g. `db.t4g.medium`, `db.m7g.large`. |
| `database_name` | required for a primary | Database created for the app. Leave unset on a cross-region replica. |
| `allowed_security_group_ids` | `[]` | Security groups allowed on 5432. |
| `allowed_cidr_blocks` | `[]` | CIDRs allowed on 5432, e.g. a VPN. `0.0.0.0/0` is rejected. |
| `multi_az` | `true` | Standby in a second AZ with automatic failover. Turn off in dev only. |
| `allocated_storage` / `max_allocated_storage` | `20` / `100` | Initial size and autoscaling ceiling, in GiB. Storage never shrinks. |
| `master_username` | `dbadmin` | The password is managed by RDS. |
| `read_replicas` | `{}` | In-region read replicas: `{ read1 = { instance_class = optional } }`. Named `<name>-<key>`. Primary only. |
| `replicate_source_db` | `null` | ARN of an instance in another region. Makes this module call a cross-region read replica. |
| `backup_replication` | `null` | `{ region = "us-west-1", retention_days = 7 }`: copy automated backups to another region. Primary only. |
| `parameters` | `{}` | Extra Postgres parameters: `{ name = { value = "...", apply_method = "immediate" \| "pending-reboot" } }`. |
| `backup_retention_days` | `14` | 1 to 35 days of point-in-time recovery. |
| `backup_window` / `maintenance_window` | `03:00-04:00` / `sun:05:00-sun:06:00` | UTC. |
| `apply_immediately` | `false` | Apply changes now instead of in the maintenance window. Some changes restart the instance. |
| `log_retention_days` | `90` | How long CloudWatch Logs keeps Postgres logs. |
| `kms_key_deletion_window_days` | `30` | Waiting period before the KMS key is deleted. |
| `tags` | `{}` | Tags on every resource. |

### Outputs

`identifier`, `arn`, `address`, `port`, `database_name`, `master_username`, `master_user_secret_arn` (null on a cross-region replica), `kms_key_arn`, `security_group_id`, `read_replica_addresses`, `read_replica_identifiers`, `backup_replication_kms_key_arn`.

## Replication and disaster recovery

One module call per region. The primary region creates the writer and, optionally, in-region read
replicas and cross-region backup copies. Each other region creates a cross-region read replica of it,
in that region's own VPC.

```hcl
# us-east-1: primary
module "database" {
  source = "git::https://github.com/<org>/terraform-aws-database.git?ref=v2.0.0"

  name           = "cluster1-prd-use1"
  # ...network, protection, engine_version, instance_class as usual
  database_name  = "app"

  read_replicas      = { read1 = {} }                                  # read traffic in this region
  backup_replication = { region = "us-west-1", retention_days = 14 }  # point-in-time restore in us-west-1
}

# us-west-1: cross-region read replica, in its own root and state
module "database" {
  source = "git::https://github.com/<org>/terraform-aws-database.git?ref=v2.0.0"

  name                = "cluster1-prd-usw1"
  # ...us-west-1 network, protection, engine_version, instance_class
  replicate_source_db = data.aws_db_instance.primary.db_instance_arn
}
```

Apply the primary region first. A replica:

- uses the source's databases and master user. The master secret stays in the primary region, so apps in
  the replica region read it from there (`master_user_secret_arn` of the primary).
- has no automated backups or final snapshot. The primary's backups, and their cross-region copies, cover
  the data.
- gets its own KMS key, subnet group, security group and parameter group in its region.
- can be read only. Point read-only clients at `read_replica_addresses` (in-region) or the replica's
  `address` (cross-region). Replication is asynchronous, so reads can lag writes slightly; alarm on the
  `ReplicaLag` metric.

**Losing the primary region:**

- **Promote the replica:** remove `replicate_source_db` and set `database_name` in that region's root,
  then apply. RDS promotes it to a standalone writer and turns on automated backups. Repoint writers to
  it. Promotion is one-way.
- **Or restore from the backup copies** to any point within `backup_replication.retention_days`, if no
  replica exists.

## Connecting the app

The app runs in the EKS cluster from `terraform-aws-compute` and reads its credentials through the External Secrets Operator.

1. **Network:** the example roots allow the EKS cluster security group, which the nodes and pods use.
2. **IAM:** in `terraform-aws-identity`, add this environment's `master_user_secret_arn` to `external_secrets.secrets_manager_arns` and `kms_key_arn` to `external_secrets.kms_key_arns`. The secret's name is generated by RDS (`rds!db-...`), so a `<cluster_name>/*` wildcard does not match it.
3. **Kubernetes:** create an `ExternalSecret` that combines the secret with the host from the outputs:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-db
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: app-db
    template:
      data:
        DATABASE_URL: "postgresql://{{ .username }}:{{ .password | urlquery }}@cluster1-dev-app.xxxx.us-east-1.rds.amazonaws.com:5432/app?sslmode=require"
  dataFrom:
    - extract:
        key: arn:aws:secretsmanager:us-east-1:111111111111:secret:rds!db-xxxx
```

The password rotates every 7 days. The app must reconnect with the new password when a login fails, or be restarted after the Kubernetes secret refreshes. Lower `refreshInterval` if you need to pick up rotations faster.

The secret holds the master user. For least privilege, create a separate app role in Postgres and store its credentials the same way.

## Upgrades

- **Minor versions** are applied automatically in the maintenance window. No change needed.
- **Major versions:** raise `engine_version` by one (e.g. `17` to `18`). The module creates a parameter group for the new family. Test in dev, then stg, then prd, in separate PRs. Check [extension compatibility](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html) first. The instance is unavailable during the upgrade.
- **Instance class and storage** changes wait for the maintenance window unless `apply_immediately = true`. In Multi-AZ, a class change fails over to the upgraded standby with a short interruption.

## The root configurations

[`examples/cluster1`](examples/cluster1) is what CI deploys. It shows the layout of a repo for one Kubernetes cluster: one folder per environment, and each folder is its own Terraform root.

```
examples/cluster1/
├── dev/
│   ├── main.tf              # backend, provider, environment values, database module call
│   ├── outputs.tf
│   └── .terraform.lock.hcl
├── stg/
│   ├── main.tf              # same as prd, with the stg account, state bucket and protection = "standard"
│   ├── outputs.tf
│   └── .terraform.lock.hcl
└── prd/
    ├── main.tf              # prd account, state bucket and protection = "strict"
    ├── outputs.tf
    └── .terraform.lock.hcl
```

Each `main.tf` has everything for its environment: the state bucket, the account ID, the provider, and the `database` module call. It finds the VPC by its `Name` tag (`cluster1-<env>`) and the private subnets by their `kubernetes.io/role/internal-elb` tag, both from `terraform-aws-networking`, and the EKS cluster security group from `terraform-aws-compute`. There are no tfvars or backend files.

`allowed_account_ids` stops Terraform from running if your credentials belong to a different account than the folder is for.

Apply the repositories in this order: `terraform-aws-networking`, `terraform-aws-compute`, this one, then `terraform-aws-identity`, which needs the secret ARN.

### Making a change

1. Edit the module, or `examples/cluster1/<env>/main.tf` for the environment you're changing.
2. Open a PR. Review the `plan` job summary for each environment. A failing prd plan that mentions `prevent_destroy` means the change would take prd down.
3. Get approval and merge. `apply` runs dev, then stg, then prd.

### Running a plan locally

Use SSO or another short-lived credential, never access keys:

```sh
cd examples/cluster1/stg
aws sso login --profile stg
export AWS_PROFILE=stg

terraform init
terraform plan -lock=false
```

Leave applies to CI.

## CI/CD

[`.github/workflows/terraform.yml`](.github/workflows/terraform.yml):

| Event | Runs |
|---|---|
| PR into `main` opened, reopened or updated with new commits | `fmt`, `validate` (with tests), then `plan` for every environment |
| Merge into `main` | `fmt`, `validate`, then `apply` one environment at a time: dev, stg, prd. Stops at the first failure. |

GitHub logs in to AWS through OIDC; the repo holds no AWS secrets. PR plans skip the state lock so they never block an apply. At merge time, apply creates a new plan rather than reusing the PR's.

### One-time setup

1. **Branch protection on `main`:** require an approved PR, and require the `fmt`, `validate` and `plan` checks to pass. This is what limits applies to approved changes.
2. **GitHub environments:** each needs the variable `AWS_ROLE_ARN`. Regions are set in each root's provider block.
   - `dev-plan`, `stg-plan`, `prd-plan`: unprotected, holding a read-only plan role.
   - `dev`, `stg`, `prd`: limited to the `main` branch, holding the apply role. Add required reviewers (at least on `prd`) if you want a manual sign-off before apply.
3. **In each AWS account:** register the IAM OIDC provider `token.actions.githubusercontent.com` (audience `sts.amazonaws.com`). Create two roles, each trusting a single GitHub environment through the `sub` claim:
   - Plan role: `repo:<org>/<repo>:environment:<env>-plan`. Read-only access plus the state bucket.
   - Apply role: `repo:<org>/<repo>:environment:<env>`. Write access to RDS, KMS (create keys and aliases, `kms:CreateGrant`), Secrets Manager (RDS creates the master user secret on your behalf), EC2 (security groups and rules) and CloudWatch Logs, plus the state bucket.

## Versions

| | Module | Root configurations (`examples/cluster1/<env>`) |
|---|---|---|
| Terraform | `>= 1.9.0, < 2.0.0` | `1.17.0` |
| AWS provider | `>= 6.0.0, < 7.0.0` | `6.70.0`, locked in each folder's `.terraform.lock.hcl` |
| PostgreSQL | any RDS major version | `17` |

Pin the module by git tag (`?ref=vX.Y.Z`).

## Testing

Offline tests use a mocked AWS provider and need no AWS access:

```sh
terraform init -backend=false
terraform test
```

## Not included

The VPC (`terraform-aws-networking`), the EKS cluster (`terraform-aws-compute`), the External Secrets IRSA role (`terraform-aws-identity`), Postgres roles and schemas inside the database, and the CI roles and GitHub OIDC provider are managed elsewhere.
