MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:

# include makefiles
export SELF ?= $(MAKE)
PROJECT_PATH ?= $(shell pwd)
include $(PROJECT_PATH)/Makefile.*

# main
export UNAME_S ?= $(shell uname -s)

export AWS_PROFILE ?= unknown
export AWS_DEFAULT_REGION ?= us-west-2
export REPO_NAME := $(shell basename ${PWD})

DOCKER_IMAGE ?= hansohn/terraform-aws
DOCKER_TAG   ?= latest
DOCKER_PULL  ?= always

DOCKER_ARGS ?=
DOCKER_ARGS += --interactive
DOCKER_ARGS += --tty
DOCKER_ARGS += --rm
DOCKER_ARGS += --env AWS_PROFILE --env AWS_DEFAULT_REGION
DOCKER_ARGS += --env REPO_NAME
DOCKER_ARGS += --workdir /app
DOCKER_ARGS += --volume ${PWD}:/app
DOCKER_ARGS += --volume ${HOME}/.aws:/root/.aws
DOCKER_ARGS += --volume ${HOME}/.ssh/known_hosts:/root/.ssh/known_hosts
DOCKER_ARGS += --volume ${HOME}/.gitconfig:/root/.gitconfig:ro
DOCKER_ARGS += --pull $(DOCKER_PULL)

SSH_AUTH_SOCK_MAGIC_PATH := /run/host-services/ssh-auth.sock
ifeq ($(UNAME_S),Darwin)
DOCKER_ARGS += --env SSH_AUTH_SOCK=$(SSH_AUTH_SOCK_MAGIC_PATH)
DOCKER_ARGS += --volume $(SSH_AUTH_SOCK_MAGIC_PATH):$(SSH_AUTH_SOCK_MAGIC_PATH)
endif


#-------------------------------------------------------------------------------
# dev
#-------------------------------------------------------------------------------

## Run local dev env
dev: ENTRYPOINT ?= bash

dev:
	docker run \
		$(DOCKER_ARGS) \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		$(ENTRYPOINT)

.PHONY: dev

#-------------------------------------------------------------------------------
# lint
#-------------------------------------------------------------------------------

## Lint YAML files
lint/yaml:
	@command -v yamllint > /dev/null 2>&1 || (echo "[ERROR] yamllint is not installed." && exit 1)
	@echo "[INFO] Linting YAML files in '$(REPO_NAME)'."
	@yamllint --strict .
.PHONY: lint/yaml

## Lint and audit GitHub Actions workflows
lint/actions:
	@command -v actionlint > /dev/null 2>&1 || (echo "[ERROR] actionlint is not installed." && exit 1)
	@command -v zizmor > /dev/null 2>&1 || (echo "[ERROR] zizmor is not installed." && exit 1)
	@echo "[INFO] Linting GitHub Actions workflows in '$(REPO_NAME)'."
	@actionlint
	@echo "[INFO] Auditing GitHub Actions workflows in '$(REPO_NAME)'."
	@zizmor .
.PHONY: lint/actions

## Byte-compile Lambda sources (archive_file zips a syntax error without complaint)
lint/python:
	@command -v python3 > /dev/null 2>&1 || (echo "[ERROR] python3 is not installed." && exit 1)
	@echo "[INFO] Compiling Lambda sources in '$(REPO_NAME)'."
	@python3 -m compileall -q lambda/
.PHONY: lint/python

# Directories holding a versions.tf: the module root and each example.
TF_DIRS ?= $(patsubst %/versions.tf,%,$(shell find . -name versions.tf -not -path '*/.terraform/*' | sort))

## Format-check, validate, lint and docs-check Terraform (TF_DIRS overrides the directories)
lint/terraform:
	@for tool in terraform tflint terraform-docs; do \
		command -v $$tool > /dev/null 2>&1 || { echo "[ERROR] $$tool is not installed."; exit 1; }; \
	done
	@for dir in $(TF_DIRS); do \
		echo "[INFO] Linting Terraform in '$$dir'."; \
		(cd "$$dir" && terraform fmt -check && terraform init -backend=false -input=false > /dev/null && terraform validate) || exit 1; \
		tflint --chdir="$$dir" \
			--only=terraform_comment_syntax \
			--only=terraform_deprecated_index \
			--only=terraform_deprecated_interpolation \
			--only=terraform_documented_outputs \
			--only=terraform_documented_variables \
			--only=terraform_module_pinned_source \
			--only=terraform_naming_convention \
			--only=terraform_required_providers \
			--only=terraform_required_version \
			--only=terraform_typed_variables \
			--only=terraform_workspace_remote || exit 1; \
		case "$$dir" in ./examples/*) ;; *) \
			terraform-docs --lockfile=false --output-check=true --output-file README.md --output-mode inject markdown table "$$dir" || exit 1 ;; \
		esac; \
	done
.PHONY: lint/terraform

## Run all linters
lint: lint/yaml lint/actions lint/python lint/terraform
.PHONY: lint

#-------------------------------------------------------------------------------
# test
#-------------------------------------------------------------------------------

## Run tests
test:
	@echo "[INFO] No tests defined."
.PHONY: test

## Run all linters and tests
all: lint test
.PHONY: all

#-------------------------------------------------------------------------------
# clean
#-------------------------------------------------------------------------------

CLEAN_DIRS  += .terraform
CLEAN_FILES += .terraform.lock.hcl terraform.plan
$(CLEAN_DIRS):
	find . -type d -name $@ -prune -exec rm -rf {} \;
$(CLEAN_FILES):
	find . -type f -name $@ -exec rm -f {} \;

## Clean everything
clean: $(CLEAN_DIRS) $(CLEAN_FILES)
.PHONY: clean $(CLEAN_DIRS) $(CLEAN_FILES)
