#!/usr/bin/env coffee
#
# TODO promisify redis
# TODO find captcha-triggering interval
# TODO store diagnostic somewhere other than worker's filesystem


fs         = require 'fs'
util       = require 'util'
coBody     = require 'co-body'
georedis   = require 'georedis'
redis      = require 'redis'
request    = require 'request'
Horseman   = require 'node-horseman'
co         = require 'co'
coWait     = require 'co-wait'

redisClient = redis.createClient(process.env.REDIS_URL)

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

    if latitude? and longitude?
        yield (cb) ->
            checking.addLocation(location, {latitude, longitude}, cb)

    yield (cb) -> redisClient.incr("fios:checks:#{myIPAddr}", cb)
    yield (cb) -> redisClient.expire("fios:checks:#{myIPAddr}", 86400, cb)

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
        yield coWait(100)
        yield horseman.screenshot('diagnostic/horseman_securitycheck.png')
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
                yield horseman.screenshot('diagnostic/horseman_pending_order.png')
                yield horseman.click('input[value="Continue"]')
                yield horseman.waitForSelector('#checkavailability')
                yield coWait(100)

            if yield horseman.exists(':contains("This address already has Verizon service")')
                #yield horseman.screenshot('diagnostic/horseman_already_has_verizon.png')
                yield horseman.click('#rdoNoNotMine ~ a')
                yield horseman.waitForSelector(':contains("Is the current resident staying?")')
                yield coWait(100)
                yield horseman.click('#rdoNoAmMovingThere ~ a')
                yield horseman.click('input[value="Continue"]')
                yield horseman.waitForSelector('#checkavailability')
                yield coWait(100)

            # in case of unexpected false...
            html = yield horseman.html()
            yield (cb) -> fs.writeFile('diagnostic/horseman_products.html', html, cb)
            yield horseman.screenshot('diagnostic/horseman_products.png')

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
            html = yield horseman.html()
            yield (cb) -> fs.writeFile('diagnostic/horseman_unknown.html', html, cb)
            yield horseman.screenshot('diagnostic/horseman_unknown.png')
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
    [_, myIPAddr] = yield (cb) -> request.get('https://api.ipify.org', cb)
    console.log("myIPAddr #{myIPAddr}")

    loop
        [key, task] = yield (cb) -> redisClient.blpop('fios:queue', 0, cb)
        {address, zipcode, latitude, longitude} = JSON.parse(task)
        status = yield check(address, zipcode, latitude, longitude)


if require.main is module
    co(start)


module.exports = {start, check}
