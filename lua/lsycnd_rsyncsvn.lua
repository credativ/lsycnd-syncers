lsyncd.rsyncsvn = {}

local function run_sync (inlet, event, src, host, target)
	local dst = host .. ':' .. target

	-- sync current file first
	spawn(
		event,
		'/usr/bin/rsync',
		'-av',
		src .. "/db/current",
		dst .. "/db/current"
	)

	-- sync rest after that
	-- create blank event for second rsync call
	event = inlet.createBlanketEvent()
	spawn(
		event,
		'/usr/bin/rsync',
		'-av',
		'--exclude', 'db/current',
		'--exclude', 'db/transactions/*',
		'--exclude', 'db/log.*',
		src, dst
	)
end

lsycnd.rsyncsvn = {
        delay = 3,
        init = function(event)
                local config    = event.config
		local inlet	= event.inlet
                log('Normal', 'Initial SVN sync ' .. config.source .. ' -> ' .. config.host)
       		run_sync(inlet, event, config.source, config.host, config.target)
	end,
        action = function(inlet)
                local config    = inlet.getConfig()
                local elist     = inlet.getEvents()
                log('Normal', 'Sync SVN ' .. config.source .. ' -> ' .. config.host)
		run_sync(inlet, elist, config.source, config.host, config.target)
        end
}
