#!/usr/bin/env bash
# Copies stack outputs into the application repository's Actions variables.
#
# Every value the application workflow substitutes into taskdef.json is an
# output of the root stack, so there is no reason to retype any of them. Run
# this after each deploy that changes the outputs. Outputs that do not exist
# yet - the ones behind the HasImage condition, before the first image is
# pushed - are reported as skipped rather than written as empty strings,
# because an empty variable is how the workflow detects the bootstrap run.
set -euo pipefail

STACK="${1:-${PROJECT:-todo-ecs}}"
REPO="${2:-leandreAlly/todo-ecs-app}"
REGION="${AWS_REGION:-eu-north-1}"

# OutputKey:VariableName - kept as a plain list so this runs on the bash 3.2
# that ships with macOS, which has no associative arrays.
MAPPINGS='
ApplicationRoleArn:AWS_ECR_ROLE_ARN
EcrRepositoryName:ECR_REPOSITORY
ArtifactBucketName:ARTIFACT_BUCKET
TaskFamily:TASK_FAMILY
TaskExecutionRoleArn:TASK_EXEC_ROLE_ARN
TaskRoleArn:TASK_ROLE_ARN
LogGroupName:LOG_GROUP
DatabaseUrl:DB_URL
DatabaseSecretArn:DB_SECRET_ARN
RedisSecretArn:REDIS_SECRET_ARN
CacheHost:REDIS_HOST
CachePort:REDIS_PORT
'

# A stack that is still creating has no Outputs at all, and the query returns
# a bare null rather than an empty list.
outputs=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs' --output json)
if [ -z "$outputs" ] || [ "$outputs" = "null" ]; then
  outputs='[]'
fi

gh variable set AWS_REGION --repo "$REPO" --body "$REGION"
printf 'set     %-20s %s\n' AWS_REGION "$REGION"

skipped=0
while IFS=: read -r key name; do
  [ -z "$key" ] && continue
  value=$(printf '%s' "$outputs" | jq -r --arg k "$key" \
    '(. // []) | .[] | select(.OutputKey==$k) | .OutputValue // empty')
  if [ -z "$value" ]; then
    printf 'skipped %-20s (output %s not published yet)\n' "$name" "$key"
    skipped=$((skipped + 1))
    continue
  fi
  gh variable set "$name" --repo "$REPO" --body "$value"
  printf 'set     %-20s %s\n' "$name" "$value"
done <<< "$MAPPINGS"

if [ "$skipped" -gt 0 ]; then
  echo
  echo "$skipped variable(s) skipped. Set ImageTag in deployment/main.yaml so the"
  echo "platform and delivery stacks are created, then run this again."
fi
