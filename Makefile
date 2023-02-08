# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build the node-problem-detector image.

.PHONY: all \
        vet fmt version test e2e-test \
        build-binaries build-container build-tar build \
        docker-builder build-in-docker push-container push-tar push clean

all: build

# PLATFORMS is the set of OS_ARCH that NPD can build against.
LINUX_PLATFORMS?=linux_amd64 linux_arm64
PLATFORMS=$(LINUX_PLATFORMS)
#PLATFORMS=$(LINUX_PLATFORMS) windows_amd64

# VERSION is the version of the binary.
VERSION?=$(shell if [ -d .git ]; then echo `git describe --tags --dirty`; else echo "UNKNOWN"; fi)

# TAG is the tag of the container image, default to binary version.
TAG?=$(VERSION)

# REGISTRY is the container registry to push into.
REGISTRY?=registry.cn-hangzhou.aliyuncs.com

# UPLOAD_PATH is the cloud storage path to upload release tar.
UPLOAD_PATH?=gs://kubernetes-release
# Trim the trailing '/' in the path
UPLOAD_PATH:=$(shell echo $(UPLOAD_PATH) | sed '$$s/\/*$$//')

# PKG is the package name of node problem detector repo.
PKG:=k8s.io/node-problem-detector

# PKG_SOURCES are all the go source code.
ifeq ($(OS),Windows_NT)
PKG_SOURCES:=
# TODO: File change detection does not work in Windows.
else
PKG_SOURCES:=$(shell find pkg cmd -name '*.go')
endif

# PARALLEL specifies the number of parallel test nodes to run for e2e tests.
PARALLEL?=3

NPD_NAME_VERSION?=node-problem-detector-$(VERSION)
# TARBALL is the name of release tar. Include binary version by default.
TARBALL=$(NPD_NAME_VERSION).tar.gz

# IMAGE is the image name of the node problem detector container image.
IMAGE:=$(REGISTRY)/acs/node-problem-detector:$(TAG)

# ENABLE_JOURNALD enables build journald support or not. Building journald
# support needs libsystemd-dev or libsystemd-journal-dev.
ENABLE_JOURNALD?=0

ifeq ($(go env GOHOSTOS), darwin)
ENABLE_JOURNALD=0
else ifeq ($(go env GOHOSTOS), windows)
ENABLE_JOURNALD=0
endif

# TODO(random-liu): Support different architectures.
# The debian-base:v1.0.0 image built from kubernetes repository is based on
# Debian Stretch. It includes systemd 239 with support for both +XZ and +LZ4
# compression. +LZ4 is needed on some os distros such as COS.
BASEIMAGE:=centos:centos8
BUILDER_BASE_IMAGE:=golang:1.17.1-buster

# Disable cgo by default to make the binary statically linked.
CGO_ENABLED:=0

# Construct the "-tags" parameter used by "go build".
BUILD_TAGS?=

LINUX_BUILD_TAGS = $(BUILD_TAGS)
WINDOWS_BUILD_TAGS = $(BUILD_TAGS)

ifeq ($(OS),Windows_NT)
HOST_PLATFORM_BUILD_TAGS = $(WINDOWS_BUILD_TAGS)
else
HOST_PLATFORM_BUILD_TAGS = $(LINUX_BUILD_TAGS)
endif

ifeq ($(ENABLE_JOURNALD), 1)
	# Enable journald build tag.
	LINUX_BUILD_TAGS := journald $(BUILD_TAGS)
	# Enable cgo because sdjournal needs cgo to compile. The binary will be
	# dynamically linked if CGO_ENABLED is enabled. This is fine because fedora
	# already has necessary dynamic library. We can not use `-extldflags "-static"`
	# here, because go-systemd uses dlopen, and dlopen will not work properly in a
	# statically linked application.
	CGO_ENABLED:=1
	LOGCOUNTER=./bin/log-counter
else
	# Hack: Don't copy over log-counter, use a wildcard path that shouldnt match
	# anything in COPY command.
	LOGCOUNTER=*dont-include-log-counter
endif
ifneq ($(BUILD_TAGS), "")
	BUILD_TAGS:=-tags "$(BUILD_TAGS)"
endif

vet:
	GO111MODULE=on go list -mod vendor -tags "$(HOST_PLATFORM_BUILD_TAGS)" ./... | \
		grep -v "./vendor/*" | \
		GO111MODULE=on xargs go vet -mod vendor -tags "$(HOST_PLATFORM_BUILD_TAGS)"

fmt:
	find . -type f -name "*.go" | grep -v "./vendor/*" | xargs gofmt -s -w -l

version:
	@echo $(VERSION)

BINARIES = bin/node-problem-detector bin/health-checker test/bin/problem-maker
BINARIES_LINUX_ONLY =
ifeq ($(ENABLE_JOURNALD), 1)
	BINARIES_LINUX_ONLY += bin/log-counter
endif

ALL_BINARIES = $(foreach binary, $(BINARIES) $(BINARIES_LINUX_ONLY), ./$(binary)) \
  $(foreach platform, $(LINUX_PLATFORMS), $(foreach binary, $(BINARIES) $(BINARIES_LINUX_ONLY), output/$(platform)/$(binary))) \
#  skip windows bin build
#  $(foreach binary, $(BINARIES), output/windows_amd64/$(binary).exe)
ALL_TARBALLS = $(foreach platform, $(PLATFORMS), $(NPD_NAME_VERSION)-$(platform).tar.gz)

output/windows_amd64/bin/%.exe: $(PKG_SOURCES)
	GOOS=windows GOARCH=amd64 CGO_ENABLED=$(CGO_ENABLED) GO111MODULE=on go build \
		-mod vendor \
		-o $@ \
		-ldflags '-X $(PKG)/pkg/version.version=$(VERSION)' \
		-tags "$(WINDOWS_BUILD_TAGS)" \
		./cmd/$(subst -,,$*)
	touch $@

output/windows_amd64/test/bin/%.exe: $(PKG_SOURCES)
	GOOS=windows GOARCH=amd64 CGO_ENABLED=$(CGO_ENABLED) GO111MODULE=on go build \
		-mod vendor \
		-o $@ \
		-tags "$(WINDOWS_BUILD_TAGS)" \
		./test/e2e/$(subst -,,$*)

# =x86_64-linux-gnu-gcc need yum install gcc-x86_64-linux-gnu.x86_64

output/linux_amd64/bin/%: $(PKG_SOURCES)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=$(CGO_ENABLED) GO111MODULE=on \
#	  CC=x86_64-linux-gnu-gcc go build \
	  CC=x86_64-redhat-linux-gcc go build \
		-mod vendor \
		-o $@ \
		-ldflags '-X $(PKG)/pkg/version.version=$(VERSION)' \
		-tags "$(LINUX_BUILD_TAGS)" \
		./cmd/$(subst -,,$*)
	touch $@

output/linux_amd64/test/bin/%: $(PKG_SOURCES)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=$(CGO_ENABLED) GO111MODULE=on \
#	  CC=x86_64-linux-gnu-gcc go build \
	  CC=x86_64-redhat-linux-gcc go build \
		-mod vendor \
		-o $@ \
		-tags "$(LINUX_BUILD_TAGS)" \
		./test/e2e/$(subst -,,$*)

output/linux_arm64/bin/%: $(PKG_SOURCES)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=$(CGO_ENABLED) GO111MODULE=on \
#	  CC=aarch64-linux-gnu-gcc go build \
	  CC=aarch64-redhat-linux-gcc go build \
		-mod vendor \
		-o $@ \
		-ldflags '-X $(PKG)/pkg/version.version=$(VERSION)' \
		-tags "$(LINUX_BUILD_TAGS)" \
		./cmd/$(subst -,,$*)
	touch $@

output/linux_arm64/test/bin/%: $(PKG_SOURCES)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=$(CGO_ENABLED) GO111MODULE=on \
#	  CC=aarch64-linux-gnu-gcc go build \
	  CC=aarch64-redhat-linux-gcc go build \
		-mod vendor \
		-o $@ \
		-tags "$(LINUX_BUILD_TAGS)" \
		./test/e2e/$(subst -,,$*)

# In the future these targets should be deprecated.
./bin/log-counter: $(PKG_SOURCES)
ifeq ($(ENABLE_JOURNALD), 1)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GO111MODULE=on go build \
		-mod vendor \
		-o bin/log-counter \
		-ldflags '-X $(PKG)/pkg/version.version=$(VERSION)' \
		-tags "$(LINUX_BUILD_TAGS)" \
		cmd/logcounter/log_counter.go
else
	echo "Warning: log-counter requires journald, skipping."
endif

./bin/node-problem-detector: $(PKG_SOURCES)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GO111MODULE=on go build \
		-mod vendor \
		-o bin/node-problem-detector \
		-ldflags '-X $(PKG)/pkg/version.version=$(VERSION)' \
		-tags "$(LINUX_BUILD_TAGS)" \
		./cmd/nodeproblemdetector

./test/bin/problem-maker: $(PKG_SOURCES)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GO111MODULE=on go build \
		-mod vendor \
		-o test/bin/problem-maker \
		-tags "$(LINUX_BUILD_TAGS)" \
		./test/e2e/problemmaker/problem_maker.go

./bin/health-checker: $(PKG_SOURCES)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GO111MODULE=on go build \
		-mod vendor \
		-o bin/health-checker \
		-ldflags '-X $(PKG)/pkg/version.version=$(VERSION)' \
		-tags "$(LINUX_BUILD_TAGS)" \
		cmd/healthchecker/health_checker.go

test: vet fmt
	GO111MODULE=on go test -mod vendor -timeout=1m -v -race -short -tags "$(HOST_PLATFORM_BUILD_TAGS)" ./...

e2e-test: vet fmt build-tar
	GO111MODULE=on ginkgo -nodes=$(PARALLEL) -mod vendor -timeout=10m -v -tags "$(HOST_PLATFORM_BUILD_TAGS)" -stream \
	./test/e2e/metriconly/... -- \
	-project=$(PROJECT) -zone=$(ZONE) \
	-image=$(VM_IMAGE) -image-family=$(IMAGE_FAMILY) -image-project=$(IMAGE_PROJECT) \
	-ssh-user=$(SSH_USER) -ssh-key=$(SSH_KEY) \
	-npd-build-tar=`pwd`/$(TARBALL) \
	-boskos-project-type=$(BOSKOS_PROJECT_TYPE) -job-name=$(JOB_NAME) \
	-artifacts-dir=$(ARTIFACTS)


$(NPD_NAME_VERSION)-%.tar.gz: $(ALL_BINARIES) test/e2e-install.sh
	mkdir -p output/$*/ output/$*/test/
	cp -r config/ output/$*/
	cp test/e2e-install.sh output/$*/test/e2e-install.sh
	(cd output/$*/ && tar -zcvf ../../$@ *)
	sha512sum $@ > $@.sha512

build-binaries: $(ALL_BINARIES)

build-container: build-binaries Dockerfile
	docker build -t $(IMAGE) --build-arg BASEIMAGE=$(BASEIMAGE) --build-arg LOGCOUNTER=$(LOGCOUNTER) . --progress=plain --no-cache

$(TARBALL): ./bin/node-problem-detector ./bin/log-counter ./bin/health-checker ./test/bin/problem-maker
	tar -zcvf $(TARBALL) bin/ config/ test/e2e-install.sh test/bin/problem-maker
	sha1sum $(TARBALL)
	md5sum $(TARBALL)

build-tar: $(TARBALL) $(ALL_TARBALLS)

build: build-container build-tar

docker-builder:
	docker build -t npd-builder ./builder

build-in-docker: clean docker-builder
	docker run \
		-v `pwd`:/gopath/src/k8s.io/node-problem-detector/ npd-builder:latest bash \
		-c 'cd /gopath/src/k8s.io/node-problem-detector/ && make build-binaries'

build-multi-stage: clean
	docker build -t $(IMAGE) --build-arg BASEIMAGE=$(BASEIMAGE) --build-arg LOGCOUNTER=$(LOGCOUNTER) -f Dockerfile.dind --build-arg BUILDER_BASE_IMAGE=$(BUILDER_BASE_IMAGE) .

push-container: build-container
	gcloud auth configure-docker
	docker push $(IMAGE)

push-tar: build-tar
	gsutil cp $(TARBALL) $(UPLOAD_PATH)/node-problem-detector/
	gsutil cp node-problem-detector-$(VERSION)-*.tar.gz* $(UPLOAD_PATH)/node-problem-detector/

push: push-container push-tar

coverage.out:
	rm -f coverage.out
	go test -coverprofile=coverage.out -mod vendor -timeout=1m -v -short ./...

clean:
	rm -rf bin/
	rm -rf test/bin/
	rm -f node-problem-detector-*.tar.gz*
	rm -rf output/
	rm -f coverage.out
