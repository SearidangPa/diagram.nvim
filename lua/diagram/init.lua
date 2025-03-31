local image_nvim = require("image")
local integrations = require("diagram/integrations")

---@class State
local state = {
	events = {
		clear_buffer = { "InsertEnter", "CursorMoved" },
	},
	renderer_options = {
		mermaid = {
			background = nil,
			theme = nil,
			scale = nil,
			width = nil,
			height = nil,
		},
	},
	integrations = {
		integrations.markdown,
	},
	diagrams = {},
}

local clear_buffer = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	for _, diagram in ipairs(state.diagrams) do
		if diagram.bufnr == bufnr and diagram.image ~= nil then
			diagram.image:clear()
		end
	end
end

---@param bufnr number
---@param winnr number
---@param integration Integration
local render_buffer = function(bufnr, winnr, integration)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	winnr = winnr or vim.api.nvim_get_current_win()

	local diagrams = integration.query_buffer_diagrams(bufnr)
	clear_buffer(bufnr)
	for _, diagram in ipairs(diagrams) do
		---@type Renderer
		local renderer = nil
		for _, r in ipairs(integration.renderers) do
			if r.id == diagram.renderer_id then
				renderer = r
				break
			end
		end
		assert(renderer, "diagram: cannot find renderer with id `" .. diagram.renderer_id .. "`")

		local renderer_options = state.renderer_options[renderer.id] or {}
		local renderer_result = renderer.render(diagram.source, renderer_options)

		local function render_image()
			if vim.fn.filereadable(renderer_result.file_path) == 0 then
				return
			end

			local diagram_col = diagram.range.start_col
			local diagram_row = diagram.range.start_row
			if vim.bo[bufnr].filetype == "norg" then
				diagram_row = diagram_row - 1
			end

			local image = image_nvim.from_file(renderer_result.file_path, {
				buffer = bufnr,
				window = winnr,
				with_virtual_padding = true,
				inline = true,
				x = diagram_col,
				y = diagram_row,
			})
			diagram.image = image

			table.insert(state.diagrams, diagram)
			image:render()
		end

		if renderer_result.job_id then
			-- Use a timer to poll the job's completion status every 100ms.
			local timer = vim.loop.new_timer()
			if not timer then
				return
			end
			timer:start(
				0,
				100,
				vim.schedule_wrap(function()
					local result = vim.fn.jobwait({ renderer_result.job_id }, 0)
					if result[1] ~= -1 then
						if timer:is_active() then
							timer:stop()
						end
						if not timer:is_closing() then
							timer:close()
							render_image()
						end
					end
				end)
			)
		else
			render_image()
		end
	end
end

-- Function to render diagrams in the current buffer
local render_diagrams = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local ft = vim.bo[bufnr].filetype

	-- Find the right integration for the current filetype
	for _, integration in ipairs(state.integrations) do
		if vim.tbl_contains(integration.filetypes, ft) then
			render_buffer(bufnr, winnr, integration)
			return
		end
	end

	vim.notify("No integration found for filetype: " .. ft, vim.log.levels.WARN)
end

---@param opts PluginOptions
local setup = function(opts)
	local ok = pcall(require, "image")
	if not ok then
		error("diagram: missing dependency `3rd/image.nvim`")
	end

	state.integrations = opts.integrations or state.integrations
	state.renderer_options = vim.tbl_deep_extend("force", state.renderer_options, opts.renderer_options or {})

	-- Create user commands
	vim.api.nvim_create_user_command("DiagramRender", function()
		render_diagrams()
	end, {
		desc = "Render diagrams in the current buffer",
	})

	vim.api.nvim_create_user_command("DiagramClear", function()
		clear_buffer()
	end, {
		desc = "Clear diagrams in the current buffer",
	})

	-- Setup autocommand for clearing on insert mode
	local setup_buffer_autocmds = function(bufnr)
		-- Only set up the clear autocmd
		if state.events.clear_buffer then
			vim.api.nvim_create_autocmd(state.events.clear_buffer, {
				buffer = bufnr,
				callback = function()
					clear_buffer(bufnr)
				end,
			})
		end
	end

	-- Create autocommands for buffer events
	for _, integration in ipairs(state.integrations) do
		vim.api.nvim_create_autocmd("FileType", {
			pattern = integration.filetypes,
			callback = function(ft_event)
				setup_buffer_autocmds(ft_event.buf)
			end,
		})

		-- Set up autocommands for the current buffer if it matches
		local current_bufnr = vim.api.nvim_get_current_buf()
		local current_ft = vim.bo[current_bufnr].filetype
		if vim.tbl_contains(integration.filetypes, current_ft) then
			setup_buffer_autocmds(current_bufnr)
		end
	end
end

local get_cache_dir = function()
	return vim.fn.stdpath("cache") .. "/diagram-cache"
end

return {
	setup = setup,
	get_cache_dir = get_cache_dir,
	render_diagrams = render_diagrams,
	clear_buffer = clear_buffer,
}
