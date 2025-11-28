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
end)

--[[
    Check if it's safe to show native dialogs
    Native dialogs block execution, so we must wait until UI loop is running
]]
function PBNativeDialog:isSafeToShow()
    if not self.enabled then
        return false
    end
    
    -- Wait until UI loop has started
    if not self.ui_ready then
        return false
    end
    
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
    local status, err = pcall(function()
        inkview.Message(icon, title, text, timeout)
    end)
    
    if not status then
        logger.err("[PB Native Dialogs] Message() failed: " .. tostring(err))
        return false
    end
    
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
        return false
    end
    
    title = title or "Information"
    timeout = timeout or 3000
    icon = icon or self.ICON.INFO
    
    -- Ensure minimum timeout of 1000ms (1 second) if specified
    if timeout > 0 and timeout < 1000 then
        timeout = 1000
    end
    
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
    local status, result = pcall(function()
        return inkview.DialogSynchro(icon, title, text, button1, button2, button3)
    end)
    
    if not status then
        logger.err("[PB Native Dialogs] DialogSynchro() failed: " .. tostring(result))
        return nil
    end
    
    -- Execute callback with result
    if callback then
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
        return nil
    end
    
    title = title or "Confirm"
    button1 = button1 or "OK"
    icon = icon or self.ICON.QUESTION
    
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
local original_infomessage_onshow = InfoMessage.onShow

--[[
    Override InfoMessage:new to intercept and show native dialogs
]]
function InfoMessage:new(args)
    -- Check if we should use native dialogs
    if args.text and PBNativeDialog:isSafeToShow() then
        -- Determine icon type based on message content or icon field
        local icon = PBNativeDialog.ICON.INFO
        
        if args.icon then
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
        
        -- Show native dialog (scheduled)
        local success = PBNativeDialog:showMessage(args.text, "KOReader", timeout_ms, icon)
        
        if not success then
            return original_infomessage_new(self, args)
        end
        
        -- Create minimal widget that does nothing visible
        local self = original_infomessage_new(self, {
            text = args.text,
            timeout = args.timeout or 3,
            invisible = true,
        })
        
        -- Mark as native
        self._is_native = true
        
        -- If there's a dismiss callback, schedule it
        if args.dismiss_callback then
            UIManager:scheduleIn(args.timeout or 3, args.dismiss_callback)
        end
        
        return self
    end
    
    -- Fall back to original implementation
    return original_infomessage_new(self, args)
end

--[[
    Override onShow to prevent double-showing for native dialogs
]]
function InfoMessage:onShow()
    if self._is_native then
        -- Already shown via native dialog, just schedule timeout
        if self.timeout and self.timeout > 0 then
            self._timeout_func = function()
                self._timeout_func = nil
                UIManager:close(self)
            end
            UIManager:scheduleIn(self.timeout, self._timeout_func)
        end
        return true
    end
    
    -- Use original show for non-native
    return original_infomessage_onshow(self)
end

-- ============================================================================
-- CONFIRMBOX WIDGET PATCH
-- ============================================================================

local ConfirmBox = require("ui/widget/confirmbox")

-- Store original methods
local original_confirmbox_new = ConfirmBox.new
local original_confirmbox_onshow = ConfirmBox.onShow

--[[
    Override ConfirmBox:new to intercept and show native dialogs
]]
function ConfirmBox:new(args)
    -- Check if we should use native dialogs
    if args.text and PBNativeDialog:isSafeToShow() then
        -- Determine icon type
        local icon = PBNativeDialog.ICON.QUESTION
        
        -- Prepare button texts
        local ok_text = args.ok_text or "OK"
        local cancel_text = args.cancel_text or "Cancel"
        local third_button = nil
        
        -- Check for additional buttons
        if args.other_buttons and #args.other_buttons > 0 then
            if args.other_buttons[1] and args.other_buttons[1][1] then
                third_button = args.other_buttons[1][1].text
            end
        end
        
        -- Create minimal widget for compatibility
        local self = original_confirmbox_new(self, {
            text = args.text,
            invisible = true,
        })
        
        -- Mark as native
        self._is_native = true
        self._native_callbacks = {
            ok = args.ok_callback,
            cancel = args.cancel_callback,
            other = args.other_buttons and args.other_buttons[1] and 
                    args.other_buttons[1][1] and args.other_buttons[1][1].callback
        }
        
        -- Create callback handler
        local callback = function(result)
            self:_executeNativeCallback(result)
            UIManager:close(self)
        end
        
        -- Show native dialog (scheduled)
        local success = PBNativeDialog:showDialog(
            args.text,
            "KOReader",
            cancel_text,
            ok_text,
            third_button,
            icon,
            callback
        )
        
        if not success then
            return original_confirmbox_new(self, args)
        end
        
        return self
    end
    
    -- Fall back to original implementation
    return original_confirmbox_new(self, args)
end

--[[
    Execute the appropriate callback based on native dialog result
]]
function ConfirmBox:_executeNativeCallback(result)
    if not self._is_native then
        return
    end
    
    local callbacks = self._native_callbacks
    
    -- Result: 1=Cancel, 2=OK, 3=Other
    if result == 2 and callbacks.ok then
        local status, err = pcall(callbacks.ok)
        if not status then
            logger.err("[PB Native Dialogs] OK callback error: " .. tostring(err))
        end
    elseif result == 1 and callbacks.cancel then
        local status, err = pcall(callbacks.cancel)
        if not status then
            logger.err("[PB Native Dialogs] Cancel callback error: " .. tostring(err))
        end
    elseif result == 3 and callbacks.other then
        local status, err = pcall(callbacks.other)
        if not status then
            logger.err("[PB Native Dialogs] Other callback error: " .. tostring(err))
        end
    end
end

--[[
    Override onShow to handle native dialog callbacks
]]
function ConfirmBox:onShow()
    if self._is_native then
        return true
    end
    
    -- Use original show for non-native
    return original_confirmbox_onshow(self)
end

-- ============================================================================
-- LOGGING
-- ============================================================================

if PBNativeDialog.enabled then
    logger.info("[PB Native Dialogs] Patch applied successfully")
    logger.info("[PB Native Dialogs] - InfoMessage → native Message() (deferred to UI tick)")
    logger.info("[PB Native Dialogs] - ConfirmBox → native DialogSynchro() (deferred to UI tick)")
else
    logger.warn("[PB Native Dialogs] Patch loaded but DISABLED due to library load failure")
end

-- Export patched modules (optional, for compatibility)
return {
    InfoMessage = InfoMessage,
    ConfirmBox = ConfirmBox,
    PBNativeDialog = PBNativeDialog,
}