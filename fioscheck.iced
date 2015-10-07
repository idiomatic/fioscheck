#!/usr/bin/env phantomjs

system = require('system')
webpage = require('webpage')
{spawn} = require('child_process')

[_, address..., zip] = system.args
address = address.join(' ')

page = webpage.create()

page.onError = (msg, trace) ->
    console.error(msg)

renderDir = 'render'
renderCount = 0
diagnosticRender = (addendum) ->
    n = "#{10000 + renderCount++}".substring(1)
    page.render("#{renderDir}/#{n} #{addendum}.png")


withSelectorMarked = (selector, fn) ->
    priorBorder = page.evaluate (selector) ->
        priorBorder = document.querySelector(selector)?.style?.border
        document.querySelector(selector)?.style?.border = "3px solid red"
        return priorBorder
    retval = fn()
    page.evaluate (selector, priorBorder) ->
        document.querySelector(selector)?.style?.border = priorBorder
    return retval


click = (selector) ->
    withSelectorMarked selector, ->
        diagnosticRender('click')
        page.evaluate (selector) ->
            ev = document.createEvent('MouseEvents')
            ev.initEvent('click', true, true)
            document.querySelector(selector)?.dispatchEvent(ev)
        , selector


input = (selector, value) ->
    withSelectorMarked selector, ->
        page.evaluate (selector, value) ->
            document.querySelector(selector)?.value = value
        , selector, value
        diagnosticRender('input')


scrape = (selector) ->
    return withSelectorMarked selector, ->
        diagnosticRender('scrape')
        return page.evaluate (selector) ->
            return document.querySelector(selector)
        , selector


exists = (selector) ->
    return not not scrape(selector)


waitfor = (selector, autocb) ->
    withSelectorMarked(selector, -> diagnosticRender('waitfor'))
    loop
        await setTimeout defer(), 1000
        break if exists(selector)
    withSelectorMarked(selector, -> diagnosticRender('waitfor found'))


# http://www.verizon.com/home/fiosavailability/ "Can I Get FiOS?" button
# displays an iframe...
page.viewportSize = {width: 825, height: 580}
await page.open('http://www.verizon.com/foryourhome/ORDERING/CheckAvailability.aspx?type=pheonix&fromPersonalisation=y&flowtype=fios&incid=newheronull_null_null_es+clk', defer(status))

input('#txtAddress', address)
input('#txtZip', zip)
click('#btnContinueOverlay')

do ->
    await setTimeout defer(), 1000
    

console.log("checking #{address}, #{zip}...")

await waitfor('#dvAddressOption0, #changeserv, #securityCheck', defer())

if exists('#securityCheck')
    console.log("security check...")

    # let it fetch the captcha image
    await setTimeout defer(), 1000
    page.render('security_check.png')
    await spawn("open", ["security_check.png"]).on('exit', defer())

    # EXPERIMENTAL prompt
    system.stdout.write('Captcha: ')
    captcha = system.stdin.readLine()
    input('#recaptcha_response_field', captcha)
    click('#body_content_btnContinue')

    # see what happens
    await setTimeout defer(), 1000
    diagnosticRender('security check')

    # XXX alas, the captcha has different flow
    phantom.exit(2)

if exists('#changeserv')
    # "This address already has Verizon service."
    console.log("address already has Verizon")

    # "Add or change existing service"
    click('#rdoNoNotMine')

    await waitfor('#dvMoreDetailsIfNotMine', defer())
    #await setTimeout defer(), 1000
    diagnosticRender('change service')
    click('#rdoNoAmMovingThere')

    click('#body_content_btnContinue')

    # XXX waitfor
    await setTimeout defer(), 1000
    diagnosticRender('existing service')
    #await waitfor...

if exists('#dvAddressOption2')
    console.warn('ambiguous address; picking first')
    diagnosticRender('ambiguous address')
    first_address = scrape('#dvAddressOption0')?.innerText
    console.log("first address #{first_address}")
    click('#dvAddressOption0 a')
    click('#body_content_btnContinue')

else if exists('#dvAddressOption0')
    # "Is this your address?"  Yes.
    verified_address = scrape('#body_content_dvAddress address')?.innerText
    console.log("verified address #{verified_address}")
    click('#body_content_btnContinue')

diagnosticRender('checking availability')
console.log "checking availability..."
await waitfor('#checkavailability', defer())

withSelectorMarked('.products_list h4', -> diagnosticRender('products'))
await setTimeout defer(), 1000
products = page.evaluate ->
    (product.innerHTML for product in document.querySelectorAll('.products_list h4'))
products = (product for product in products when /fios/i.test(product))
products = products.join(', ')

console.log("#{products or 'nothing'} at #{verified_address or first_address}")

diagnosticRender('done')
#await spawn("open", ["fioscheck.png"]).on 'exit', defer()

page.close()

phantom.exit()
