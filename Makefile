# cubrid-nix recipes (ADR 0001). Each runs a script of scripts/ in the dev shell; from any
# other shell it enters `nix develop` first. `make` alone lists them.
#
#   make build WORKTREE=<dir> [MODE=optdebug|release]          nix build, as the CI builds (D6)
#   make shell-build WORKTREE=<dir> [MODE=..] [PREFIX=<dir>]   incremental build in place (D3)
#   make seal WORKTREE=<dir>                                   record new sealed inputs (D7), needs network
#   make smoke INSTALL=<dir> [NAME=smoke]                      server, csql and PL/CSQL in a run directory (D2)
#   make ctp SUITE=<sql|medium> INSTALL=<dir> TC_REF=<ref>|PR=<n> [ONLY='<dir> ..'] [ARGS='..']
#                                                              a CTP suite or part of it (D8, D11)
#   make shell-case INSTALL=<dir> CASE=<case dir> [TESTCASES=<private-ex checkout>]
#                                                              one CTP shell case (ADR 0003 D8)
#   make cache-update [CACHE_DIR=<dir>]                        after a flake.nix, flake.lock or nix/ change:
#                                                              both binary caches (docs/cache-maintenance.md)
#   make cache-push [CACHE_DIR=<dir>] [KEY=<file>]             fill the LAN binary cache directory (ADR 0002)
#   make cache-publish [CACHE_DIR=<dir>]                       our own paths to the GitHub release cache

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
NIX := nix --extra-experimental-features 'nix-command flakes'
# the dev shell sets CUBRID_CI_SNAPSHOT
DEV := $(if $(CUBRID_CI_SNAPSHOT),,$(NIX) develop $(ROOT) -c)
# Every recipe runs under scripts/reap.py: what a build, a server or a test leaves behind
# is reaped and stopped there, not left to a PID 1 that may never reap it (ADR 0003 D12).
RUN := $(DEV) $(ROOT)/scripts/reap.py --
MODE ?= optdebug
NAME ?= smoke
need = $(if $($(1)),,$(error $(1)= is required: $(2)))
# zsh leaves the ~ of `WORKTREE=~/cubrid` as it is
path = "$(patsubst ~/%,$(HOME)/%,$(1))"

.NOTPARALLEL:
.PHONY: help build shell-build seal smoke ctp shell-case cache-update cache-push cache-publish
help:
	@sed -n 's/^#   //p' $(ROOT)/Makefile

build:
	@: $(call need,WORKTREE,make build WORKTREE=<cubrid worktree> [MODE=optdebug|release])
	$(RUN) $(ROOT)/scripts/build.sh $(call path,$(WORKTREE)) "$(MODE)"

shell-build:
	@: $(call need,WORKTREE,make shell-build WORKTREE=<cubrid worktree> [MODE=..] [PREFIX=<dir>])
	$(RUN) $(ROOT)/scripts/shell-build.sh $(call path,$(WORKTREE)) "$(MODE)" $(if $(PREFIX),$(call path,$(PREFIX)))

seal:
	@: $(call need,WORKTREE,make seal WORKTREE=<cubrid worktree>)
	$(RUN) $(ROOT)/scripts/seal.sh $(call path,$(WORKTREE))

smoke:
	@: $(call need,INSTALL,make smoke INSTALL=<install> [NAME=smoke])
	$(RUN) $(ROOT)/scripts/smoke-install.sh $(call path,$(INSTALL)) "$(NAME)"

ctp:
	@: $(call need,SUITE,make ctp SUITE=<sql|medium> INSTALL=<install> TC_REF=<ref>|PR=<n>)
	@: $(call need,INSTALL,make ctp SUITE=<sql|medium> INSTALL=<install> TC_REF=<ref>|PR=<n>)
	$(RUN) $(ROOT)/scripts/ctp.sh "$(SUITE)" $(call path,$(INSTALL)) $(if $(TC_REF),--tc-ref "$(TC_REF)") \
	  $(if $(PR),--pr "$(PR)") $(foreach d,$(ONLY),--only "$(d)") $(ARGS)

shell-case:
	@: $(call need,INSTALL,make shell-case INSTALL=<install> CASE=<case dir>)
	@: $(call need,CASE,make shell-case INSTALL=<install> CASE=<case dir>)
	$(RUN) $(ROOT)/scripts/shell-case.sh $(call path,$(INSTALL)) $(call path,$(CASE)) $(if $(TESTCASES),$(call path,$(TESTCASES)))

cache-update: cache-push cache-publish

cache-push:
	$(RUN) $(ROOT)/scripts/cache-push.sh $(if $(CACHE_DIR),$(call path,$(CACHE_DIR)),'') $(if $(KEY),$(call path,$(KEY)))

cache-publish:
	$(RUN) $(ROOT)/scripts/cache-publish.sh $(if $(CACHE_DIR),$(call path,$(CACHE_DIR)))
