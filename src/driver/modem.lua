
local socket = require "socket"
local bit = require "bit"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local log = require "tsmodem.util.log"
local uloop = require "uloop"
local sys  = require "luci.sys"

local M = require 'posix.termio'
local F = require 'posix.fcntl'
local U = require 'posix.unistd'

local checkubus = require "tsmodem.util.checkubus"

-- Constants & utils
local AT_RELATED_UBUS_METHODS = require 'tsmodem.constants.AT_related_ubus_methods'

require "tsmodem.util.split_string"
require "tsmodem.driver.util"


-- AT Manual Specification related
local spec_V300_ch3 = require "tsmodem.spec.v300_ch3"
local spec_V300_ch4 = require "tsmodem.spec.v300_ch4"
local spec_V300_ch9 = require "tsmodem.spec.v300_ch9"

local def_events = require "tsmodem.constants.def_events"

local lock = require "tsmodem.driver.lock"

--local check_host = require 'tsmodem.parser.hostip'

local modem = {}
modem.debug = (uci:get("tsmodem", "debug", "enable") == "1") and true
modem.debug_type = uci:get("tsmodem", "debug", "type")

modem.device = arg[1] or '/dev/ttyUSB1'         -- First port
modem.fds = nil                                 -- File descriptor for /dev/ttyUSB2
modem.fds_ev = nil      						-- Event loop descriptor
modem.ws_fds = nil								-- Websocket file descriptor
modem.ws_fds_ev = nil
modem.ws_pipeout_file = "/tmp/wspipeout.fifo"	-- Gwsocket creates it
modem.ws_pipein_file = "/tmp/wspipein.fifo" -- Gwsocket creates it
modem.defined_events = {}
modem.lock = lock

-- [[ UCI staff ]]
modem.config = "tsmodem"
modem.config_gsm = "tsmodem_adapter_provider"
modem.section = "sim"


function modem:init()
	if not self:is_connected(modem.fds) then

		if_debug(modem.debug_type, "INIT 1", "", "", "")

		modem:unpoll()
		if modem.fds then
			if_debug(modem.debug_type, "INIT 2", "", "", "")
			U.close(modem.fds)
			modem.state:update("usb", "disconnected", modem.device .. " close")
			modem.state:update("reg", "7", "AT+CREG?")
			modem.state:update("signal", "", "AT+CSQ")
			modem.state:update("cpin","", "","")
		end

		local fds, err, errnum = F.open(modem.device, bit.bor(F.O_RDWR, F.O_NONBLOCK))
		if fds then
			local term_attrs = M.tcsetattr(fds, 0, {
			   cflag = M.B115200 + M.CS8 + M.CLOCAL + M.CREAD,
			   iflag = M.IGNPAR,
			   oflag = M.OPOST,
			   cc = {
			      [M.VTIME] = 0,
			      [M.VMIN] = 1,
			   }
			})
			modem.fds = fds
			-- Принудительный перевод модема в режим Text
			U.write(modem.fds, "AT+CMGF=1\r\n")
			--
			local ok, err, sim_id = modem.state:get("sim", "value")
			if ok and (sim_id == "1" or sim_id == "0") then
                local provider_id = get_provider_id(sim_id)
				local apn_provider = uci:get(modem.config_gsm, provider_id, "gate_address") or "APNP"
				local apn_network = uci:get("network", "tsmodem", "apn") or "APNN"
				if(apn_provider ~= apn_network) then
					uci:set("network", "tsmodem", "apn", apn_provider)
					uci:save("network")
					uci:commit("network")
				end
			end

			modem.state:update("usb", "connected", modem.device .. " open", "")
			modem.state:update("reg", "7", "AT+CREG?", "")
			modem.state:update("signal", "", "AT+CSQ", "")
			modem.state:update("cpin","", "","")

		end
	end
end

function modem:is_connected(fd)
	return fd and U.isatty(fd)
end

function modem:poll()
	if (modem.fds_ev == nil) and modem:is_connected(modem.fds) then
		modem.fds_ev = uloop.fd_add(modem.fds, function(ufd, events)

			local message_from_browser, message_to_browser = "", ""
			local chunk, err, errcode = U.read(modem.fds, 1024)

			if (err) then
				if_debug(modem.debug_type, "POLL", err, chunk, "[modem.lua]: " .. string.format("tsmodem: U.read(modem.fds, 1024) ERROR CODE: %s", tostring(errcode)))
			end

			if not err then
				spec_V300_ch3:parse_AT(modem, chunk)
				spec_V300_ch4:parse_AT(modem, chunk) -- balance via USSD, sim provider_id check
				spec_V300_ch9:parse_AT(modem, chunk)

				if modem.lock.is_notify() then
					local event_name = "AT-ANSWER"
					local payload = {
						answer = chunk,
					}
					modem.notifier:fire(event_name, payload)
				end
			else
				if (modem.debug and (util.contains(AT_RELATED_UBUS_METHODS, modem.debug_type) or modem.debug_type == "all")) then
					if_debug(modem.debug_type, "FILE", "POLL", "ERROR", "[modem.lua]: " .. string.format("tsmodem: U.read(modem.fds, 1024) ERROR CODE: %s", tostring(errcode)))
				end
			end
		end, uloop.ULOOP_READ)
	end
end

function modem:unpoll()
	if(modem.fds_ev) then
		modem.fds_ev:delete()
		modem.fds_ev = nil
		if (modem.debug) then print("MODEM UNPOLLED") end
	end
end

function modem:close()
	if(modem.fds) then
		U.close(modem.fds)
		if (modem.debug) then print("MODEM FD CLOSED") end
	end
end

-- [[ Initialize ]]
local metatable = {
	__call = function(modem, state, timer, notifier)
        modem.state = state
        modem.timer = timer
        modem.notifier = notifier

        modem.defined_events = def_events

		local self_lock = modem.lock.is_owner_or_set_if_unlocked("self")
		print("self_lock: ", self_lock)

        modem.state.init(modem, timer, notifier)
        modem.timer.init(modem, state, notifier)
        modem.notifier.init(modem, state, timer)

        modem.state:make_ubus()
		modem.state:tsmsms_subscribe_ubus()

		uloop.init()
		modem:poll()

		timer.general:set(timer.interval.general)
		timer.CPIN:set(timer.interval.cpin)
		timer.CREG:set(timer.interval.reg)
		timer.CSQ:set(timer.interval.signal)
		timer.COPS:set(timer.interval.provider)
		timer.CNSMOD:set(timer.interval.netmode)

		local unlock_status
		unlock_status, self_lock = modem.lock.unlock("self")
		print("self_lock: ", self_lock)

		uloop.run()
		state.conn:close()

		return table
	end
}
setmetatable(modem, metatable)

return modem
