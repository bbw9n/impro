EMACS ?= emacs
IMPRO  = $(EMACS) --batch -l impro.el -f impro-batch

.PHONY: check doctor smoke smoke-linux

# Compile without warnings, and lint the smoke scenario: no window needed.
check:
	$(EMACS) --batch -Q --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile impro.el && rm -f impro.elc
	$(IMPRO) test/smoke-demo.el --lint

# What this system has, and what's missing to record.
doctor:
	$(IMPRO) --doctor

# Record the smoke test here, to out/smoke.mp4 and out/smoke.gif.
smoke:
	$(IMPRO) test/smoke-demo.el out/smoke

# The same on Linux, headless, in Docker (Xvfb started directly:
# xvfb-run can hang waiting for Xvfb in containers).
smoke-linux:
	docker build -q -t impro-linux test
	docker run --rm --init -v "$(CURDIR)":/impro impro-linux sh -c '\
	  Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & sleep 1; \
	  DISPLAY=:99 emacs --batch -l /impro/impro.el -f impro-batch \
	    /impro/test/smoke-demo.el /impro/out/smoke-linux'
