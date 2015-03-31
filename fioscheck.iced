system = require 'system'
webpage = require 'webpage'
{spawn} = require 'child_process'

[_, address..., zip] = system.args
address = address.join ' '

page = webpage.create()

click = (selector) ->
    page.evaluate (selector) ->
        ev = document.createEvent 'MouseEvents'
        ev.initEvent 'click', true, true
        document.querySelector(selector)?.dispatchEvent ev
    , selector
    # XXX alternatively:
    #{offsetLeft, offsetRight} = page.evaluate (selector) ->
    #    document.querySelector(selector)
    #, selector
    #page.sendEvent 'click', offsetLeft + 1, offsetTop + 1

input = (selector, value) ->
    page.evaluate (selector, value) ->
        document.querySelector(selector)?.value = value
    , selector, value

waitfor = (selector, autocb) ->
    loop
        await setTimeout defer(), 500
        break if page.evaluate (selector) ->
            document.querySelector selector
        , selector

page.onError = (msg, trace) ->
    console.error msg

page.viewportSize = width: 825, height: 580
await page.open 'http://www.verizon.com/foryourhome/ORDERING/CheckAvailability.aspx?type=pheonix&fromPersonalisation=y&flowtype=fios&incid=newheronull_null_null_es+clk', defer status

input '#txtAddress', address
input '#txtZip', zip
click '#btnContinueOverlay'

# XXX it might show captcha

await waitfor '#dvAddressOption0, #securityCheck', defer()

if page.evaluate(-> document.getElementById 'dvAddressOption2')
    console.log 'ambiguous address'
    phantom.exit 1

verified_address = null
if page.evaluate(-> document.getElementById 'securityCheck')
    await setTimeout defer(), 500
    page.render 'securitycheck.png'
    await spawn("open", ["securitycheck.png"]).on 'exit', defer()
    #phantom.exit 1
    system.stdout.write 'Captcha: '
    captcha = system.stdin.readLine()
    input '#recaptcha_response_field', captcha
    click '#body_content_btnContinue'
    await setTimeout defer(), 500
    page.render 'securitycheck.png'
    phantom.exit 2
else
    verified_address = page.evaluate ->
        document.querySelector('#body_content_dvAddress address')?.innerText
    click '#body_content_btnContinue'

await waitfor '#checkavailability', defer()
page.render 'fioscheck.png'

products = page.evaluate ->
    (product.innerHTML for product in document.querySelectorAll('.products_list h4'))

has_fios = "FiOS Internet" in products
console.log "#{if has_fios then "" else "no "}FiOS at #{verified_address}"

#results = {}
#results[verified_address] = has_fios
#system.stdout.write JSON.stringify results

page.render 'fioscheck.png'
#await spawn("open", ["fioscheck.png"]).on 'exit', defer()
phantom.exit()
