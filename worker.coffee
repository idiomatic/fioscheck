#!/usr/bin/env coffee
#
# TODO promisify redis
# TODO find captcha-triggering interval
# TODO store diagnostic somewhere other than worker's filesystem


fs   = require 'fs'
util = require 'util'

Horseman = require 'node-horseman'

co        = require 'co'
coWait    = require 'co-wait'
coBody    = require 'co-body'
coRequest = require 'co-request'

redis       = require 'redis'
coRedis     = require 'co-redis'
redisClient = redis.createClient(process.env.REDIS_URL)
redis       = coRedis(redisClient)

georedis = require 'georedis'
geo      = georedis.initialize(redisClient, zset:'fios')
can      = geo.addSet('can')
cannot   = geo.addSet('cannot')
checking = geo.addSet('checking')


# e.g., 'localhost:2001'
proxy = process.env.SOCKS_PROXY
proxyType = process.env.SOCKS_TYPE or (proxy ? 'socks5')

horsemanOptions =
    injectJquery: false
    timeout:      30000
    proxy:        proxy
    proxyType:    proxyType

myIPAddr = undefined


check = (address, zipcode, latitude, longitude) ->
    location = "#{address}, #{zipcode}"
    status = undefined

    diagnose = ->
        html = yield horseman.html()
        screenshot = yield horseman.screenshotBase64('PNG')
        yield redis.set 'fios:diagnostic.html', html
        yield redis.set 'fios:diagnostic.png', screenshot

    if latitude? and longitude?
        yield (cb) ->
            checking.addLocation(location, {latitude, longitude}, cb)

    yield redis.incr("fios:checks:#{myIPAddr}")
    yield redis.expire("fios:checks:#{myIPAddr}", 86400)

    url = 'http://www.verizon.com/foryourhome/ORDERING/CheckAvailability.aspx?type=pheonix&fromPersonalisation=y&flowtype=fios&incid=newheronull_null_null_es+clk'
    horseman = new Horseman(horsemanOptions)
    yield horseman.open(url)
    yield horseman.waitForSelector('#txtAddress')
    yield coWait(100)
 
    yield horseman.type('#txtAddress', address)
    yield horseman.type('#txtZip', zipcode)
    yield horseman.click('#btnContinueOverlay')
    yield horseman.waitForSelector('#dvAddressOption0, #securityCheck')
    yield coWait(100)

    if yield horseman.exists('#securityCheck')
        # captcha.  damn.
        yield coWait(1000)
        yield diagnose()

        # HACK no throw because we need to remove location from checking set
        #@throw(429, 'captcha')
        #@status = 429
        status = 'captcha'

    else
        if yield horseman.exists('#dvAddressOption2')
            yield horseman.click('#dvAddressOption0 a')
            # fall through into #dvAddressOption0

        if yield horseman.exists('#dvAddressOption0')
            # "Is this your address?"  Yes.
            yield horseman.click('#dvAddressOption0 a')
            yield horseman.click('input[value="Continue"]')
            #yield horseman.screenshot('diagnostic/horseman_address_verification.png')
            yield horseman.waitForNextPage()
            yield horseman.waitForSelector('#checkavailability, #changeserv')
            yield coWait(100)

            if yield horseman.exists(':contains("This address already has a pending Verizon Order")')
                yield horseman.click('#rdoNotMineOrd a')
                yield diagnose()
                yield horseman.click('input[value="Continue"]')
                yield horseman.waitForSelector('#checkavailability')
                yield coWait(100)

            if yield horseman.exists(':contains("This address already has Verizon service")')
                yield horseman.click('#rdoNoNotMine ~ a')
                yield horseman.waitForSelector(':contains("Is the current resident staying?")')
                yield coWait(100)
                yield horseman.click('#rdoNoAmMovingThere ~ a')
                yield horseman.click('input[value="Continue"]')
                yield horseman.waitForSelector('#checkavailability')
                yield coWait(100)

            status = yield horseman.exists('.products_list h4:contains("Fios Internet")')

        else if yield horseman.exists(':contains("service you wanted isn\'t available")')
            status = 'unavailable'

        else if yield horseman.exists(':contains("address you entered is not served by Verizon")')
            status = 'no service'

        else if yield horseman.exists(':contains("unable to validate the address")')
            #@throw(400, "invalid location")
            #@status = 400
            status = 'invalid location'

        # TODO This address already has a pending Verizon Order

        else
            yield diagnose()
            console.log("unknown #{location}")
            status = 'unknown'

    horseman.close()

    if latitude? and longitude?
        if status is true
            yield [
                (cb) -> can.addLocation(location, {latitude, longitude}, cb)
                (cb) -> cannot.removeLocation(location, cb)
            ]
        else if status?
            yield [
                (cb) -> cannot.addLocation(location, {latitude, longitude}, cb)
                (cb) -> can.removeLocation(location, cb)
            ]
        yield (cb) ->
            checking.removeLocation(location, cb)

    console.log("#{status} #{location}")
    return status


start = ->
    {body: myIPAddr} = yield coRequest('https://api.ipify.org')
    console.log("myIPAddr #{myIPAddr}")

    loop
        [key, task] = yield redis.blpop('fios:queue', 0)
        {address, zipcode, latitude, longitude} = JSON.parse(task)
        status = yield check(address, zipcode, latitude, longitude)


if require.main is module
    co(start)


module.exports = {start, check}
