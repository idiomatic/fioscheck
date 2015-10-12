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
co = require 'co'

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

start = ->
    # XXX per web process... redis INCR instead?
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

        @assert(address and /./.test(address), 400, 'Address missing')
        @assert(zipcode and /\d{5}/.test(zipcode), 400, 'Zipcode missing')

        # in case main overrode it
        {check} = module.exports
        @body = yield check(address, zipcode, latitude, longitude)

    app.use(require('koa-static')('static'))

    app.listen(port)

    yield return


check = (address, zipcode, latitude, longitude) ->
    task = JSON.stringify({address, zipcode, latitude, longitude})
    yield (cb) -> redisClient.rpush('fios:queue', task, cb)
    return 'checking'


if require.main is module
    co(start)


module.exports = {start, check}
