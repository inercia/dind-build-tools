# Description

Tools for running stuff (ie, builds, tests...) in a DinD container.

So, for example, when you do something like `make dind/build`, this will:

* build the Docker image (fomr a specific `Dockerfile`).
* start the DinD container, mounting all your code in the container,
  and leave it running in the background.
* `docker exec` a `make build` in the DinD container.

Some important features:

* a DinD container can call `docker build` and it will work (as there is a Docker daemon
  running inside the DinD container), so you should be able to run `make build` as well
  as `make dind/build` and get the same result.
* it is easy to reproduce the same build environment you have in Jenkins:
  the `Jenkinsfile` will invoke `make ci/something` and it will run everything
  inside a Docker container, and you can do the same locally with no changes.
* it keeps running in the background and only restart the container is the
  image changes or the mounts change.

## Usage

First, add in your project with something like:

```bash
git submodule add https://github.com/inercia/dind-build-tools hack/dind
```

Then create some customized copies of `dind.cfg` and `Dockerfile` for
creating a suitable environment for your build.

Modify your Makefile for having some targets like these:

```Makefile
TOP_DIR          = <your top directory>

DIND_CFG         = dind.cfg
DIND_DOCKERFILE  = Dockerfile.ci
DIND_ARGS        = --config $(DIND_CFG) --dockerfile $(DIND_DOCKERFILE)

build:
    # this builds your software
    echo "Building..."
    
cleanup-ci:
	@echo "Nothing to do"

# NOTE: CI can only start jobs from this section

ci/cleanup: dind/cleanup-ci
	$(Q)$(TOP_DIR)/hack/dind/dind.sh --delete $(DIND_ARGS)
.PHONY: ci/cleanup

# any other ci/something target is translated to dind/something
ci/%::
	$(Q)make dind/$*

# any dind/something target is run in the DinD container
dind/%::
	$(Q)$(TOP_DIR)/hack/dind/dind.sh $(DIND_ARGS) make $*
```
