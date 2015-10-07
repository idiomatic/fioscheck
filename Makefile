ICED = node_modules/.bin/iced
PHANTOMJS = /usr/local/bin/phantomjs
#ADDRESS = 2149 Magnolia Ave 90806
#ADDRESS = 40 CEDAR WALK UNIT P3 CA 90802
#ADDRESS = 7140 E MEZZANINE WAY 90808
COORDS = 33.8145,-118.094
ADDRESS = $($(ICED) rgeocode.iced $(COORDS))

run: deps build
	$(PHANTOMJS) fioscheck.js $(ADDRESS)

build: fioscheck.js rgeocode.js

%.js: %.iced
	$(ICED) -I inline -p $< > $@

deps: $(ICED) $(PHANTOMJS)

$(ICED):
	npm install iced-coffee-script

$(PHANTOMJS):
	brew install phantomjs

clean:
	-rm *~ fioscheck.js rgeocode.js

distclean:
