# Local helpers. CI runs the same commands (see .gitlab-ci.yml).
REQUEST ?= requests/ubuntu-2404-base.yaml
NAME    := $(basename $(notdir $(REQUEST)))
TARGET  ?= docker

.PHONY: help validate render packer-validate build lint fmt clean portal portal-test

help:
	@echo "make validate                          validate every request"
	@echo "make render REQUEST=requests/x.yaml    render Packer/Ansible inputs into build/"
	@echo "make packer-validate REQUEST=...       packer validate for the request's targets"
	@echo "make build REQUEST=... TARGET=docker   local build (docker needs only a Docker daemon)"
	@echo "make lint                              all linters"
	@echo "make fmt                               format Packer and Terraform code"
	@echo "make portal                            regenerate Backstage templates + preview the Pages portal on :8000"
	@echo "make portal-test                       portal processor and naming-standard tests"

validate:
	python3 scripts/imagefactory.py validate

render:
	python3 scripts/imagefactory.py render $(REQUEST) --out build

packer-validate:
	IMAGE_REQUEST=$(REQUEST) python3 scripts/imagefactory.py plan --out build
	scripts/ci/packer-validate.sh

build: render
	packer init packer/linux
	packer build -only=linux.$(if $(filter aws,$(TARGET)),amazon-ebs,$(if $(filter azure,$(TARGET)),azure-arm,docker)).linux \
	  -var-file=build/$(NAME)/variables.pkrvars.json packer/linux

lint: validate
	yamllint -c .yamllint.yml .
	shellcheck scripts/ci/*.sh scripts/vm/*.sh scripts/container/*.sh scripts/bootstrap/*.sh
	packer fmt -check -recursive packer/
	terraform fmt -check -recursive terraform/
	ansible-galaxy role install -r ansible/requirements.yml -p ansible/.galaxy/roles
	cd ansible && ansible-playbook image.yml --syntax-check -i localhost,

fmt:
	packer fmt -recursive packer/
	terraform fmt -recursive terraform/

clean:
	rm -rf build .packer-tmp

portal:
	python3 scripts/portal/render.py backstage
	python3 scripts/portal/render.py pages --out portal/pages
	cd portal/pages && python3 -m http.server 8000

portal-test:
	python3 scripts/portal/test_portal.py
	python3 scripts/portal/validate_all.py
