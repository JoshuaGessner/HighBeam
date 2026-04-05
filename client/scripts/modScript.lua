local EXT_NAME = "highbeam"
local LOG_TAG = "HighBeam.Bootstrap"

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
