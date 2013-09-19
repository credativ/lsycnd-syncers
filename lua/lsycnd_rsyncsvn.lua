rsyncsvn = {}

local function run_sync (inlet, event, src, host, target)
	local dst = host .. ':' .. target

	-- sync current file first
	spawn(
		event,
		'/usr/bin/rsync',
		'-a',
		src .. "/db/current",
		dst .. "/db/current"
	)

	-- sync rest after that
	-- create blank event for second rsync call
	event = inlet.createBlanketEvent()
	spawn(
		event,
		'/usr/bin/rsync',
		'-a',
		'--exclude', 'db/current',
		'--exclude', 'db/transactions/*',
		'--exclude', 'db/log.*',
		src, dst
	)
end

rsyncsvn.delay = 3

--
-- startup method
--
rsyncsvn.init = function(event)
    local config    = event.config
    local inlet	= event.inlet
    log('Normal', 'Initial svn sync: ' .. config.source .. ' -> ' .. config.host)
    run_sync(inlet, event, config.source, config.host, config.target)
end


--
-- method to be run on each action
--
rsyncsvn.action = function(inlet)
    local config    = inlet.getConfig()
    local elist     = inlet.getEvents()
    log('Normal', 'Syncing svn repo: ' .. config.source .. ' -> ' .. config.host)
    run_sync(inlet, elist, config.source, config.host, config.target)
end
