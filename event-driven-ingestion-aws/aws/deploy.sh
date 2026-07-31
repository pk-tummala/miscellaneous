#!/usr/bin/env bash
#==============================================================================
# deploy.sh - stand up the ENTIRE event-driven ingestion pipeline in one go.
#
# Creates (via CloudFormation): the S3 bucket with EventBridge on, all IAM roles,
# the EMR Serverless application, the Step Functions state machine, and the
# EventBridge rule. Then uploads the PySpark job. After this, you just drop a file
# into  s3://<bucket>/incoming/  and the pipeline runs.
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (aws configure) with permission to create
#     CloudFormation stacks, IAM roles, S3, EventBridge, Step Functions, EMR Serverless.
#   - Set your region below (or export AWS_REGION).
#
# Usage:   bash deploy.sh [stack-name]
# Teardown: empty the bucket, then  aws cloudformation delete-stack --stack-name <name>
#==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export AWS_PAGER=""            # AWS CLI v2 pipes output through a pager by default;
                              # disable it so this script never hangs waiting for 'q'.

STACK="${1:-carsales-event-ingest}"
REGION="${AWS_REGION:-us-east-1}"          # <-- change to your region if needed

echo "1/3  Deploying the stack '$STACK' in $REGION (creates all resources)..."
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file event-driven-ingestion.cfn.yaml \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

echo "2/3  Reading the bucket name the stack created..."
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)

echo "3/3  Uploading the PySpark job to s3://$BUCKET/code/ ..."
aws s3 cp emr_serverless_job.py "s3://$BUCKET/code/emr_serverless_job.py" --region "$REGION"

echo ""
echo "Done. Try it:"
echo "  aws s3 cp <a-listing>.json s3://$BUCKET/incoming/ --region $REGION"
echo "Then watch the run in the Step Functions console (state machine: carsales-ingest)."
echo "Output lands in s3://$BUCKET/curated/listings/."
