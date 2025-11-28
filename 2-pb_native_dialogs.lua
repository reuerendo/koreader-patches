--[[
    User patch for KOReader to use native Pocketbook dialogs
    
    This patch modifies InfoMessage and ConfirmBox widgets to use native 
    Pocketbook SDK dialogs when running on Pocketbook devices.
    
    Installation:
    1. Place this file in koreader/patches/ directory
    2. The patch will be automatically loaded on startup
    
    Features:
    - Replaces InfoMessage with native Message() function
    - Replaces ConfirmBox with native DialogSynchro() function
    - Preserves all callbacks and behavior
    - Automatic icon mapping based on message type
    - Defers native dialogs to avoid blocking during startup
    - Debug logging for all message text and dialog parameters
]]

local Device = require("device")

-- Only apply patch on Pocketbook devices
if not Device:isPocketBook() then
    return
end

local logger = require("logger")
local ffi = require("ffi")
local UIManager = require("ui/uimanager")

logger.info("[PB Native Dialogs] Starting patch initialization...")

-- ============================================================================
-- NATIVE POCKETBOOK SDK DEFINITIONS
-- ============================================================================

-- Load Pocketbook SDK definitions
ffi.cdef[[
    // Icon types for dialogs
    static const int ICON_INFORMATION = 1;
    static const int ICON_QUESTION = 2;
    static const int ICON_WARNING = 3;
    static const int ICON_ERROR = 4;

    // Native message function with timeout in MILLISECONDS
    void Message(int icon, const char *title, const char *text, int timeout);
    
    // Synchronous dialog with up to 3 buttons (returns button index: 1, 2, or 3)
    int DialogSynchro(int icon, const char *title, const char *text, 
                      const char *button1, const char *button2, const char *button3);
]]

local inkview
local inkview_available = false

-- Try to load inkview library safely
local load_status, load_result = pcall(function()
    return ffi.load("inkview")
end)

if load_status then
    inkview = load_result
    inkview_available = true
    logger.info("[PB Native Dialogs] inkview library loaded successfully")
else
    logger.err("[PB Native Dialogs] Failed to load inkview library: " .. tostring(load_result))
    logger.err("[PB Native Dialogs] Native dialogs will be DISABLED")
end

-- ============================================================================
-- DEBUG HELPER FUNCTIONS
-- ============================================================================

--[[
    Helper function to count UTF-8 characters (compatible with Lua 5.1/LuaJIT)
]]
local function utf8_len(text)
    if not text then return 0 end
    local _, count = string.gsub(text, "[^\128-\193]", "")
    return count
end

--[[
    Remove bidirectional text control characters that are not supported by PocketBook fonts
    These characters (U+2066, U+2067, U+2068, U+2069, U+202A-U+202E) are used by KOReader
    for proper text direction handling but cause display issues in native dialogs
]]
local function removeBidiChars(text)
    if not text then return text end
    
    -- Remove the following Unicode bidirectional formatting characters:
    -- U+2066 (E2 81 A6) - LEFT-TO-RIGHT ISOLATE
    -- U+2067 (E2 81 A7) - RIGHT-TO-LEFT ISOLATE
    -- U+2068 (E2 81 A8) - FIRST STRONG ISOLATE
    -- U+2069 (E2 81 A9) - POP DIRECTIONAL ISOLATE
    -- U+202A (E2 80 AA) - LEFT-TO-RIGHT EMBEDDING
    -- U+202B (E2 80 AB) - RIGHT-TO-LEFT EMBEDDING
    -- U+202C (E2 80 AC) - POP DIRECTIONAL FORMATTING
    -- U+202D (E2 80 AD) - LEFT-TO-RIGHT OVERRIDE
    -- U+202E (E2 80 AE) - RIGHT-TO-LEFT OVERRIDE
    
    local cleaned = text
    -- Remove U+2066-U+2069
    cleaned = cleaned:gsub("\xE2\x81[\xA6-\xA9]", "")
    -- Remove U+202A-U+202E
    cleaned = cleaned:gsub("\xE2\x80[\xAA-\xAE]", "")
    
    return cleaned
end

--[[
    Helper function to safely log text with character information
]]
local function debugLogText(prefix, text)
    if not text then
        logger.dbg(string.format("[PB Native Dialogs] %s: <nil>", prefix))
        return
    end
    
    -- Log the full text
    logger.dbg(string.format("[PB Native Dialogs] %s: '%s'", prefix, text))
    
    -- Log text length and byte information
    local char_count = utf8_len(text)
    logger.dbg(string.format("[PB Native Dialogs] %s length: %d bytes, ~%d chars", 
        prefix, #text, char_count))
    
    -- Log first few characters with their byte values (for debugging encoding issues)
    local bytes_info = {}
    for i = 1, math.min(50, #text) do
        table.insert(bytes_info, string.format("%02X", string.byte(text, i)))
    end
    if #bytes_info > 0 then
        logger.dbg(string.format("[PB Native Dialogs] %s first bytes (hex): %s%s", 
            prefix, 
            table.concat(bytes_info, " "),
            #text > 50 and "..." or ""))
    end
end

-- ============================================================================
-- NATIVE DIALOG WRAPPER MODULE
-- ============================================================================

local PBNativeDialog = {
    -- Icon type constants
    ICON = {
        INFO = 1,
        QUESTION = 2,
        WARNING = 3,
        ERROR = 4,
    },
    enabled = inkview_available,
    ui_ready = false,  -- Track if UI loop is ready
}

-- Mark UI as ready after first run
UIManager:nextTick(function()
    PBNativeDialog.ui_ready = true
    logger.dbg("[PB Native Dialogs] UI is now ready for native dialogs")
end)

--[[
    Check if it's safe to show native dialogs
    Native dialogs block execution, so we must wait until UI loop is running
]]
function PBNativeDialog:isSafeToShow()
    if not self.enabled then
        logger.dbg("[PB Native Dialogs] isSafeToShow: disabled")
        return false
    end
    
    -- Wait until UI loop has started
    if not self.ui_ready then
        logger.dbg("[PB Native Dialogs] isSafeToShow: UI not ready yet")
        return false
    end
    
    logger.dbg("[PB Native Dialogs] isSafeToShow: OK")
    return true
end

--[[
    Show native Pocketbook message dialog (called via scheduler)
    
    @param text string - message text to display
    @param title string - dialog title
    @param timeout number - timeout in milliseconds
    @param icon number - icon type
]]
function PBNativeDialog:_showMessageNow(text, title, timeout, icon)
    logger.info("[PB Native Dialogs] === SHOWING MESSAGE ===")
    logger.info(string.format("[PB Native Dialogs] Icon: %d, Timeout: %d ms", icon, timeout))
    
    -- Clean text from bidirectional control characters
    local clean_title = removeBidiChars(title)
    local clean_text = removeBidiChars(text)
    
    debugLogText("Title", title)
    if clean_title ~= title then
        logger.dbg(string.format("[PB Native Dialogs] Title (cleaned): '%s'", clean_title))
        logger.dbg(string.format("[PB Native Dialogs] Removed %d bytes of bidi chars from title", #title - #clean_title))
    end
    
    debugLogText("Message text", text)
    if clean_text ~= text then
        logger.dbg(string.format("[PB Native Dialogs] Message text (cleaned): '%s'", clean_text))
        logger.dbg(string.format("[PB Native Dialogs] Removed %d bytes of bidi chars from text", #text - #clean_text))
    end
    
    local status, err = pcall(function()
        inkview.Message(icon, clean_title, clean_text, timeout)
    end)
    
    if not status then
        logger.err("[PB Native Dialogs] Message() failed: " .. tostring(err))
        return false
    end
    
    logger.info("[PB Native Dialogs] Message() executed successfully")
    return true
end

--[[
    Schedule native message to show on next UI tick
    
    @param text string - message text to display
    @param title string - dialog title (optional, defaults to "Information")
    @param timeout number - timeout in milliseconds (optional, default 3000)
    @param icon number - icon type (optional, defaults to INFO)
]]
function PBNativeDialog:showMessage(text, title, timeout, icon)
    if not self.enabled then
        logger.dbg("[PB Native Dialogs] showMessage: disabled, skipping")
        return false
    end
    
    title = title or "Information"
    timeout = timeout or 3000
    icon = icon or self.ICON.INFO
    
    -- Ensure minimum timeout of 1000ms (1 second) if specified
    if timeout > 0 and timeout < 1000 then
        timeout = 1000
    end
    
    logger.dbg("[PB Native Dialogs] showMessage: scheduling message for next tick")
    
    -- Schedule to show on next tick to avoid blocking
    UIManager:nextTick(function()
        self:_showMessageNow(text, title, timeout, icon)
    end)
    
    return true
end

--[[
    Show native Pocketbook dialog with buttons (called via scheduler)
    
    @param text string - dialog text
    @param title string - dialog title
    @param button1 string - first button text
    @param button2 string - second button text
    @param button3 string - third button text
    @param icon number - icon type
    @param callback function - callback to execute with result
]]
function PBNativeDialog:_showDialogNow(text, title, button1, button2, button3, icon, callback)
    logger.info("[PB Native Dialogs] === SHOWING DIALOG ===")
    logger.info(string.format("[PB Native Dialogs] Icon: %d", icon))
    
    -- Clean all text from bidirectional control characters
    local clean_title = removeBidiChars(title)
    local clean_text = removeBidiChars(text)
    local clean_button1 = removeBidiChars(button1)
    local clean_button2 = removeBidiChars(button2)
    local clean_button3 = removeBidiChars(button3)
    
    debugLogText("Title", title)
    if clean_title ~= title then
        logger.dbg(string.format("[PB Native Dialogs] Title (cleaned): '%s'", clean_title))
    end
    
    debugLogText("Dialog text", text)
    if clean_text ~= text then
        logger.dbg(string.format("[PB Native Dialogs] Dialog text (cleaned): '%s'", clean_text))
        logger.dbg(string.format("[PB Native Dialogs] Removed %d bytes of bidi chars from dialog text", #text - #clean_text))
    end
    
    debugLogText("Button 1", button1)
    if clean_button1 ~= button1 then
        logger.dbg(string.format("[PB Native Dialogs] Button 1 (cleaned): '%s'", clean_button1))
    end
    
    debugLogText("Button 2", button2)
    if clean_button2 ~= button2 then
        logger.dbg(string.format("[PB Native Dialogs] Button 2 (cleaned): '%s'", clean_button2))
    end
    
    debugLogText("Button 3", button3)
    if button3 and clean_button3 ~= button3 then
        logger.dbg(string.format("[PB Native Dialogs] Button 3 (cleaned): '%s'", clean_button3))
    end
    
    local status, result = pcall(function()
        return inkview.DialogSynchro(icon, clean_title, clean_text, clean_button1, clean_button2, clean_button3)
    end)
    
    if not status then
        logger.err("[PB Native Dialogs] DialogSynchro() failed: " .. tostring(result))
        return nil
    end
    
    logger.info(string.format("[PB Native Dialogs] DialogSynchro() returned: %d", result))
    
    -- Execute callback with result
    if callback then
        logger.dbg("[PB Native Dialogs] Executing callback with result: " .. tostring(result))
        callback(result)
    end
    
    return result
end

--[[
    Schedule native dialog to show on next UI tick
    
    @param text string - dialog text
    @param title string - dialog title (optional, defaults to "Confirm")
    @param button1 string - first button text (optional, defaults to "OK")
    @param button2 string - second button text (optional, defaults to nil)
    @param button3 string - third button text (optional, defaults to nil)
    @param icon number - icon type (optional, defaults to QUESTION)
    @param callback function - callback to execute with result
]]
function PBNativeDialog:showDialog(text, title, button1, button2, button3, icon, callback)
    if not self.enabled then
        logger.dbg("[PB Native Dialogs] showDialog: disabled, skipping")
        return nil
    end
    
    title = title or "Confirm"
    button1 = button1 or "OK"
    icon = icon or self.ICON.QUESTION
    
    logger.dbg("[PB Native Dialogs] showDialog: scheduling dialog for next tick")
    
    -- Schedule to show on next tick to avoid blocking
    UIManager:nextTick(function()
        self:_showDialogNow(text, title, button1, button2, button3, icon, callback)
    end)
    
    return true
end

-- ============================================================================
-- INFOMESSAGE WIDGET PATCH
-- ============================================================================

local InfoMessage = require("ui/widget/infomessage")

-- Store original methods
local original_infomessage_new = InfoMessage.new

--[[
    Override InfoMessage:new to intercept and show native dialogs
]]
function InfoMessage:new(args)
    logger.dbg("[PB Native Dialogs] InfoMessage:new() called")
    
    -- Check if we should use native dialogs
    if args.text and PBNativeDialog:isSafeToShow() then
        logger.dbg("[PB Native Dialogs] InfoMessage: using native dialog")
        
        -- Determine icon type based on message content or icon field
        local icon = PBNativeDialog.ICON.INFO
        
        if args.icon then
            logger.dbg(string.format("[PB Native Dialogs] InfoMessage icon field: '%s'", args.icon))
            -- Map icon names to native icons
            if args.icon == "notice-warning" or args.icon == "warning" then
                icon = PBNativeDialog.ICON.WARNING
            elseif args.icon == "notice-error" or args.icon == "error" then
                icon = PBNativeDialog.ICON.ERROR
            elseif args.icon == "notice-question" or args.icon == "question" then
                icon = PBNativeDialog.ICON.QUESTION
            end
        end
        
        -- Convert timeout from seconds to milliseconds
        local timeout_ms = (args.timeout or 3) * 1000
        
        logger.dbg(string.format("[PB Native Dialogs] InfoMessage timeout: %d seconds = %d ms", 
            args.timeout or 3, timeout_ms))
        
        -- Show native dialog (scheduled)
        PBNativeDialog:showMessage(args.text, "KOReader", timeout_ms, icon)
        
        -- If there's a dismiss callback, schedule it
        if args.dismiss_callback then
            logger.dbg("[PB Native Dialogs] InfoMessage: scheduling dismiss callback")
            UIManager:scheduleIn(args.timeout or 3, args.dismiss_callback)
        end
        
        -- Return fake widget that blocks showing
        local Widget = require("ui/widget/widget")
        local fake = Widget:new{}
        fake._is_native = true
        fake.modal = args.modal
        fake.dimen = {x=0, y=0, w=0, h=0}
        
        -- Override all display methods to do nothing
        fake.paintTo = function() end
        fake.onShow = function() 
            -- Auto-close after timeout
            if args.timeout and args.timeout > 0 then
                UIManager:scheduleIn(args.timeout, function()
                    UIManager:close(fake)
                end)
            end
        end
        fake.onCloseWidget = function() end
        
        return fake
    end
    
    -- Fall back to original implementation
    logger.dbg("[PB Native Dialogs] InfoMessage: falling back to original implementation")
    return original_infomessage_new(self, args)
end

-- ============================================================================
-- CONFIRMBOX WIDGET PATCH
-- ============================================================================

local ConfirmBox = require("ui/widget/confirmbox")

-- Store original methods
local original_confirmbox_new = ConfirmBox.new

--[[
    Override ConfirmBox:new to intercept and show native dialogs
]]
function ConfirmBox:new(args)
    logger.dbg("[PB Native Dialogs] ConfirmBox:new() called")
    
    -- Check if we should use native dialogs
    if args.text and PBNativeDialog:isSafeToShow() then
        logger.dbg("[PB Native Dialogs] ConfirmBox: using native dialog")
        
        -- Determine icon type
        local icon = PBNativeDialog.ICON.QUESTION
        
        -- Prepare button texts
        local ok_text = args.ok_text or "OK"
        local cancel_text = args.cancel_text or "Cancel"
        local third_button = nil
        
        logger.dbg(string.format("[PB Native Dialogs] ConfirmBox buttons: OK='%s', Cancel='%s'", 
            ok_text, cancel_text))
        
        -- Check for additional buttons
        if args.other_buttons and #args.other_buttons > 0 then
            if args.other_buttons[1] and args.other_buttons[1][1] then
                third_button = args.other_buttons[1][1].text
                logger.dbg(string.format("[PB Native Dialogs] ConfirmBox third button: '%s'", 
                    third_button))
            end
        end
        
        -- Store callbacks
        local callbacks = {
            ok = args.ok_callback,
            cancel = args.cancel_callback,
            other = args.other_buttons and args.other_buttons[1] and 
                    args.other_buttons[1][1] and args.other_buttons[1][1].callback
        }
        
        logger.dbg(string.format("[PB Native Dialogs] ConfirmBox callbacks: ok=%s, cancel=%s, other=%s",
            callbacks.ok and "present" or "nil",
            callbacks.cancel and "present" or "nil",
            callbacks.other and "present" or "nil"))
        
        -- Return fake widget that blocks showing
        local Widget = require("ui/widget/widget")
        local fake = Widget:new{}
        fake._is_native = true
        fake.modal = args.modal
        fake.dimen = {x=0, y=0, w=0, h=0}
        
        -- Override all display methods to do nothing
        fake.paintTo = function() end
        fake.onCloseWidget = function() end
        
        -- onShow will trigger the native dialog
        fake.onShow = function()
            logger.dbg("[PB Native Dialogs] ConfirmBox fake widget onShow() called")
            
            -- Create callback handler
            local callback = function(result)
                logger.info(string.format("[PB Native Dialogs] ConfirmBox callback received result: %d", result))
                
                -- Result: 1=Cancel, 2=OK, 3=Other
                if result == 2 and callbacks.ok then
                    logger.dbg("[PB Native Dialogs] Executing OK callback")
                    local status, err = pcall(callbacks.ok)
                    if not status then
                        logger.err("[PB Native Dialogs] OK callback error: " .. tostring(err))
                    end
                elseif result == 1 and callbacks.cancel then
                    logger.dbg("[PB Native Dialogs] Executing Cancel callback")
                    local status, err = pcall(callbacks.cancel)
                    if not status then
                        logger.err("[PB Native Dialogs] Cancel callback error: " .. tostring(err))
                    end
                elseif result == 3 and callbacks.other then
                    logger.dbg("[PB Native Dialogs] Executing Other callback")
                    local status, err = pcall(callbacks.other)
                    if not status then
                        logger.err("[PB Native Dialogs] Other callback error: " .. tostring(err))
                    end
                end
                
                -- Close the fake widget
                logger.dbg("[PB Native Dialogs] Closing fake widget")
                UIManager:close(fake)
            end
            
            -- Show native dialog (scheduled to avoid blocking)
            PBNativeDialog:showDialog(
                args.text,
                "KOReader",
                cancel_text,
                ok_text,
                third_button,
                icon,
                callback
            )
        end
        
        return fake
    end
    
    -- Fall back to original implementation
    logger.dbg("[PB Native Dialogs] ConfirmBox: falling back to original implementation")
    return original_confirmbox_new(self, args)
end

-- ============================================================================
-- LOGGING
-- ============================================================================

if PBNativeDialog.enabled then
    logger.info("[PB Native Dialogs] Patch applied successfully")
    logger.info("[PB Native Dialogs] - InfoMessage → native Message() (deferred to UI tick)")
    logger.info("[PB Native Dialogs] - ConfirmBox → native DialogSynchro() (deferred to UI tick)")
    logger.info("[PB Native Dialogs] - Debug logging enabled for all messages and dialogs")
else
    logger.warn("[PB Native Dialogs] Patch loaded but DISABLED due to library load failure")
end

-- Export patched modules (optional, for compatibility)
return {
    InfoMessage = InfoMessage,
    ConfirmBox = ConfirmBox,
    PBNativeDialog = PBNativeDialog,
}