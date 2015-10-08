#!/usr/bin/env coffee

fs         = require 'fs'
util       = require 'util'
koa        = require 'koa'
route      = require 'koa-route'
bodyParser = require 'koa-bodyparser'
coBody     = require 'co-body'
georedis   = require 'georedis'
redis      = require 'redis'
Horseman   = require 'node-horseman'

redisClient = redis.createClient()

geo      = georedis.initialize(redisClient, zset:'fios')
has      = geo.addSet('has')
can      = geo.addSet('can')
cannot   = geo.addSet('cannot')
checking = geo.addSet('checking')

port = 3001
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
    featureize = (latitude, longitude, properties) ->
        #latitude  = latitude.toFixed(6)
        #longitude = longitude.toFixed(6)
        type: 'Feature'
        geometry:
            type: 'Point'
            coordinates: [longitude, latitude]
        properties: properties
    features = []
    for status, locations of location_groups
        for {latitude, longitude, key} in locations
            features.push(featureize(latitude, longitude, address:key, status:status))
    return {type:'FeatureCollection', features}

app.use route.get '/markers', (next) ->
    {latitude, longitude, distance} = @state
    [hasData, canData, cannotData, checkingData] = yield [
        (cb) -> has.nearby({latitude, longitude}, distance, withCoordinates:true, cb)
        (cb) -> can.nearby({latitude, longitude}, distance, withCoordinates:true, cb)
        (cb) -> cannot.nearby({latitude, longitude}, distance, withCoordinates:true, cb)
        (cb) -> checking.nearby({latitude, longitude}, distance, withCoordinates:true, cb)
    ]
    @body = geojson {has:hasData, can:canData, cannot:cannotData, checking:checkingData}

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
    yield horseman.type('#txtAddress', address)
    yield horseman.type('#txtZip', zipcode)
    yield horseman.click('#btnContinueOverlay')
    yield horseman.waitForSelector('#dvAddressOption0, #securityCheck')

    if yield horseman.exists('#securityCheck')
        # captcha.  damn.
        yield horseman.screenshot('horseman securitycheck.png')
        console.log "captcha"
        #@throw(429, 'captcha')
        @status = 429

    else
        if yield horseman.exists('#dvAddressOption2')
            #yield horseman.screenshot('horseman ambiguous.png')
            yield horseman.click('#dvAddressOption0 a')
            # fall through into #dvAddressOption0

        if yield horseman.exists('#dvAddressOption0')
            #yield horseman.screenshot('horseman confirm.png')
            # "Is this your address?"  Yes.
            yield horseman.click('input[value="Continue"]')
            yield horseman.waitForNextPage()

            yield horseman.waitForSelector('#checkavailability, #changeserv')

            if yield horseman.exists(':contains("This address already has Verizon service")')
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
            fios = false
            #html = yield horseman.html()
            #yield (cb) -> fs.writeFile('horseman not found.html', html, cb)
            #yield horseman.screenshot('horseman not found.png')

        else
            @body = "unknown\n"

    yield horseman.close()

    if latitude? and longitude?
        yield [
            (cb) ->
                (if fios then can else cannot).addLocation(location, {latitude, longitude}, cb)
            (cb) ->
                checking.removeLocation(location, cb)
        ]

    @body = JSON.stringify(fios)


app.use(require('koa-static')('static'))

app.listen(port)
