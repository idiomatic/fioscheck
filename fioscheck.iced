system = require('system')
webpage = require('webpage')
{spawn} = require('child_process')

[_, address..., zip] = system.args
address = address.join(' ')

page = webpage.create()

click = (selector) ->
    page.evaluate (selector) ->
        ev = document.createEvent('MouseEvents')
        ev.initEvent('click', true, true)
        document.querySelector(selector)?.dispatchEvent(ev)
    , selector

input = (selector, value) ->
    page.evaluate (selector, value) ->
        document.querySelector(selector)?.value = value
    , selector, value

scrape = (selector) ->
    return page.evaluate (selector) ->
        document.querySelector(selector)
    , selector

exists = (selector) ->
    return not not scrape(selector)

waitfor = (selector, autocb) ->
    loop
        await setTimeout defer(), 500
        break if exists(selector)

page.onError = (msg, trace) ->
    console.error(msg)

page.viewportSize = {width: 825, height: 580}
await page.open('http://www.verizon.com/foryourhome/ORDERING/CheckAvailability.aspx?type=pheonix&fromPersonalisation=y&flowtype=fios&incid=newheronull_null_null_es+clk', defer(status))

input('#txtAddress', address)
input('#txtZip', zip)
click('#btnContinueOverlay')

# XXX might already have Verizon

await waitfor('#dvAddressOption0, #securityCheck', defer())

if exists('#dvAddressOption2')
    console.log('ambiguous address')
    phantom.exit(1)

verified_address = null
if exists('#securityCheck')
    await setTimeout defer(), 500
    page.render('securitycheck.png')
    await spawn("open", ["securitycheck.png"]).on('exit', defer())
    #phantom.exit 1
    system.stdout.write('Captcha: ')
    captcha = system.stdin.readLine()
    input('#recaptcha_response_field', captcha)
    click('#body_content_btnContinue')
    await setTimeout defer(), 500
    page.render('securitycheck.png')
    # XXX captcha has different flow
    phantom.exit(2)
else
    verified_address = scrape('#body_content_dvAddress address')?.innerText
    click('#body_content_btnContinue')

await waitfor('#checkavailability', defer())
page.render('fioscheck.png')

products = page.evaluate ->
    (product.innerHTML for product in document.querySelectorAll('.products_list h4'))
products = (product for product in products when /fios/i.test(product))
products = products.join(', ')

console.log("#{products} at #{verified_address}")

page.render('fioscheck.png')
#await spawn("open", ["fioscheck.png"]).on 'exit', defer()
phantom.exit()
