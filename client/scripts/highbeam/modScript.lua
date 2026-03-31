local EXT_NAME = "highbeam"

if extensions and extensions.load then
	local ok, err = pcall(extensions.load, EXT_NAME)
	if not ok then
		log('E', 'HighBeam.Bootstrap', 'Failed to load extension via extensions.load: ' .. tostring(err))
	end

	if extensions.setExtensionUnloadMode then
		local ok_mode, err_mode = pcall(extensions.setExtensionUnloadMode, EXT_NAME, 'manual')
		if not ok_mode then
			log(
				'W',
				'HighBeam.Bootstrap',
				'Failed to set unload mode via extensions.setExtensionUnloadMode: ' .. tostring(err_mode)
			)
		end
	elseif setExtensionUnloadMode then
		-- Older environments expose setExtensionUnloadMode globally.
		pcall(setExtensionUnloadMode, EXT_NAME, 'manual')
	end
elseif load then
	-- Fallback for older environments that expose extension loading via global load().
	local ok, err = pcall(load, EXT_NAME)
	if not ok then
		log('E', 'HighBeam.Bootstrap', 'Failed to load extension via global load: ' .. tostring(err))
	end

	if setExtensionUnloadMode then
		pcall(setExtensionUnloadMode, EXT_NAME, 'manual')
	end
else
	log('E', 'HighBeam.Bootstrap', 'No extension loader API found in this environment')
end
