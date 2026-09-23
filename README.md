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
| `templates/main.yaml` | Root stack. Nests every child stack; deploy this, never its children. |
| `templates/nested-stacks/network.yaml` | Four-tier VPC, six security groups, VPC endpoints. |
| `templates/nested-stacks/registry.yaml` | ECR repository and the OIDC role the application repository pushes with. |
| `templates/nested-stacks/data.yaml` | RDS PostgreSQL, RDS Proxy, ElastiCache Redis, generated secret. |
| `templates/nested-stacks/platform.yaml` | ALB, ECS cluster and service, target groups, autoscaling. |
| `templates/nested-stacks/delivery.yaml` | EventBridge rule, CodePipeline, CodeDeploy blue/green. |
| `deployment/*.yaml` | Git sync deployment files — one per synced stack. |
| `packaged/main.yaml` | Build artifact, committed by the packaging workflow. |
| `scripts/` | One-time bootstrap, and stack-outputs to Actions variables and secrets sync. |

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
`logs`, `secretsmanager` and `ssm` as interface endpoints in the app subnets,
and S3 as a gateway endpoint on the app route tables. The data and cache route
tables carry only the local route.

## Deploying from scratch

Prerequisites: AWS credentials for the one-time bootstrap and the GitHub OIDC
provider already present in the account (`CreateOidcProvider` is
`'false'` in `deployment/bootstrap.yaml` because IAM allows one provider per
URL per account and the sibling labs already created it).

1. **Create the Git sync role.** Run once, with credentials that can create IAM
   roles. Git sync cannot do this itself.

   ```sh
   AWS_REGION=eu-north-1 ./scripts/bootstrap-gitsync.sh
   ```

2. **Create the `todo-ecs-bootstrap` stack, then its Git sync configuration.**

   Order matters, and this is the one genuinely surprising part. A sync
   configuration created through the API only ever issues *update* change
   sets: on the first push it calls `CreateChangeSet` against a stack that
   does not exist yet and fails with `Stack [todo-ecs-bootstrap] does not
   exist`. Nothing surfaces in `get-sync-blocker-summary` — the failure is
   only visible in CloudTrail. The console's "Create stack from Git" flow
   creates the stack for you; the API does not. So create the stack once with
   the same name, parameters and tags as the deployment file, and let Git sync
   own it from then on:

   ```sh
   aws cloudformation create-stack \
     --stack-name todo-ecs-bootstrap \
     --template-body file://templates/bootstrap.yaml \
     --role-arn "$(aws cloudformation describe-stacks --stack-name todo-ecs-gitsync-role \
        --query 'Stacks[0].Outputs[?OutputKey==`GitSyncRoleArn`].OutputValue' --output text)" \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameters ParameterKey=ProjectName,ParameterValue=todo-ecs \
                  ParameterKey=GitHubOwner,ParameterValue=leandreAlly \
                  ParameterKey=InfrastructureRepo,ParameterValue=todo-ecs-infrastructure \
                  ParameterKey=GitHubOwnerId,ParameterValue=78492995 \
                  ParameterKey=CreateOidcProvider,ParameterValue=false \
                  ParameterKey=TemplateRetentionDays,ParameterValue=30 \
     --tags Key=project,Value=todo-ecs Key=layer,Value=bootstrap \
            Key=managed-by,Value=cloudformation-gitsync

   aws codeconnections create-repository-link \
     --connection-arn <your GitHub connection ARN> \
     --owner-id leandreAlly --repository-name todo-ecs-infrastructure

   aws codeconnections create-sync-configuration \
     --branch main --config-file deployment/bootstrap.yaml \
     --repository-link-id <id from the previous call> \
     --resource-name todo-ecs-bootstrap \
     --role-arn <the Git sync role> --sync-type CFN_STACK_SYNC
   ```

   Git sync also only reacts to a push that actually changes a file. An empty
   commit will not reconcile anything.

   Two more behaviours worth knowing, because neither reports anything through
   `get-sync-blocker-summary` and both look identical from the outside - the
   push lands, and nothing happens:

   - A sync configuration binds to the stack that existed when it was created.
     Delete and recreate the stack and the configuration keeps pointing at the
     old one.
   - A configuration goes dormant after a change set of its own fails, and
     does not pick up later pushes.

   In both cases the fix is the same: delete the sync configuration and create
   it again, then push a change. CloudTrail's `CreateChangeSet` events are the
   only reliable way to see what Git sync actually attempted.

3. **Set this repository's Actions values** from the bootstrap outputs:
   `AWS_REGION` and `TEMPLATE_BUCKET` as variables, `AWS_PACKAGE_ROLE_ARN` as
   a **secret** — it carries the account ID, and GitHub redacts a secret from
   the workflow log. The packaging workflow needs all three before it can run.

4. **Let the packaging workflow run.** It lints every template, runs
   `aws cloudformation package`, and commits `packaged/main.yaml`. Git sync
   watches that file.

5. **Create the `todo-ecs` stack and its sync configuration**, the same way as
   step 2 but pointed at `deployment/main.yaml`, and with
   `--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND`.
   With `ImageTag` empty it creates the network,
   registry and data nested stacks only — an ECS service cannot start before an
   image exists to pull. The data tier takes 25–40 minutes because of the
   Multi-AZ instance.

6. **Approve the GitHub connection.** The bootstrap stack created an
   `AWS::CodeStarConnections::Connection` in `PENDING`; CloudFormation cannot
   complete the handshake. Open CodePipeline → Settings → Connections, choose
   `todo-ecs-github`, click **Update pending connection** and authorise the
   GitHub app. The bootstrap stack exports the ARN for the root stack; it is
   not copied into the deployment file.

7. **Publish the Actions variables and secrets the application repository
   needs.**

   ```sh
   AWS_REGION=eu-north-1 ./scripts/sync-app-vars.sh todo-ecs leandreAlly/todo-ecs-app
   ```

   Outputs that do not exist yet are reported as skipped. That is expected on
   this pass.

8. **Push the application.** Its workflow builds the image and pushes it to
   ECR. It does nothing else — the deployment description is committed, so
   there is no bundle to publish and no ordering to get wrong.

9. **Set `ImageTag`** in `deployment/main.yaml` to the full commit SHA the
   application workflow pushed, and commit. Git sync creates the platform and
   delivery nested stacks.

10. **Pin `ServiceTaskDefinitionArn`.** Once the service is running, obtain its
    active revision with `aws ecs describe-services --cluster todo-ecs
    --services todo-ecs --query 'services[0].taskDefinition' --output text` and
    commit that ARN as the parameter value. Repeat this after CodeDeploy moves
    the service to a later revision. Until it is pinned, a template edit that
    touches the task definition makes CloudFormation try to move the service,
    and ECS rejects that on a `CODE_DEPLOY` service.

## How a deployment flows

A push to `todo-ecs-app` builds an image, pushes it under the full commit SHA,
then moves `latest`. Commit tags are immutable; only `latest` is mutable.

The EventBridge rule matches the immutable push and starts CodePipeline with
the event's image digest and tag as source revision overrides. The tag selects
the exact Git commit through CodeConnections, while the digest selects the
exact ECR image. A CodeBuild stage renders `taskdef.json` and `appspec.yaml`
with CloudFormation-provided role ARNs, parameter ARNs, full secret ARNs,
logging settings and task sizing. CodePipeline replaces `<IMAGE1_NAME>` with
the digest URI and CodeDeploy performs the blue/green deployment.

The pipeline uses queued execution, so releases cannot overtake one another.
The source overrides ensure a newer branch head or a later `latest` update
cannot change the revision already being deployed.

`DetectChanges` is `false` on the repository source, so the connection does not
register a webhook of its own. The EventBridge rule is meant to be the only
thing that starts this pipeline; after a deploy, check that nothing else picked
up the job:

```sh
aws events list-rule-names-by-target \
  --target-arn "arn:aws:codepipeline:eu-north-1:<account-id>:todo-ecs-pipeline"
```

### Why the task definition can be committed

`taskdef.json` is a portable template. CloudFormation passes the generated
values to the render project, which replaces the placeholders before the
CodeDeploy action sees the file. Endpoint values remain behind fixed SSM paths,
and credential selectors are built from the full Secrets Manager ARNs rather
than partial ARNs.

Fixed secret names cost one thing: Secrets Manager keeps a deleted secret for
up to 30 days, so rebuilding inside that window collides with the old one.
Teardown has to purge both:

```sh
for name in todo-ecs-db-credentials todo-ecs-redis-auth; do
  aws secretsmanager delete-secret --force-delete-without-recovery --secret-id "$name"
done
```

CodeDeploy shifts 10% of production traffic to the green target group for five
minutes before completing, so the version histogram in the UI visibly shows
both commits while the shift is in progress.

## Cost

The largest recurring costs are ten interface-endpoint ENIs across two AZs,
the Multi-AZ database, RDS Proxy, two Redis nodes and the ALB. CodeBuild runs
only during a deployment, and queued CodePipeline V2 executions add a small
usage-based delivery cost.

The lab requirements make the multi-AZ subnet layout, endpoints, proxy and
blue/green load balancer intentional costs. For a short-lived lab, deleting the
root stack between sessions saves far more than weakening the network design.
If resilience is not being demonstrated, `DbMultiAZ: 'false'` is the clearest
parameterized saving; Redis remains at two nodes because automatic failover is
part of this implementation.
