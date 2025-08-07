local util = require "luci.util"
local uloop = require "uloop"
local uci = require "luci.model.uci".cursor()

--[[
	Этот подмодуль отвечает за разбор, т.е. парсиниг AT ответов от модема согласно 
	SIM7500_SIM7600 Series_AT Command Manual V3.00 2021.5.18, Chapter 9. AT Commands for SMS
]]

local U = require 'posix.unistd'

local cmgs_ok = require 'tsmodem.parser.cmgs_ok'
local cmgs_error = require 'tsmodem.parser.cmgs_error'
local remote_control_pars = require 'tsmodem.parser.parser_sms'
local pdu_decoder = require 'tsmodem.util.pdu_decoder'

require "tsmodem.driver.util"

local v300_ch9 = {}
v300_ch9.modem = nil
v300_ch9.resive_sms_counter = nil
v300_ch9.read_sms_timer = nil

-- [modem] is a link to modem.lua functable
function v300_ch9:parse_AT(modem, chunk)
	self.modem = modem
	if chunk:find("+CMTI:") then
		self.resive_sms_counter = remote_control_pars:get_sms_count(chunk)
		if_debug("remote_control", "AT", "NOTIFY", self.resive_sms_counter, "[spec/v300_ch9.lua]: +CMTI new sms receive, sms count=" .. tostring(self.resive_sms_counter))
		-- Задержка для модема, дающая время на обработку запроса
		self.read_sms_timer = uloop.timer(v300_ch9:AtCommandReadSMS())
		self.read_sms_timer:set(3000) -- Задержка 3 сек

	-- Обработать ответ и выделить тело смс.
	elseif chunk:find("+CMGR:") then
		local pdu_data = ""
        local shift = 2

        if chunk:find("OK") then
            shift = 8
        end

        for i = #chunk - shift, 1, -1 do
            if chunk:sub(i, i) == '\n' then break end
            pdu_data = chunk:sub(i, i) .. pdu_data
        end

		local parsed_sms = pdu_decoder.parse(pdu_data)

		-- Запись принятых данных в state: [param, value, command, comment]
		v300_ch9.modem.state:update("remote_control", tostring(parsed_sms.sender_number), tostring(parsed_sms.message_text), "+CMGR:".. tostring(self.resive_sms_counter))
		if_debug("remote_control", "AT", "ANSWER", parsed_sms.sender_number, "[spec/v300_ch9.lua]: +CMGR Sender Phone Number")
		if_debug("remote_control", "AT", "ANSWER", parsed_sms.message_text, "[spec/v300_ch9.lua]: +CMGR Resive Command")

		local event_name = v300_ch9.modem.defined_events[4]
		local event_payload = {
			answer = chunk,
			["sms_phone"] = parsed_sms.sender_number,
			["sms_command"] = parsed_sms.message_text,
		}
		v300_ch9.modem.notifier:fire(event_name, event_payload)


		-- nil ERROR in self.resive_sms_counter, code commented for now --
		--
		-- Удалить все СМС если их колличество больше 10
		-- if (self.resive_sms_counter > 6) then
		-- 	-- Отправить команду в модем на удаление смс 
		-- 	U.write(v300_ch9.modem.fds, "AT+CMGD=,1" .. "\r\n")
		-- 	if_debug("remote_control", "AT", "ANSWER", self.resive_sms_counter, "[spec/v300_ch9.lua]: SMS storage limited. Deleteting all read messages.")
		-- end

	elseif (chunk:find("AT%+CMGS=") or chunk:find("%+CMGS: ") or chunk:find("%+CMS ERROR")) then
		local removed_ctrlZ_chunk = chunk:gsub("%c", " ")
		local is_sms_sent_ok = cmgs_ok:match(removed_ctrlZ_chunk) and type(cmgs_ok:match(removed_ctrlZ_chunk) == "string")
		local is_sms_sent_error = cmgs_error:match(removed_ctrlZ_chunk) and type(cmgs_error:match(removed_ctrlZ_chunk) == "string")

		if_debug("send_at", "v300_ch9.lua", removed_ctrlZ_chunk, cmgs_ok:match(removed_ctrlZ_chunk), "")

		local event_name = ""
		local event_payload = {}

		if is_sms_sent_ok then
			event_name = v300_ch9.modem.defined_events[2]
			event_payload = {
				answer = cmgs_ok:match(removed_ctrlZ_chunk),
				automation = v300_ch9.modem.automation
			}
			v300_ch9.modem.notifier:fire(event_name, event_payload)
			if_debug("send_at", "NOTIFY", event_name, cmgs_ok:match(removed_ctrlZ_chunk), string.format("[spec/v300_ch9.lua]: %s event", event_name))
		elseif is_sms_sent_error then
			event_name = v300_ch9.modem.defined_events[3]
			event_payload = {
				answer = cmgs_error:match(removed_ctrlZ_chunk),
				automation = v300_ch9.modem.automation
			}
			v300_ch9.modem.notifier:fire(event_name, event_payload)
			if_debug("send_at", "NOTIFY", event_name, cmgs_error:match(removed_ctrlZ_chunk), string.format("[spec/v300_ch9.lua]: %s event", event_name))
		else
			event_name = v300_ch9.modem.defined_events[1]
			event_payload = {
				answer = removed_ctrlZ_chunk,
				automation = v300_ch9.modem.automation
			}
			if_debug("send_at", "NOTIFY", event_name, removed_ctrlZ_chunk, string.format("[spec/v300_ch9.lua]: %s event", event_name))
		end
	elseif chunk:match("+CMGS:") then
		--modem.state.conn:notify(modem.state.ubus_methods["tsmodem.driver"].__ubusobj, "SMS-SENT", {answer = chunk} )
	end
end

-- Обработчик для чтения СМС
function v300_ch9:AtCommandReadSMS()
	return function()
		-- Запрос в модем на считывание принятой смс
		local at_set_PDU_mode = "\r\nAT+CMGF=0\r\n"
		U.write(v300_ch9.modem.fds, at_set_PDU_mode)
		local at_get_sms_counter = "\r\nAT+CMGR=" .. tostring(v300_ch9.resive_sms_counter) .. "\r\n"
		U.write(v300_ch9.modem.fds, at_get_sms_counter)
		if_debug("remote_control", "AT", "ANSWER", at_get_sms_counter, "[modem.lua]: Send AT to read SMS")
		v300_ch9.read_sms_timer:cancel() -- отмена таймера
	end
end

-- function v300_ch9:notifier(chunk)
-- 	-- Send notification only when web-cosole is opened. E.g. when modem automation mode is "stop".
-- 	if self.modem.automation == "stop" then
-- 		self.modem.state.conn:notify( modem.state.ubus_methods["tsmodem.driver"].__ubusobj, "AT-answer", {answer = chunk} )
-- 		if string.find(chunk, "tsmsms") then
-- 			if_debug("remote_control", "AT", "ANSWER", at_get_sms_counter, "[modem.lua]: Send AT to read SMS")
-- 			print("[modem.lua] send_AT_responce_to_webconsole(SMS-SENT")
-- 			modem.state.conn:notify( modem.state.ubus_methods["tsmodem.driver"].__ubusobj, "SMS-SENT", {answer = chunk} )
-- 		end
-- 		if (modem.debug and (util.contains(AT_RELATED_UBUS_METHODS, modem.debug_type) or modem.debug_type == "all")) then
-- 			if_debug(modem.debug_type, "UBUS", "NOTIFY", {answer = chunk}, "[modem.lua]: tsmodem.driver notifies subscribers, e.g. when AT-response sent to web-console.")
-- 		end
-- 	end
-- end

return v300_ch9