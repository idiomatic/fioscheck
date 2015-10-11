#!/usr/bin/env coffee

# TODO search box
# TODO search result regions (e.g., search by zipcode)
# TODO auto-check on precise address search
# TODO /markers latitude/longitude/distance based on map.getBounds() and map.getZoom()
# TODO double click to zoom
# TODO scale icons in relation to map scale


fs         = require 'fs'
util       = require 'util'
koa        = require 'koa'
route      = require 'koa-route'
bodyParser = require 'koa-bodyparser'
coBody     = require 'co-body'
georedis   = require 'georedis'
redis      = require 'redis'
Horseman   = require 'node-horseman'

redisClient = redis.createClient(process.env.REDIS_URL)

geo      = georedis.initialize(redisClient, zset:'fios')
can      = geo.addSet('can')
cannot   = geo.addSet('cannot')
checking = geo.addSet('checking')

port = process.env.PORT ? 3001
horsemanOptions =
    injectJquery: false
    timeout: 30000
    #proxy: 'localhost:2001'
    #proxyType: 'socks5'
checkCount = 0

app = koa()
app.use(bodyParser())

app.use (next) ->
    {latitude, longitude, distance} = @query
    @state.latitude  = parseFloat(latitude)
    @state.longitude = parseFloat(longitude)
    @state.distance  = parseInt(distance) or 1000
    yield next

geojson = (location_groups) ->
    features = []
    for status, locations of location_groups
        for {latitude, longitude, key} in locations
            #latitude  = latitude.toFixed(6)
            #longitude = longitude.toFixed(6)
            feature =
                type: 'Feature'
                geometry:
                    type: 'Point'
                    coordinates: [longitude, latitude]
                properties:
                    address: key
                    status: status
            features.push(feature)
    return {type:'FeatureCollection', features}

app.use route.get '/markers', (next) ->
    {latitude, longitude, distance} = @state
    @body = geojson yield
        can: (cb) ->
            can.nearby({latitude, longitude}, distance, withCoordinates:true, cb)
        cannot: (cb) ->
            cannot.nearby({latitude, longitude}, distance, withCoordinates:true, cb)
        checking: (cb) ->
            checking.nearby({latitude, longitude}, distance, withCoordinates:true, cb)

app.use route.get '/passed', (next) ->
    @body = {'90025': {longitude:34.043712, latitude:-118.460739, passed:0}}

app.use route.post '/check', (next) ->
    # address, obtained by click|geoip or textfields
    if @is('text/csv')
        body = yield coBody.text(@request)
        [longitude, latitude, houseNumber, street, _, _, _, zipcode] = body.split(',')
        if houseNumber? and street?
            address = "#{houseNumber} #{street}"
    else
        {address, zipcode, latitude, longitude} = @request.body
    latitude  = parseFloat(latitude)
    longitude = parseFloat(longitude)
    location = "#{address}, #{zipcode}"
    fios = undefined

    @assert(address and /./.test(address), 400, 'Address missing')
    @assert(zipcode and /\d{5}/.test(zipcode), 400, 'Zipcode missing')

    console.log "##{++checkCount} checking #{location}"

    if latitude? and longitude?
        yield (cb) ->
            checking.addLocation(location, {latitude, longitude}, cb)

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
        @status = 429
        @body = 'captcha'

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
            @status = 400
            @body = 'invalid location'

        # TODO This address already has a pending Verizon Order

        else
            html = yield horseman.html()
            yield (cb) -> fs.writeFile('horseman unknown.html', html, cb)
            yield horseman.screenshot('horseman unknown.png')
            console.log "unknown"
            @body = "unknown"

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

    @body = JSON.stringify(fios)


app.use(require('koa-static')('static'))

app.listen(port)
