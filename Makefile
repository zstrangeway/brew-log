SHELL=/bin/bash

STAGE ?= dev

# import env variables
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

APP_NAME:=brew-log
DOMAIN:=9gatesbrewing.com

GITHUB_BRANCH:=develop
GITHUB_OWNER:=zstrangeway
GITHUB_REPO:=brew-log

FRONTEND_DOMAIN:=dev.${DOMAIN}
DISTRIBUTION_ID:=E2K1RVUJMWKW8Y

BUILD_DIR:=dist
TEMPLATE_FILE:=template.yml
OUTPUT_FILE:=${BUILD_DIR}/${TEMPLATE_FILE}

PROJECT:=${STAGE}-${APP_NAME}
PIPELINE:=${PROJECT}-pipeline

DEPLOYMENT_BUCKET:=${PROJECT}-deployment-files
ARTIFACT_BUCKET:=${PROJECT}-artifacts

FRONT_END_BUCKET:=${PROJECT}-frontend
FRONT_END_LOG_BUCKET:=${FRONT_END_BUCKET}-logs

ifeq (${STAGE}, prod)
	GITHUB_BRANCH:=master
	FRONTEND_DOMAIN:=${DOMAIN}
	DISTRIBUTION_ID:=EYQDW7GVI1JVQ
endif

.PHONY: create_deploy_bucket
create_deploy_bucket:
	# create the deployment bucket in S3 case it doesn't exist
	aws s3 mb s3://${DEPLOYMENT_BUCKET}
	aws s3api put-bucket-tagging \
		--bucket ${DEPLOYMENT_BUCKET} \
		--tagging "TagSet=[{Key=environment,Value=${STAGE}},{Key=service,Value=deployment}]"

.PHONY: build
build:
	# Build application for dev, override STAGE=prod to deploy to prod

	# Return error code 1 if value of STAGE is invalid
	if [ ${STAGE} != "dev" ] && [ ${STAGE} != "prod" ]; then \
		echo ${STAGE} is not a valid input for STAGE.; \
		exit 1; \
	fi;
	
	# make local directory for generated cloudformation templates
	rm -rf ${BUILD_DIR}
	mkdir ${BUILD_DIR}

	# compile typescript packages
	npm run build && npm run export

	# generate cloudformation templates
	sam package \
    --template-file ${TEMPLATE_FILE} \
    --output-template-file ${OUTPUT_FILE} \
    --s3-bucket ${DEPLOYMENT_BUCKET}

.PHONY: deploy
deploy:
	# Deploy cloudformation and lambdas to dev, override STAGE=prod to deploy to prod
	
	# Return error code 1 if value of STAGE is invalid
	if [ ${STAGE} != "dev" ] && [ ${STAGE} != "prod" ]; then \
		echo ${STAGE} is not a valid input for STAGE.; \
		exit 1; \
	fi;

	make build

	sam deploy \
    --template-file ${OUTPUT_FILE} \
    --stack-name ${PROJECT} \
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
    --parameter-overrides \
			Environment=${STAGE} \
			HostedZone=${DOMAIN} \
			FrontendDomainName=${FRONTEND_DOMAIN} \
			FrontendRootBucketName=${FRONT_END_BUCKET} \
			FrontendLogBucketName=${FRONT_END_LOG_BUCKET} 

	# deploy web applications to S3
	aws s3 sync \
		./${BUILD_DIR} \
		s3://${FRONT_END_BUCKET} \
		--delete \
		--cache-control max-age=31536000
	
	aws s3 cp \
		./${BUILD_DIR}/index.html \
		s3://${FRONT_END_BUCKET} \
		--cache-control max-age=0,no-cache

	aws cloudfront create-invalidation \
		--distribution-id ${DISTRIBUTION_ID} \
		--paths "/index.html" \
		--output yaml-stream \
		--profile ${PROFILE}

.PHONY: deploy-pipeline
deploy_pipeline:
	# Create CodePipeline for dev, override STAGE=prod to create for prod
	aws s3 mb s3://${ARTIFACT_BUCKET}

	aws cloudformation deploy \
		--template-file templates/cicd.template.yml \
		--capabilities CAPABILITY_NAMED_IAM \
		--stack-name ${PIPELINE} \
		--parameter-overrides \
			Environment=${STAGE} \
			TargetStack=${PROJECT} \
			GitHubOAuthToken=${GITHUB_TOKEN} \
			GitHubOwner=${GITHUB_OWNER} \
			GitHubRepo=${GITHUB_REPO} \
			GitHubBranch=${GITHUB_BRANCH} \
			DeploymentBucket=${DEPLOYMENT_BUCKET} \
			BuildArtifactsBucket=${ARTIFACT_BUCKET} \
			HostedZone=${DOMAIN} \
			FrontendDomainName=${FRONTEND_DOMAIN} \
			FrontendRootBucketName=${FRONT_END_BUCKET} \
			FrontendLogBucketName=${FRONT_END_LOG_BUCKET}
