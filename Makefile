# Run test/install/load.sql (extension install) COMMITTED, once, before the
# main pgTAP suite, via pgxntool's test/install feature. Set explicitly
# (rather than left to auto-detect) so an accidentally emptied test/install/
# is a hard build error instead of silently falling back to "disabled".
# Must be set before `include pgxntool/base.mk` below -- base.mk reads it
# while parsing.
PGXNTOOL_ENABLE_TEST_INSTALL = yes

# TEST_LOAD_SOURCE selects how test/install/load.sql installs extension_drop:
#   - fresh (default): CREATE EXTENSION extension_drop (current version).
#   - update: CREATE EXTENSION at TEST_UPDATE_FROM, then ALTER EXTENSION
#     UPDATE -- to TEST_UPDATE_TO if set, otherwise to the current version.
#     Running the SAME suite/expected output against the result asserts
#     update behaves identically to a fresh install. NOTE: extension_drop has
#     never had a real second released version (PGXN's only listing is
#     0.1.x from 2017, predating the current SQL entirely -- see HISTORY.asc
#     and RELEASE.md), so TEST_UPDATE_FROM has no safe default; this mode is
#     wired up and structurally ready, but there is nothing real to update
#     FROM yet, and so no CI leg exercises it in this repo today.
#   - existing: the extension is ALREADY installed (a real pg_upgrade, or an
#     ALTER EXTENSION UPDATE done outside the suite). load.sql does not
#     touch it; it only asserts presence + current version. Pair with
#     CONTRIB_TESTDB=<db> and EXTRA_REGRESS_OPTS=--use-existing to point
#     pg_regress at that database instead of a throwaway one.
#
# Propagated to load.sql as a GUC: pg_regress doesn't forward make variables,
# but the psql processes it spawns inherit the environment, so PGOPTIONS
# reaches load.sql. Exported UNCONDITIONALLY so load.sql can read it without
# missing_ok and fail loudly if it didn't propagate, rather than silently
# defaulting to the wrong mode. The mode is also validated here at
# make-parse-time, so a typo like `TEST_LOAD_SOURCE=fresh ` or
# `TEST_LOAD_SOURCE=typo` fails immediately instead of quietly running the
# default.
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh update existing),)
$(error TEST_LOAD_SOURCE must be 'fresh', 'update' or 'existing', got '$(TEST_LOAD_SOURCE)')
endif

# update-mode version range (load.sql only reads these in update mode).
# Empty TEST_UPDATE_TO means "update to the current default_version". There
# is no safe default for TEST_UPDATE_FROM (see above) -- require it
# explicitly rather than pointing it at a version that doesn't exist.
TEST_UPDATE_FROM ?=
TEST_UPDATE_TO ?=
ifeq ($(TEST_LOAD_SOURCE),update)
  ifeq ($(strip $(TEST_UPDATE_FROM)),)
$(error TEST_UPDATE_FROM must be set when TEST_LOAD_SOURCE=update -- extension_drop has no prior released version yet to default it to)
  endif
endif

export PGOPTIONS := $(PGOPTIONS) -c extension_drop.test_load_mode=$(TEST_LOAD_SOURCE) -c extension_drop.test_update_from=$(TEST_UPDATE_FROM) -c extension_drop.test_update_to=$(TEST_UPDATE_TO)

# make test-update == make test TEST_LOAD_SOURCE=update. Must recurse (a
# fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with update set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

include pgxntool/base.mk

testdeps: test_extension
test_extension: $(DESTDIR)$datadir)/extension/extension_drop_test.control $(wildcard $(TESTDIR)/*)
$(DESTDIR)$datadir)/extension/extension_drop_test.control:
	make -C $(TESTDIR)/extension install
#
# OTHER DEPS
#
.PHONY: deps
deps: cat_tools
install: deps

# extension_drop.sql calls cat_tools.routine__parse_arg_types_text(), which only
# exists starting at cat_tools 0.3.0. PGXN's published cat_tools listing is
# stuck at 0.2.1 from 2017 (the old decibel/cat_tools distribution) and was
# never updated for the Postgres-Extensions/cat_tools fork; `pgxn install
# cat_tools` therefore installs an ancient 0.2.1 lacking the function we need
# (and carrying a pre-omit_column-fix catalog query that breaks on PG12+).
# 0.3.0 itself has not been tagged/published to PGXN yet -- only 0.2.2/0.2.3
# are there, and even 0.2.3 predates this function. So PGXN isn't a usable
# install source right now.
#
# Building straight from a git ref instead of PGXN is a supported way to
# depend on an extension here, not just a one-off hack -- reach for it again
# whenever a dependency's real state has moved ahead of what's tagged on
# PGXN. What IS temporary is depending on cat_tools this way at all:
# CAT_TOOLS_GIT_REF tracks cat_tools' `master` directly rather than a pinned
# commit, since the function we need doesn't exist on any tagged release, so
# there's nothing more stable to pin to yet. Once 0.3.0 is tagged and
# published to PGXN, revert *this target* to a plain
# `pgxn install 'cat_tools>=0.3.0' --sudo`; leave the git-source mechanism
# itself in place for reuse if this happens again.
CAT_TOOLS_GIT_REF = master
CAT_TOOLS_BUILD_DIR = tmp/cat_tools-build

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	rm -rf $(CAT_TOOLS_BUILD_DIR)
	git clone https://github.com/Postgres-Extensions/cat_tools.git $(CAT_TOOLS_BUILD_DIR)
	cd $(CAT_TOOLS_BUILD_DIR) && git checkout $(CAT_TOOLS_GIT_REF)
	$(MAKE) -C $(CAT_TOOLS_BUILD_DIR) install PG_CONFIG=$(PG_CONFIG) DESTDIR=$(DESTDIR)
	rm -rf $(CAT_TOOLS_BUILD_DIR)
