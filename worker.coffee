#!/usr/bin/env coffee

fs         = require 'fs'
util       = require 'util'
coBody     = require 'co-body'
georedis   = require 'georedis'
redis      = require 'redis'
Horseman   = require 'node-horseman'
co = require 'co'

redisClient = redis.createClient(process.env.REDIS_URL)

geo      = georedis.initialize(redisClient, zset:'fios')
can      = geo.addSet('can')
cannot   = geo.addSet('cannot')
checking = geo.addSet('checking')

horsemanOptions =
    injectJquery: false
    timeout: 30000
    #proxy: 'localhost:2001'
    #proxyType: 'socks5'
checkCount = 0


check = (address, zipcode, latitude, longitude) ->
    location = "#{address}, #{zipcode}"
    fios = undefined

    if latitude? and longitude?
        yield (cb) ->
            checking.addLocation(location, {latitude, longitude}, cb)

    console.log "##{++checkCount} checking #{location}"

    url = 'http://www.verizon.com/foryourhome/ORDERING/CheckAvailability.aspx?type=pheonix&fromPersonalisation=y&flowtype=fios&incid=newheronull_null_null_es+clk'
    horseman = new Horseman(horsemanOptions)
    yield horseman.open(url)
    yield horseman.waitForSelector('#txtAddress')

    yield horseman.type('#txtAddress', address)
    yield horseman.type('#txtZip', zipcode)
    yield horseman.click('#btnContinueOverlay')
    yield horseman.waitForSelector('#dvAddressOption0, #securityCheck')

    if yield horseman.exists('#securityCheck')
        # captcha.  damn.
        yield horseman.screenshot('horseman securitycheck.png')
        console.log "captcha"
        # HACK no throw because we need to remove location from checking set
        #@throw(429, 'captcha')
        #@status = 429
        return 'captcha'

    else
        if yield horseman.exists('#dvAddressOption2')
            yield horseman.click('#dvAddressOption0 a')
            # fall through into #dvAddressOption0

        if yield horseman.exists('#dvAddressOption0')
            # "Is this your address?"  Yes.
            yield horseman.click('input[value="Continue"]')
            #yield horseman.screenshot('horseman address verification.png')
            yield horseman.waitForNextPage()

            yield horseman.waitForSelector('#checkavailability, #changeserv')

            if yield horseman.exists(':contains("This address already has Verizon service")')
                #yield horseman.screenshot('horseman already has verizon.png')
                yield horseman.click('#rdoNoNotMine ~ a')
                yield horseman.waitForSelector(':contains("Is the current resident staying?")')
                yield horseman.click('#rdoNoAmMovingThere ~ a')
                yield horseman.click('input[value="Continue"]')
                yield horseman.waitForSelector('#checkavailability')

            #html = yield horseman.html()
            #yield (cb) -> fs.writeFile('horseman products.html', html, cb)
            #yield horseman.screenshot('horseman products.png')

            fios = yield horseman.exists('.products_list h4:contains("FiOS Internet")')

        else if yield horseman.exists(':contains("service you wanted isn\'t available")')
            console.log "unavailable"
            fios = false

        else if yield horseman.exists(':contains("address you entered is not served by Verizon")')
            console.log "no service"
            fios = false

        else if yield horseman.exists(':contains("unable to validate the address")')
            console.log "invalid location #{location}"
            #@throw(400, "invalid location")
            #@status = 400
            return 'invalid location'

        # TODO This address already has a pending Verizon Order

        else
            html = yield horseman.html()
            yield (cb) -> fs.writeFile('horseman unknown.html', html, cb)
            yield horseman.screenshot('horseman unknown.png')
            console.log "unknown"
            return "unknown"

    horseman.close()

    if latitude? and longitude?
        if fios?
            if fios
                yield [
                    (cb) -> can.addLocation(location, {latitude, longitude}, cb)
                    (cb) -> cannot.removeLocation(location, cb)
                ]
            else
                yield [
                    (cb) -> cannot.addLocation(location, {latitude, longitude}, cb)
                    (cb) -> can.removeLocation(location, cb)
                ]
        yield (cb) ->
            checking.removeLocation(location, cb)

    return fios


start = ->
    loop
        # XXX can promisify redis
        [key, task] = yield (cb) -> redisClient.blpop('fios:queue', 0, cb)
        {address, zipcode, latitude, longitude} = JSON.parse(task)
        status = yield check(address, zipcode, latitude, longitude)


if require.main is module
    co(start)


module.exports = {start, check}
