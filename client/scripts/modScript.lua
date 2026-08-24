local EXT_NAME = "highbeam"
local LOG_TAG = "HighBeam.Bootstrap"
local SUPPORTED_MAJOR = 0
local SUPPORTED_MINOR = 39

local function detectedBeamNGVersion()
	local candidates = { rawget(_G, 'beamng_version'), rawget(_G, 'beamng_versionb') }
	if Engine and Engine.getVersion then
		local ok, value = pcall(Engine.getVersion)
		if ok then candidates[#candidates + 1] = value end
	end
	for _, value in ipairs(candidates) do
		local major, minor = tostring(value or ''):match('(%d+)%.(%d+)')
		if major and minor then return tonumber(major), tonumber(minor), tostring(value) end
	end
	return nil, nil, nil
end

local function isSupportedBeamNGVersion()
	local major, minor, version = detectedBeamNGVersion()
	if not major then
		log('W', LOG_TAG, 'Could not determine BeamNG.drive version; continuing with the 0.39 compatibility path')
		return true
	end
	if major == SUPPORTED_MAJOR and minor == SUPPORTED_MINOR then
		log('I', LOG_TAG, 'BeamNG.drive compatibility check passed: ' .. version)
		return true
	end
	local message = 'HighBeam currently supports BeamNG.drive 0.39.x; detected ' .. version
	log('E', LOG_TAG, message)
	if rawget(_G, 'ui_message') then pcall(ui_message, message, 12, 'HighBeam compatibility', 'error') end
	return false
end

local function setManualUnloadMode()
	if extensions and rawget(extensions, 'setExtensionUnloadMode') then
		local ok_mode, err_mode = pcall(extensions.setExtensionUnloadMode, EXT_NAME, 'manual')
		if not ok_mode then
			log('W', LOG_TAG, 'Failed to set unload mode via extensions.setExtensionUnloadMode: ' .. tostring(err_mode))
		end
	else
		-- Use rawget to avoid triggering BeamNG extension auto-loader
		local globalFn = rawget(_G, 'setExtensionUnloadMode')
		if globalFn then
			local ok_mode, err_mode = pcall(globalFn, EXT_NAME, 'manual')
			if not ok_mode then
				log('W', LOG_TAG, 'Failed to set unload mode via global setExtensionUnloadMode: ' .. tostring(err_mode))
			end
		end
	end
end

local function bootstrap()
	if not isSupportedBeamNGVersion() then return end
	-- Guard: skip if the extension is already loaded (prevents state wipe on modDB re-init)
	if extensions and extensions[EXT_NAME] then
		log('I', LOG_TAG, 'Extension already loaded, skipping bootstrap: ' .. EXT_NAME)
		return
	end

	if extensions and extensions.load then
		local ok, err = pcall(extensions.load, EXT_NAME)
		if not ok then
			log('E', LOG_TAG, 'Failed to load extension via extensions.load: ' .. tostring(err))
			return
		end
		log('I', LOG_TAG, 'Loaded extension via extensions.load: ' .. EXT_NAME)
		setManualUnloadMode()
		return
	end

	if load then
		-- Fallback for older environments that expose extension loading via global load().
		local ok, err = pcall(load, EXT_NAME)
		if not ok then
			log('E', LOG_TAG, 'Failed to load extension via global load: ' .. tostring(err))
			return
		end
		log('I', LOG_TAG, 'Loaded extension via global load: ' .. EXT_NAME)
		setManualUnloadMode()
		return
	end

	log('E', LOG_TAG, 'No extension loader API found in this environment')
end

bootstrap()
