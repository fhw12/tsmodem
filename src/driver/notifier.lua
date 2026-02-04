local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local log = require "tsmodem.util.log"
local uloop = require "uloop"

require "tsmodem.driver.util"


local notifier = {}

notifier.modem = nil
notifier.state = nil
notifier.timer = nil

notifier.init = function(modem, state, timer)
    notifier.modem = modem
    notifier.state = state
    notifier.timer = timer
end

function notifier:fire(ev_name, ev_payload)
	notifier.state.conn:notify(notifier.state.ubus_methods["tsmodem.driver"].__ubusobj, ev_name, ev_payload)
	if_debug(notifier.modem.debug_type, "NOTIFY", ev_name, ev_payload, string.format("[driver/notifier.lua]: Event [%s] occured when modem automation is [%s].", tostring(ev_name), tostring(notifier.modem.lock.is_notify())))
end

return notifier
