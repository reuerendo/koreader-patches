-- User patch to keep previous screen visible during book loading
-- Place this file in koreader/patches/

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Device = require("device") -- Добавлен для обработки ошибок (Device:setIgnoreInput)
local Input = require("device/input") -- Добавлен для обработки ошибок
local InfoMessage = require("ui/widget/infomessage") -- Добавлен для сообщения об ошибке

logger.info("KeepPreviousScreen patch: initializing")

-- Configuration
local enabled = G_reader_settings:nilOrTrue("keep_previous_screen_enabled")

-- Hook into ReaderUI
local ReaderUI = require("apps/reader/readerui")

-- Store original method
if not ReaderUI._original_showReaderCoroutine_keepscreen then
    ReaderUI._original_showReaderCoroutine_keepscreen = ReaderUI.showReaderCoroutine
    
    -- Override showReaderCoroutine
    ReaderUI.showReaderCoroutine = function(self, file, provider, seamless)
        if enabled then
            logger.info("KeepPreviousScreen patch: loading immediately with seamless=true")
            
            -- Мы убрали UIManager:nextTick, чтобы виджет создавался синхронно
            -- и не вызывал закрытие UIManager из-за пустого стека
            local co = coroutine.create(function()
                -- Load document without showing intermediate states
                -- Force seamless = true
                self:doShowReader(file, provider, true) 
            end)
            
            local ok, err = coroutine.resume(co)
            if err ~= nil or ok == false then
                io.stderr:write('[!] doShowReader coroutine crashed:\n')
                io.stderr:write(debug.traceback(co, err, 1))
                
                -- Restore input if crashed
                Device:setIgnoreInput(false)
                Input:inhibitInputUntil(0.2)
                
                UIManager:show(InfoMessage:new{
                    text = "Error loading document",
                })
            end
        else
            -- Call original method
            return ReaderUI._original_showReaderCoroutine_keepscreen(self, file, provider, seamless)
        end
    end
    
    logger.info("KeepPreviousScreen patch: successfully patched ReaderUI.showReaderCoroutine")
end

logger.info("KeepPreviousScreen patch: initialized successfully")