local util = require "luci.util"
local uloop = require "uloop"
local uci = require "luci.model.uci".cursor()

--[[
	Этот подмодуль отвечает за разбор - парсиниг AT ответов от модема согласно 
	SIM7500_SIM7600 Series_AT Command Manual V3.00 2021.5.18, Chapter 3. AT Commands According to V.25TER
]]

local CPIN_parser = require 'tsmodem.parser.cpin'
local CREG_parser = require 'tsmodem.parser.creg'
local CSQ_parser = require 'tsmodem.parser.csq'

local notifier = require "tsmodem.driver.notifier"

require "tsmodem.driver.util"

local v300_ch3 = {}

-- [modem] is a link to modem.lua functable
function v300_ch3:parse_AT(modem, chunk)
	if (chunk:find("+CME ERROR") or chunk:find("+CPIN: READY") or chunk:find("+SIMCARD: NOT AVAILABLE")) then
		local cpin = CPIN_parser:match(chunk)
		if_debug("cpin", "AT", "ANSWER", cpin, "[spec/v300_ch3.lua]: chunk: " .. chunk:gsub("%c+", " "))
		local _,_, SWITCHING = modem.state:get("switching", "value")
		if cpin and (SWITCHING ~= "true") and (cpin == "true" or cpin == "false" or cpin == "failure") then
			modem.state:update("cpin", cpin, "AT+CPIN?", "")
			return
		end
	elseif chunk:find("+CREG:") then
		local creg = CREG_parser:match(chunk)
		if_debug("reg", "AT", "ANSWER", creg, "[spec/v300_ch3.lua]: chunk: " .. chunk:gsub("%c+", " "))
		if creg and creg ~= "" then
			modem.state:update("reg", creg, "AT+CREG?", "")
			modem.state:update("usb", "connected", modem.device .. " open", "")
		end
	elseif chunk:find("+CSQ:") then
		local signal = CSQ_parser:match(chunk)
		if_debug("signal", "AT", "ANSWER", signal, "[spec/v300_ch3.lua]: +CSQ parsed every " .. tostring(modem.timer.interval.signal).."ms")
		--local no_signal_aliase = {"0", "99", "31", "nil", nil, ""}
		local no_signal_aliase = {"99", "nil", nil, ""}
		if not util.contains(no_signal_aliase, signal) then
			signal = tonumber(signal) or false
			if (signal and signal >= 0 and signal <= 31) then signal = math.ceil(signal * 100 / 31) else signal = "" end
		else
			signal = ""
		end
		modem.state:update("signal", tostring(signal), "AT+CSQ", "")
	end
end

return v300_ch3