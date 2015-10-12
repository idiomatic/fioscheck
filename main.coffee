#!/usr/bin/env coffee

co     = require 'co'
worker = require './worker'
web    = require './web'

# XXX assumes worker's invocations is via module.exports.check, and that propigates
#web.check = worker.check

co worker.start
co web.start
