-- User patch for displaying book cover during document loading
-- Place this file in koreader/patches/

local logger = require("logger")
local UIManager = require("ui/uimanager")
local ImageWidget = require("ui/widget/imagewidget")
local Screen = require("device").screen
local lfs = require("libs/libkoreader-lfs")
local DocumentRegistry = require("document/documentregistry")

logger.info("BookLoadCover patch: initializing")

-- Configuration
local enabled = G_reader_settings:nilOrTrue("bookloadcover_enabled")
local cover_widget = nil
local cover_bb_cache = nil -- store extracted cover to free it later
local BookInfoManager = nil
local FileManagerBookInfo = nil

-- Lazy load modules
local function getBookInfoManager()
    if BookInfoManager then
        return BookInfoManager
    end
    
    local plugin_path = "plugins/coverbrowser.koplugin"
    if lfs.attributes(plugin_path, "mode") == "directory" then
        package.path = plugin_path .. "/?.lua;" .. package.path
        
        local ok, module = pcall(require, "bookinfomanager")
        if ok then
            BookInfoManager = module
            logger.info("BookLoadCover patch: loaded BookInfoManager")
            return BookInfoManager
        else
            logger.warn("BookLoadCover patch: failed to load BookInfoManager:", module)
        end
    else
        logger.warn("BookLoadCover patch: CoverBrowser plugin directory not found")
    end
    
    return nil
end

local function getFileManagerBookInfo()
    if FileManagerBookInfo then
        return FileManagerBookInfo
    end
    
    local ok, module = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if ok then
        FileManagerBookInfo = module
        logger.info("BookLoadCover patch: loaded FileManagerBookInfo")
        return FileManagerBookInfo
    else
        logger.warn("BookLoadCover patch: failed to load FileManagerBookInfo:", module)
    end
    
    return nil
end

-- Function to get cover from CoverImage cache
local function getCoverFromCoverImageCache(filepath)
    logger.info("BookLoadCover patch: checking CoverImage cache")
    
    -- Get CoverImage settings
    local cache_path = G_reader_settings:readSetting("cover_image_cache_path")
    if not cache_path then
        logger.info("BookLoadCover patch: CoverImage cache path not configured")
        return nil
    end
    
    if lfs.attributes(cache_path, "mode") ~= "directory" then
        logger.info("BookLoadCover patch: CoverImage cache directory doesn't exist")
        return nil
    end
    
    -- Build cache key similar to CoverImage:getCacheFile()
    local util = require("util")
    local md5 = require("ffi/sha2").md5
    local dummy, document_name = util.splitFilePathName(filepath)
    
    local quality = G_reader_settings:readSetting("cover_image_quality", 75)
    local stretch_limit = G_reader_settings:readSetting("cover_image_stretch_limit", 8)
    local background = G_reader_settings:readSetting("cover_image_background", "black")
    local format = G_reader_settings:readSetting("cover_image_format", "auto")
    local grayscale = G_reader_settings:isTrue("cover_image_grayscale")
    local rotate = G_reader_settings:readSetting("cover_image_rotate", true)
    local rotated = rotate and "_rotated_" or ""
    
    local key = document_name .. quality .. stretch_limit .. background .. format .. 
                tostring(grayscale) .. Screen:getRotationMode() .. rotated
    
    local cache_prefix = "cover_"
    local cover_path = G_reader_settings:readSetting("cover_image_path")
    local ext = "jpg" -- default
    
    if cover_path then
        ext = util.getFileNameSuffix(cover_path):lower()
    end
    
    local cache_file = cache_path .. cache_prefix .. md5(key) .. "." .. ext
    
    logger.info("BookLoadCover patch: looking for cache file:", cache_file)
    
    if lfs.attributes(cache_file, "mode") == "file" then
        logger.info("BookLoadCover patch: found CoverImage cache file")
        
        -- Load image from file
        local RenderImage = require("ui/renderimage")
        local ok, cover_bb = pcall(function()
            return RenderImage:renderImageFile(cache_file)
        end)
        
        if ok and cover_bb then
            logger.info("BookLoadCover patch: successfully loaded from CoverImage cache")
            return cover_bb, true -- true = needs to be freed
        else
            logger.warn("BookLoadCover patch: failed to load cache file:", cover_bb)
        end
    end
    
    return nil
end

-- Function to get cover from BookInfoManager DB
local function getCoverFromDB(filepath)
    local BIM = getBookInfoManager()
    if not BIM then
        return nil
    end
    
    local bookinfo = BIM:getBookInfo(filepath, true) -- true = get cover
    
    if not bookinfo then
        logger.info("BookLoadCover patch: no bookinfo found in DB for", filepath)
        return nil
    end
    
    if not bookinfo.has_cover or bookinfo.ignore_cover then
        logger.info("BookLoadCover patch: book has no cover or cover is ignored")
        return nil
    end
    
    if not bookinfo.cover_bb then
        logger.info("BookLoadCover patch: cover blitbuffer not available")
        return nil
    end
    
    logger.info("BookLoadCover patch: found cover in DB")
    return bookinfo.cover_bb, false -- false = don't free (managed by BIM)
end

-- Function to extract cover directly from document
local function extractCoverFromDocument(filepath)
    logger.info("BookLoadCover patch: attempting to extract cover from document")
    
    if not DocumentRegistry:hasProvider(filepath) then
        logger.info("BookLoadCover patch: no document provider for", filepath)
        return nil
    end
    
    local FMBI = getFileManagerBookInfo()
    if not FMBI then
        logger.warn("BookLoadCover patch: FileManagerBookInfo not available")
        return nil
    end
    
    -- Try to open document and extract cover
    local ok, cover_bb = pcall(function()
        local ReaderUI = require("apps/reader/readerui")
        local provider = ReaderUI:extendProvider(filepath, DocumentRegistry:getProvider(filepath))
        local document = DocumentRegistry:openDocument(filepath, provider)
        
        if not document then
            return nil
        end
        
        local cover = nil
        
        -- For CreDocument, we need to load metadata
        if document.loadDocument then
            local loaded = document:loadDocument(false) -- load only metadata
            if loaded then
                cover = FMBI:getCoverImage(document)
            end
        else
            cover = FMBI:getCoverImage(document)
        end
        
        document:close()
        return cover
    end)
    
    if ok and cover_bb then
        logger.info("BookLoadCover patch: successfully extracted cover from document")
        return cover_bb, true -- true = needs to be freed
    else
        logger.info("BookLoadCover patch: failed to extract cover:", cover_bb or "unknown error")
        return nil
    end
end

-- Function to show cover
local function showCover(filepath)
    if not enabled then
        return false
    end
    
    logger.info("BookLoadCover patch: attempting to show cover for", filepath)
    
    local cover_bb, needs_free
    
    -- Priority 1: CoverImage cache (fastest, pre-scaled)
    cover_bb, needs_free = getCoverFromCoverImageCache(filepath)
    
    -- Priority 2: CoverBrowser DB (fast, original quality)
    if not cover_bb then
        cover_bb, needs_free = getCoverFromDB(filepath)
    end
    
    -- Priority 3: Extract from document (slow)
    if not cover_bb then
        cover_bb, needs_free = extractCoverFromDocument(filepath)
    end
    
    if not cover_bb then
        logger.info("BookLoadCover patch: no cover available")
        return false
    end
    
    -- Store reference if we need to free it later
    if needs_free then
        cover_bb_cache = cover_bb
    end
    
    -- Create image widget with the blitbuffer
    local s_w, s_h = Screen:getWidth(), Screen:getHeight()
    
    cover_widget = ImageWidget:new{
        image = cover_bb,
        width = s_w,
        height = s_h,
        alpha = true,
        image_disposable = false,
    }
    
    UIManager:show(cover_widget, "full")
    UIManager:forceRePaint()
    logger.info("BookLoadCover patch: cover displayed")
    
    return true
end

-- Function to close cover
local function closeCover()
    if cover_widget then
        logger.info("BookLoadCover patch: closing cover")
        UIManager:close(cover_widget)
        cover_widget = nil
    end
    
    -- Free cached blitbuffer if we own it
    if cover_bb_cache then
        cover_bb_cache:free()
        cover_bb_cache = nil
    end
    
    -- Close DB connection to free resources
    local BIM = getBookInfoManager()
    if BIM then
        BIM:closeDbConnection()
    end
end

-- Hook into ReaderUI
local ReaderUI = require("apps/reader/readerui")

-- Store original method
if not ReaderUI._original_showReaderCoroutine_bookloadcover then
    ReaderUI._original_showReaderCoroutine_bookloadcover = ReaderUI.showReaderCoroutine
    
    -- Override showReaderCoroutine
    ReaderUI.showReaderCoroutine = function(self, file, provider, seamless)
        logger.info("BookLoadCover patch: intercepting showReaderCoroutine for", file)
        
        -- Show cover if enabled and available
        local cover_shown = showCover(file)
        
        -- Call original method
        -- If cover was shown, set seamless=true to hide InfoMessage
        return ReaderUI._original_showReaderCoroutine_bookloadcover(
            self, file, provider, cover_shown or seamless
        )
    end
    
    logger.info("BookLoadCover patch: successfully patched ReaderUI.showReaderCoroutine")
end

-- Hook into ReaderUI:init to close cover when reader is ready
if not ReaderUI._original_init_bookloadcover then
    ReaderUI._original_init_bookloadcover = ReaderUI.init
    
    ReaderUI.init = function(self, ...)
        -- Call original init
        local ret = ReaderUI._original_init_bookloadcover(self, ...)
        
        -- Schedule cover close after ReaderReady event
        UIManager:scheduleIn(0.1, function()
            closeCover()
        end)
        
        return ret
    end
end

logger.info("BookLoadCover patch: initialized successfully")