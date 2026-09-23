#!/usr/bin/env bash
# Copies stack outputs into the application repository's Actions variables and
# secrets.
#
# The application workflow only builds and pushes an image now - taskdef.json
# is committed and CodePipeline reads it from the repository - so there are
# three values left to publish rather than a dozen. Run this after a deploy
# that changes them, which in practice means after a rebuild. Outputs that do
# not exist yet are reported as skipped rather than written as empty strings.
set -euo pipefail

STACK="${1:-${PROJECT:-todo-ecs}}"
REPO="${2:-leandreAlly/todo-ecs-app}"
REGION="${AWS_REGION:-eu-north-1}"

# OutputKey:Name:Kind - kept as a plain list so this runs on the bash 3.2
# that ships with macOS, which has no associative arrays.
#
# Kind is "secret" for every role ARN and "variable" for the rest. A role ARN
# carries the account ID, and GitHub redacts a secret from the workflow log
# where it prints a variable in full.
MAPPINGS='
ApplicationRoleArn:AWS_ECR_ROLE_ARN:secret
EcrRepositoryName:ECR_REPOSITORY:variable
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
while IFS=: read -r key name kind; do
  [ -z "$key" ] && continue
  value=$(printf '%s' "$outputs" | jq -r --arg k "$key" \
    '(. // []) | .[] | select(.OutputKey==$k) | .OutputValue // empty')
  if [ -z "$value" ]; then
    printf 'skipped %-20s (output %s not published yet)\n' "$name" "$key"
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$kind" = secret ]; then
    gh secret set "$name" --repo "$REPO" --body "$value"
    printf 'set     %-20s (secret, not echoed)\n' "$name"
  else
    gh variable set "$name" --repo "$REPO" --body "$value"
    printf 'set     %-20s %s\n' "$name" "$value"
  fi
done <<< "$MAPPINGS"

if [ "$skipped" -gt 0 ]; then
  echo
  echo "$skipped value(s) skipped. Both come from the registry stack, which is"
  echo "created on the first deploy - if they are missing, the root stack has"
  echo "not finished creating yet."
fi
