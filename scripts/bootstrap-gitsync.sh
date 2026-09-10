#!/usr/bin/env bash
# Creates the IAM role CloudFormation Git sync assumes for this project.
#
# Git sync cannot deploy this stack, because the role has to exist before a
# sync configuration can be created. Run it once, with credentials that can
# create IAM roles, then pick the role it prints when you create each sync
# configuration in the CloudFormation console.
set -euo pipefail

PROJECT="${PROJECT:-todo-ecs}"
REGION="${AWS_REGION:-eu-north-1}"
STACK="${PROJECT}-gitsync-role"

cd "$(dirname "$0")/.."

aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file templates/gitsync-role.yaml \
  --parameter-overrides "ProjectName=${PROJECT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --tags "project=${PROJECT}" 'layer=bootstrap'

aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`GitSyncRoleArn`].OutputValue' \
  --output text
