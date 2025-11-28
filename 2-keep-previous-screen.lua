-- User patch to keep previous screen visible during book loading
-- Place this file in koreader/patches/
-- This avoids the white flash by not forcing repaint until content is ready

local logger = require("logger")
local UIManager = require("ui/uimanager")

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
            logger.info("KeepPreviousScreen patch: loading without intermediate repaint")
            
            -- Don't show loading message and don't force repaint
            -- Just start loading in background
            UIManager:nextTick(function()
                logger.dbg("KeepPreviousScreen: creating coroutine for showing reader")
                local co = coroutine.create(function()
                    -- Load document without showing intermediate states
                    self:doShowReader(file, provider, true) -- seamless=true
                end)
                
                local ok, err = coroutine.resume(co)
                if err ~= nil or ok == false then
                    io.stderr:write('[!] doShowReader coroutine crashed:\n')
                    io.stderr:write(debug.traceback(co, err, 1))
                    
                    -- Restore input if crashed
                    Device:setIgnoreInput(false)
                    Input:inhibitInputUntil(0.2)
                    
                    UIManager:show(InfoMessage:new{
                        text = _("Error loading document"),
                    })
                end
            end)
        else
            -- Call original method
            return ReaderUI._original_showReaderCoroutine_keepscreen(self, file, provider, seamless)
        end
    end
    
    logger.info("KeepPreviousScreen patch: successfully patched ReaderUI.showReaderCoroutine")
end

logger.info("KeepPreviousScreen patch: initialized successfully")