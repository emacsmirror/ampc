all: clean install compile test

benchjs:
	node_modules/.bin/matcha

benchel:
	emacs -Q -L . \
	-l context-coloring \
	-l benchmark/scenarios.el

compile:
	emacs -Q -batch -f batch-byte-compile *.el

clean:
	rm -rf node_modules
	rm *.elc

install:
	npm install

test:
	node_modules/.bin/mocha
	emacs -Q -batch -L . \
	-l ert \
	-l context-coloring \
	-l test/context-coloring-test.el \
	-f ert-run-tests-batch-and-exit

.PHONY: all benchjs benchel compile clean install test
