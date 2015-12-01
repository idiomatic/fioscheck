#!/usr/bin/env coffee
#
# TODO search box
# TODO search result regions (e.g., search by zipcode)
# TODO auto-check on precise address search
# TODO /markers latitude/longitude/distance based on map.getBounds() and map.getZoom()
# TODO double click to zoom
# TODO scale icons in relation to map scale


fs   = require 'fs'
util = require 'util'

Horseman = require 'node-horseman'

koa        = require 'koa'
route      = require 'koa-route'
koaStatic  = require 'koa-static'
bodyParser = require 'koa-bodyparser'

co     = require 'co'
coBody = require 'co-body'

redis       = require 'redis'
coRedis     = require 'co-redis'
redisClient = redis.createClient(process.env.REDIS_URL)
redis       = coRedis(redisClient)

georedis = require 'georedis'
geo      = georedis.initialize(redisClient, zset:'fios')
can      = geo.addSet('can')
cannot   = geo.addSet('cannot')
checking = geo.addSet('checking')

port = process.env.PORT ? 3001


start = ->
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
                        type:        'Point'
                        coordinates: [longitude, latitude]
                    properties:
                        address: key
                        status:  status
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

    app.use route.get '/diagnostic.html', (next) ->
        html = yield redis.get('fios:diagnostic.html')
        if html
            @body = html
        else
            yield next

    app.use route.get '/diagnostic.png', (next) ->
        png = yield redis.get('fios:diagnostic.png')
        if png
            @body = new Buffer(png, 'base64')
            @type = 'image/png'
        else
            yield next

    app.use(koaStatic('diagnostic'))
    app.use(koaStatic('static'))

    app.listen(port)

    yield return


check = (address, zipcode, latitude, longitude) ->
    task = JSON.stringify({address, zipcode, latitude, longitude})
    yield redis.rpush('fios:queue', task)
    return 'checking'


if require.main is module
    co(start)


module.exports = {start, check}
