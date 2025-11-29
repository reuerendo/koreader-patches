--[[
    User patch for KOReader to use native Pocketbook dialogs
    
    This patch modifies InfoMessage and ConfirmBox widgets to use native 
    Pocketbook SDK dialogs when running on Pocketbook devices.
    
    Installation:
    1. Place this file in koreader/patches/ directory
    2. The patch will be automatically loaded on startup
    
    Features:
    - Replaces InfoMessage with native Message() or DialogSynchro()
    - Long texts (>200 chars) automatically use DialogSynchro with OK button
    - Replaces ConfirmBox with native DialogSynchro() function
    - Preserves all callbacks and behavior
    - Automatic icon mapping based on message type
    - Blocks input during native dialog display to prevent freezing
    
    Fixes:
    - Added automatic detection of long texts for proper dialog type
    - Removed UIManager:scheduleIn to fix missing dialogs during blocking operations
    - Suppressed UIManager full-screen refresh after dialog closes (silent close)
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
    Remove bidirectional text control characters that are not supported by PocketBook fonts
]]
local function removeBidiChars(text)
    if not text then return text end
    
    local cleaned = text
    -- Remove U+2066-U+2069
    cleaned = cleaned:gsub("\xE2\x81[\xA6-\xA9]", "")
    -- Remove U+202A-U+202E
    cleaned = cleaned:gsub("\xE2\x80[\xAA-\xAE]", "")
    
    return cleaned
end

--[[
    Check if text is long enough to require DialogSynchro instead of Message
    Threshold: 200 characters or multiple paragraphs
]]
local function isLongText(text)
    if not text then return false end
    
    -- Check length
    if #text > 200 then
        return true
    end
    
    -- Check for multiple paragraphs (more than 2 line breaks)
    local _, newline_count = text:gsub("\n", "")
    if newline_count > 2 then
        return true
    end
    
    return false
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
    ui_ready = false,
    dialog_active = false,
}

-- Mark UI as ready after first run
UIManager:nextTick(function()
    PBNativeDialog.ui_ready = true
    logger.dbg("[PB Native Dialogs] UI is now ready for native dialogs")
end)

--[[
    Check if it's safe to show native dialogs
]]
function PBNativeDialog:isSafeToShow()
    if not self.enabled then return false end
    if not self.ui_ready then return false end
    if self.dialog_active then return false end
    return true
end

--[[
    Helper to silently close a widget without triggering a screen refresh.
    This relies on the fact that the native PB dialog handles restoring 
    the background pixels itself.
]]
function PBNativeDialog:silentClose(widget)
    if not widget then return end
    
    -- Save the original setDirty function
    local setDirty_orig = UIManager.setDirty
    
    -- Temporarily disable setDirty to prevent refresh triggers
    UIManager.setDirty = function() end
    
    -- Close the widget (this will now update the stack but NOT flag for repaint)
    local status, err = pcall(function() UIManager:close(widget) end)
    
    -- Restore the original setDirty function immediately
    UIManager.setDirty = setDirty_orig
    
    if not status then
        logger.err("[PB Native Dialogs] Error during silent close: " .. tostring(err))
        -- Fallback to normal close if something went wrong
        UIManager:close(widget)
    else
        logger.dbg("[PB Native Dialogs] Widget closed silently (no refresh triggered)")
    end
end

-- ============================================================================
-- INFOMESSAGE WIDGET PATCH
-- ============================================================================

local InfoMessage = require("ui/widget/infomessage")
local original_infomessage_new = InfoMessage.new

function InfoMessage:new(args)
    -- Check if we should use native dialogs
    if args.text and PBNativeDialog:isSafeToShow() then
        local use_long_dialog = isLongText(args.text)
        
        if use_long_dialog then
            logger.dbg("[PB Native Dialogs] InfoMessage: using DialogSynchro (long text)")
        else
            logger.dbg("[PB Native Dialogs] InfoMessage: using native Message (short text)")
        end
        
        local icon = PBNativeDialog.ICON.INFO
        if args.icon then
            if args.icon == "notice-warning" or args.icon == "warning" then
                icon = PBNativeDialog.ICON.WARNING
            elseif args.icon == "notice-error" or args.icon == "error" then
                icon = PBNativeDialog.ICON.ERROR
            elseif args.icon == "notice-question" or args.icon == "question" then
                icon = PBNativeDialog.ICON.QUESTION
            end
        end
        
        -- Create fake widget
        local Widget = require("ui/widget/widget")
        local fake = Widget:new{}
        fake._is_native = true
        fake.modal = args.modal
        fake.dimen = {x=0, y=0, w=0, h=0}
        
        fake.paintTo = function() end
        fake.onCloseWidget = function() end
        
        local dismiss_callback = args.dismiss_callback
        
        -- onShow will show native dialog IMMEDIATELY (Synchronously)
        fake.onShow = function()
            PBNativeDialog.dialog_active = true
            
            local status, err
            if use_long_dialog then
                -- Use DialogSynchro for long texts (with OK button)
                -- IMPORTANT: DialogSynchro requires at least button1 and button2
                -- button1 is displayed on the left (Cancel/Back position)
                -- button2 is displayed on the right (OK/Confirm position)
                -- We only want OK button, so we make button1 empty string
                status, err = pcall(function()
                    inkview.DialogSynchro(
                        icon,
                        "KOReader",
                        removeBidiChars(args.text),
                        "OK",
                        nil,
                        nil
                    )
                end)
            else
                -- Use Message for short texts (with timeout)
                local timeout_ms = (args.timeout or 3) * 1000
                status, err = pcall(function()
                    inkview.Message(icon, "KOReader", removeBidiChars(args.text), timeout_ms)
                end)
            end
            
            PBNativeDialog.dialog_active = false
            
            if not status then
                logger.err("[PB Native Dialogs] Native dialog failed: " .. tostring(err))
            end
            
            -- Close fake widget silently (no refresh)
            PBNativeDialog:silentClose(fake)
            
            -- Execute dismiss callback
            if dismiss_callback then
                pcall(dismiss_callback)
            end
        end
        
        return fake
    end
    
    return original_infomessage_new(self, args)
end

-- ============================================================================
-- CONFIRMBOX WIDGET PATCH
-- ============================================================================

local ConfirmBox = require("ui/widget/confirmbox")
local original_confirmbox_new = ConfirmBox.new

function ConfirmBox:new(args)
    -- Check if we should use native dialogs
    if args.text and PBNativeDialog:isSafeToShow() then
        logger.dbg("[PB Native Dialogs] ConfirmBox: using native dialog")
        
        local icon = PBNativeDialog.ICON.QUESTION
        local ok_text = args.ok_text or "OK"
        local cancel_text = args.cancel_text or "Cancel"
        local third_button = nil
        
        if args.other_buttons and #args.other_buttons > 0 then
            if args.other_buttons[1] and args.other_buttons[1][1] then
                third_button = args.other_buttons[1][1].text
            end
        end
        
        local callbacks = {
            ok = args.ok_callback,
            cancel = args.cancel_callback,
            other = args.other_buttons and args.other_buttons[1] and 
                    args.other_buttons[1][1] and args.other_buttons[1][1].callback
        }
        
        local Widget = require("ui/widget/widget")
        local fake = Widget:new{}
        fake._is_native = true
        fake.modal = args.modal
        fake.dimen = {x=0, y=0, w=0, h=0}
        
        fake.paintTo = function() end
        fake.onCloseWidget = function() end
        
        fake.onShow = function()
            PBNativeDialog.dialog_active = true
            
            local result = nil
            local status, err = pcall(function()
                result = inkview.DialogSynchro(
                    icon,
                    "KOReader",
                    removeBidiChars(args.text),
                    removeBidiChars(cancel_text),
                    removeBidiChars(ok_text),
                    third_button and removeBidiChars(third_button) or nil
                )
            end)
            
            PBNativeDialog.dialog_active = false
            
            if not status then
                logger.err("[PB Native Dialogs] DialogSynchro() failed: " .. tostring(err))
            end
            
            -- Close fake widget silently (no refresh)
            PBNativeDialog:silentClose(fake)
            
            -- Execute callback
            if status and result then
                -- Result: 1=Cancel, 2=OK, 3=Other
                if result == 2 and callbacks.ok then
                    pcall(callbacks.ok)
                elseif result == 1 and callbacks.cancel then
                    pcall(callbacks.cancel)
                elseif result == 3 and callbacks.other then
                    pcall(callbacks.other)
                end
            end
        end
        
        return fake
    end
    
    return original_confirmbox_new(self, args)
end

-- ============================================================================
-- LOGGING
-- ============================================================================

if PBNativeDialog.enabled then
    logger.info("[PB Native Dialogs] Patch applied: Sync mode + Silent Close + Long Text Detection")
else
    logger.warn("[PB Native Dialogs] Patch loaded but DISABLED")
end

return {
    InfoMessage = InfoMessage,
    ConfirmBox = ConfirmBox,
    PBNativeDialog = PBNativeDialog,
}