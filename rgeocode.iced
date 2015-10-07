request = require 'request'

[_, _, coords] = process.argv

api_key = "AIzaSyC6nPG7Lx_PCy9CWv6jlyY4kOaHPw-LDYk"
coords ?= "33.8145,-118.094"

request.get "https://maps.googleapis.com/maps/api/geocode/json?key=#{api_key}&latlng=#{coords}", (err, res, body) ->
    geocodes = JSON.parse body
    geocode = (a for a in (geocodes?.results ? []) when 'street_address' in (a.types ? []))?[0]
    #console.log geocode?.formatted_address
    short_names = {}
    for component in (geocode?.address_components ? [])
        short_names[component.types[0]] = component.short_name
    console.log "#{short_names.street_number} #{short_names.route} #{short_names.postal_code}"
