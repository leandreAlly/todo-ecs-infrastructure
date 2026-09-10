# todo-ecs — infrastructure

CloudFormation for a to-do application on ECS Fargate. Writes persist to RDS
PostgreSQL **through RDS Proxy**; reads are served from ElastiCache Redis.
Everything is deployed by CloudFormation Git sync, and GitHub Actions
authenticates with OIDC — there are no long-lived AWS credentials anywhere.

Application code lives in [todo-ecs-app](https://github.com/leandreAlly/todo-ecs-app).

## Layout

| Path | Purpose |
| --- | --- |
| `templates/gitsync-role.yaml` | The IAM role Git sync assumes. Deployed by hand, once — Git sync cannot create the role it needs to exist before it can run. |
| `templates/bootstrap.yaml` | Template bucket and the OIDC role this repository's packaging workflow uses. |
| `templates/main.yaml` | Root stack. Nests every module; deploy this, never its children. |
| `templates/modules/network.yaml` | Four-tier VPC, six security groups, VPC endpoints. |
| `templates/modules/registry.yaml` | ECR repository and the OIDC role the application repository pushes with. |
| `templates/modules/data.yaml` | RDS PostgreSQL, RDS Proxy, ElastiCache Redis, generated secret. |
| `templates/modules/platform.yaml` | ALB, ECS cluster and service, target groups, autoscaling. |
| `templates/modules/delivery.yaml` | EventBridge rule, CodePipeline, CodeDeploy blue/green. |
| `deployment/*.yaml` | Git sync deployment files — one per synced stack. |
| `packaged/main.yaml` | Build artifact, committed by the packaging workflow. |
| `scripts/` | One-time bootstrap, and stack-outputs to Actions-variables sync. |

## Network design

Two availability zones, four dedicated subnet tiers, and no NAT gateway.

| Tier | CIDRs | Holds |
| --- | --- | --- |
| public | `10.0.0.0/24`, `10.0.1.0/24` | Application Load Balancer |
| app | `10.0.10.0/24`, `10.0.11.0/24` | ECS tasks, VPC endpoints |
| data | `10.0.20.0/24`, `10.0.21.0/24` | RDS instance, RDS Proxy ENIs |
| cache | `10.0.30.0/24`, `10.0.31.0/24` | ElastiCache nodes |

Each resource type gets its own security group, and every group declares its
egress inline so the implicit allow-all outbound rule is removed. The chain is
`alb-sg → task-sg → {proxy-sg, cache-sg, endpoint-sg}` and `proxy-sg → db-sg`.
The database accepts connections from the proxy only, so there is no path from
a task to the instance that skips the pool.

The private subnets reach AWS through VPC endpoints: `ecr.api`, `ecr.dkr`,
`logs` and `secretsmanager` as interface endpoints in the app subnets, and S3
as a gateway endpoint on the app route tables. The data and cache route tables
carry only the local route.

## Deploying from scratch

Prerequisites: an AWS CodeConnections connection to the GitHub account, and the
GitHub OIDC provider already present in the account (`CreateOidcProvider` is
`'false'` in `deployment/bootstrap.yaml` because IAM allows one provider per
URL per account and the sibling labs already created it).

1. **Create the Git sync role.** Run once, with credentials that can create IAM
   roles. Git sync cannot do this itself.

   ```sh
   AWS_REGION=eu-north-1 ./scripts/bootstrap-gitsync.sh
   ```

2. **Create the `todo-ecs-bootstrap` Git sync configuration** in the
   CloudFormation console, pointed at this repository, `main`, and
   `deployment/bootstrap.yaml`, using the role from step 1. It creates the
   template bucket and the packaging role.

3. **Set this repository's Actions variables** from the bootstrap outputs:
   `AWS_REGION`, `TEMPLATE_BUCKET`, `AWS_PACKAGE_ROLE_ARN`. The packaging
   workflow needs them before it can run.

4. **Let the packaging workflow run.** It lints every template, runs
   `aws cloudformation package`, and commits `packaged/main.yaml`. Git sync
   watches that file.

5. **Create the `todo-ecs` Git sync configuration**, pointed at
   `deployment/main.yaml`. With `ImageTag` empty it creates the network,
   registry and data modules only — an ECS service cannot start before an
   image exists to pull. The data tier takes 25–40 minutes because of the
   Multi-AZ instance.

6. **Publish the Actions variables the application repository needs.**

   ```sh
   AWS_REGION=eu-north-1 ./scripts/sync-app-vars.sh todo-ecs leandreAlly/todo-ecs-app
   ```

   Outputs that do not exist yet are reported as skipped. That is expected on
   this pass.

7. **Push the application.** Its workflow builds the image and pushes it to
   ECR. `ARTIFACT_BUCKET` is still unset, so it publishes the image only.

8. **Set `ImageTag`** in `deployment/main.yaml` to the short commit SHA the
   application workflow pushed, and commit. Git sync creates the platform and
   delivery modules.

9. **Run `sync-app-vars.sh` again.** Everything resolves this time. From now on
   a push to the application repository is a full blue/green deployment.

## How a deployment flows

A push to `todo-ecs-app` builds an image tagged with both the commit SHA and
`latest`, uploads `taskdef.json` and `appspec.yaml` to the artifact bucket, and
then pushes both tags. The EventBridge rule matches a push of `latest` and
starts CodePipeline, which hands the already-uploaded config to CodeDeploy.

The task definition references the **SHA** tag, not `latest`, so a rollback
returns to the image that was actually running rather than to whatever `latest`
has since become. `latest` exists only to give the EventBridge rule something
stable to match.

CodeDeploy shifts 10% of production traffic to the green target group for five
minutes before completing, so the version histogram in the UI visibly shows
both commits while the shift is in progress.

## Cost

Roughly **$150–190 per month** in `eu-north-1` if left running. The largest
line items are the four interface endpoints across two AZs (~$64), the
Multi-AZ database and its doubled storage (~$33), RDS Proxy (~$22–26), the two
cache nodes (~$26) and the ALB (~$18).

Cheapest levers, best first: set `DbMultiAZ` to `'false'` (~$19), drop the
endpoints to one AZ (~$32, at the cost of task starts in the other AZ during an
AZ failure), or set `CacheClusterCount` to `2` → single node with failover off.
Deleting the `todo-ecs` stack between sessions dominates all of them; the
bootstrap stack and ECR cost nothing to leave in place.
