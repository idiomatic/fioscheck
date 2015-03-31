ICED = node_modules/.bin/iced
PHANTOMJS = /usr/local/bin/phantomjs
ADDRESS = 2149 Magnolia Ave 90806

run: deps build
	$(PHANTOMJS) fioscheck.js $(ADDRESS)

build: fioscheck.js

fioscheck.js: fioscheck.iced
	$(ICED) -I inline -c fioscheck.iced

deps: $(ICED) $(PHANTOMJS)

$(ICED):
	npm install iced-coffee-script

$(PHANTOMJS):
	brew install phantomjs

clean:
	-rm *~ fioscheck.js

distclean:
