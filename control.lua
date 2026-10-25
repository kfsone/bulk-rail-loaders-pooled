-- Modern Bulk Rail Loaders: Pooled
--
-- Each station has one hidden "pool" container that owns all items. Every
-- visible silo is a proxy-container window onto that pool, so contents are
-- shared by construction and can never get unbalanced between wagons.
-- Wire ONE silo (any of them) to a circuit network to read the true station
-- total; wiring more than one multiplies the reading.

local SILO_NAME = "mbrlp-silo"
local POOL_NAME = "mbrlp-pool"
local INSERTER_NAME = "mbrlp-invisible-inserter"

local WAGON_SPACING = 7 -- distance between wagon centres

local silo_share = settings.startup["mbrlp-silo-capacity"].value

local function init_storage()
    storage.groups = storage.groups or {}                 -- group id (pool unit_number) -> group
    storage.stop_to_group = storage.stop_to_group or {}   -- train stop unit_number -> group id
    storage.silo_to_group = storage.silo_to_group or {}   -- silo unit_number -> group id
    storage.silo_inserters = storage.silo_inserters or {} -- silo unit_number -> cybersyn helper inserter
    storage.silo_sprites = storage.silo_sprites or {}     -- silo unit_number -> {LuaRenderObject}
    storage.gap_styles = storage.gap_styles or {}         -- train stop unit_number -> "compact"|"normal"|"extra"
    storage.ui_count = storage.ui_count or 5
end

-- ---------------------------------------------------------------------------
-- Groups and pools
-- ---------------------------------------------------------------------------

local function pool_inventory(group)
    return group.pool.get_inventory(defines.inventory.chest)
end

local function silo_count(group)
    local n = 0
    for _, silo in pairs(group.silos) do
        if silo.valid then n = n + 1 end
    end
    return n
end

local function update_pool_bar(group)
    local inv = pool_inventory(group)
    local usable = math.min(silo_count(group) * silo_share, #inv)
    inv.set_bar(usable + 1) -- the bar is the first *blocked* slot
end

-- existing_pool: adopt a pool that already exists in the save (state rebuild)
-- instead of creating a new one.
local function create_group(surface, position, force, stop, existing_pool)
    local pool = existing_pool
        or surface.create_entity{name = POOL_NAME, position = position, force = force}
    pool.destructible = false
    local group = {
        id = pool.unit_number,
        pool = pool,
        stop = stop,
        silos = {},
        mode = "load",
        vertical = stop and (stop.direction == defines.direction.north
                          or stop.direction == defines.direction.south) or nil
    }
    storage.groups[group.id] = group
    if stop then storage.stop_to_group[stop.unit_number] = group.id end
    return group
end

local function group_for_stop(stop)
    local group_id = storage.stop_to_group[stop.unit_number]
    local group = group_id and storage.groups[group_id]
    if group and group.pool.valid then return group end
    return create_group(stop.surface, stop.position, stop.force, stop)
end

-- ---------------------------------------------------------------------------
-- Silo visuals (mode-dependent: silo above the wagon / grate under it)
-- ---------------------------------------------------------------------------

local function destroy_silo_sprites(unit_number)
    local sprites = storage.silo_sprites[unit_number]
    if sprites then
        for _, obj in pairs(sprites) do
            if obj.valid then obj.destroy() end
        end
    end
    storage.silo_sprites[unit_number] = nil
end

local function redraw_silo(group, silo)
    destroy_silo_sprites(silo.unit_number)
    local sprites = {}
    if group.mode == "unload" then
        sprites[1] = rendering.draw_sprite{
            sprite = group.vertical and "mbrlp-unloader-vertical" or "mbrlp-unloader-horizontal",
            target = silo,
            surface = silo.surface,
            render_layer = "floor-mechanics" -- under the wagon, above the rails
        }
    else
        sprites[1] = rendering.draw_sprite{
            sprite = group.vertical and "mbrlp-loader-vertical" or "mbrlp-loader-horizontal",
            target = silo,
            surface = silo.surface,
            render_layer = "higher-object-above" -- hopper structure straddles the wagon
        }
    end
    storage.silo_sprites[silo.unit_number] = sprites
end

local function redraw_group(group)
    for _, silo in pairs(group.silos) do
        if silo.valid then redraw_silo(group, silo) end
    end
end

-- ---------------------------------------------------------------------------
-- Attaching / removing silos
-- ---------------------------------------------------------------------------

local function attach_silo(silo, group)
    if group.vertical == nil then
        local rail = silo.surface.find_entities_filtered{
            type = "straight-rail", position = silo.position, radius = 1
        }[1]
        group.vertical = not rail
            or rail.direction == defines.direction.north
            or rail.direction == defines.direction.south
    end

    silo.proxy_target_entity = group.pool
    silo.proxy_target_inventory = defines.inventory.chest
    group.silos[silo.unit_number] = silo
    storage.silo_to_group[silo.unit_number] = group.id
    update_pool_bar(group)
    redraw_silo(group, silo)

    if remote.interfaces["cybersyn"] then
        local inserter_pos = {x = silo.position.x, y = silo.position.y - 2}
        -- reuse a helper inserter that already exists (state rebuild) so we
        -- never stack duplicates
        local existing = silo.surface.find_entities_filtered{
            name = INSERTER_NAME, position = inserter_pos, radius = 1.5, limit = 1
        }[1]
        storage.silo_inserters[silo.unit_number] = existing or silo.surface.create_entity{
            name = INSERTER_NAME,
            position = inserter_pos,
            force = silo.force
        }
    end
end

local function forget_silo(unit_number)
    destroy_silo_sprites(unit_number)
    local inserter = storage.silo_inserters[unit_number]
    if inserter and inserter.valid then inserter.destroy() end
    storage.silo_inserters[unit_number] = nil
    storage.silo_to_group[unit_number] = nil
end

local function destroy_group(group)
    if group.pool.valid then group.pool.destroy() end
    if group.stop and group.stop.valid then
        storage.stop_to_group[group.stop.unit_number] = nil
    end
    storage.groups[group.id] = nil
end

-- Removal triggered by mining/death of a single silo. When the last silo of
-- a group disappears, spill whatever is left in the pool so nothing is lost.
local function detach_silo(unit_number)
    local group_id = storage.silo_to_group[unit_number]
    forget_silo(unit_number)

    local group = group_id and storage.groups[group_id]
    if not group then return end
    group.silos[unit_number] = nil

    if next(group.silos) then
        update_pool_bar(group)
        return
    end
    if group.pool.valid then
        local inv = pool_inventory(group)
        for i = 1, #inv do
            local stack = inv[i]
            if stack.valid_for_read then
                group.pool.surface.spill_item_stack{
                    position = group.pool.position,
                    stack = stack
                }
            end
        end
    end
    destroy_group(group)
end

-- Removal of every silo in a group at once (GUI rebuild). The pool and its
-- contents are kept.
local function remove_all_silos(group)
    for unit_number, silo in pairs(group.silos) do
        forget_silo(unit_number)
        if silo.valid then silo.destroy() end
        group.silos[unit_number] = nil
    end
end

local function clear_silo_ghosts(stop)
    local radius = 93
    local ghosts = stop.surface.find_entities_filtered{
        name = "entity-ghost",
        ghost_name = SILO_NAME,
        area = {
            {stop.position.x - radius, stop.position.y - radius},
            {stop.position.x + radius, stop.position.y + radius}
        }
    }
    for _, ghost in pairs(ghosts) do
        if ghost.valid then ghost.destroy() end
    end
end

-- ---------------------------------------------------------------------------
-- Wagon transfer
-- ---------------------------------------------------------------------------

local function stopped_wagon_at(silo)
    local wagon = silo.surface.find_entities_filtered{
        position = silo.position,
        type = "cargo-wagon",
        radius = 1,
        limit = 1
    }[1]
    if not wagon then return end

    local state = wagon.train.state
    local stopped = state == defines.train_state.wait_station
        or state == defines.train_state.manual_control_stop
        or (state == defines.train_state.manual_control and wagon.train.speed == 0)
    return stopped and wagon or nil
end

local function process_group(group)
    if not group.pool.valid then return end

    local wagon_invs = {}
    for unit_number, silo in pairs(group.silos) do
        if silo.valid then
            local wagon = stopped_wagon_at(silo)
            if wagon then
                wagon_invs[#wagon_invs + 1] = wagon.get_inventory(defines.inventory.cargo_wagon)
            end
        else
            detach_silo(unit_number)
        end
    end
    if #wagon_invs == 0 then return end

    local pool_inv = pool_inventory(group)
    if group.mode == "unload" then
        for _, wagon_inv in pairs(wagon_invs) do
            for _, item in pairs(wagon_inv.get_contents()) do
                local inserted = pool_inv.insert{name = item.name, count = item.count, quality = item.quality}
                if inserted > 0 then
                    wagon_inv.remove{name = item.name, count = inserted, quality = item.quality}
                end
            end
        end
    else
        -- Split each item type evenly across the wagons present, as if every
        -- hopper held its share. A wagon that can't take its share (full,
        -- filtered) leaves the rest to be re-split among the later wagons.
        for _, item in pairs(pool_inv.get_contents()) do
            local remaining = item.count
            for i, wagon_inv in pairs(wagon_invs) do
                local share = math.ceil(remaining / (#wagon_invs - i + 1))
                if share > 0 then
                    local inserted = wagon_inv.insert{name = item.name, count = share, quality = item.quality}
                    if inserted > 0 then
                        pool_inv.remove{name = item.name, count = inserted, quality = item.quality}
                        remaining = remaining - inserted
                    end
                end
                if remaining <= 0 then break end
            end
        end
    end
end

script.on_nth_tick(60, function()
    for _, group in pairs(storage.groups) do
        process_group(group)
    end
end)

-- Immediate transfer on arrival, only for the group at the stop the train
-- actually arrived at.
script.on_event(defines.events.on_train_changed_state, function(event)
    local train = event.train
    if train.state ~= defines.train_state.wait_station then return end
    local stop = train.station
    if not stop then return end
    local group_id = storage.stop_to_group[stop.unit_number]
    local group = group_id and storage.groups[group_id]
    if group then process_group(group) end
end)

-- ---------------------------------------------------------------------------
-- Placement along the track
-- ---------------------------------------------------------------------------

-- lateral: fixed offset from the stop onto the track centre.
-- axis: the direction trains extend away from the stop.
local RAIL_LAYOUT = {
    [defines.direction.north] = {lateral = {x = -2, y = 0}, axis = {x = 0, y = 1}},
    [defines.direction.east]  = {lateral = {x = 0, y = -2}, axis = {x = -1, y = 0}},
    [defines.direction.south] = {lateral = {x = 2, y = 0},  axis = {x = 0, y = -1}},
    [defines.direction.west]  = {lateral = {x = 0, y = 2},  axis = {x = 1, y = 0}}
}

local function wagon_offsets(count, gap_style)
    local offsets = {}
    for i = 1, count do
        local slot
        if gap_style == "compact" then
            slot = i - 1
        elseif gap_style == "extra" then
            slot = i + 1
        else
            slot = i
        end
        offsets[i] = slot * WAGON_SPACING + 3
    end
    return offsets
end

local function classify_position(surface, position)
    local area = {
        {position.x - 2, position.y - 2},
        {position.x + 2, position.y + 2}
    }
    for _, entity in pairs(surface.find_entities_filtered{area = area}) do
        local t = entity.type
        if entity.name ~= POOL_NAME
            and entity.name ~= INSERTER_NAME
            and t ~= "straight-rail"
            and t ~= "corpse"
            and t ~= "cargo-wagon"
            and t ~= "locomotive"
            and t ~= "character" then
            return "blocked"
        end
    end
    local rails = surface.find_entities_filtered{
        type = "straight-rail", position = position, radius = 1
    }
    return #rails > 0 and "free" or "no-rail"
end

local function cybersyn_refresh(stop)
    if not remote.interfaces["cybersyn"] then return end
    local combinators = stop.surface.find_entities_filtered{
        name = "cybersyn-combinator", position = stop.position, radius = 2.2
    }
    if combinators[1] then
        local stop_id = remote.call("cybersyn", "get_id_from_stop", stop)
        if stop_id then
            remote.call("cybersyn", "reset_stop_layout", stop_id, nil, true)
        end
    end
end

local function rebuild_silos(stop, count)
    local group = group_for_stop(stop)

    if count == 0 then
        if not pool_inventory(group).is_empty() then
            game.print("Cannot remove the loaders: the shared pool still contains items.")
            return
        end
        remove_all_silos(group)
        destroy_group(group)
        clear_silo_ghosts(stop)
        cybersyn_refresh(stop)
        return
    end

    remove_all_silos(group)
    clear_silo_ghosts(stop)

    local layout = RAIL_LAYOUT[stop.direction]
    if not layout then
        game.print("Bulk loaders only support straight north/east/south/west stations.")
        return
    end

    local placed, ghosts = 0, 0
    for _, offset in pairs(wagon_offsets(count, storage.gap_styles[stop.unit_number] or "normal")) do
        local position = {
            x = stop.position.x + layout.lateral.x + layout.axis.x * offset,
            y = stop.position.y + layout.lateral.y + layout.axis.y * offset
        }
        local kind = classify_position(stop.surface, position)
        if kind == "free" then
            local silo = stop.surface.create_entity{
                name = SILO_NAME, position = position, force = stop.force
            }
            attach_silo(silo, group)
            placed = placed + 1
        else
            stop.surface.create_entity{
                name = "entity-ghost", inner_name = SILO_NAME,
                position = position, force = stop.force, expires = false
            }
            ghosts = ghosts + 1
        end
        stop.surface.create_trivial_smoke{name = "smoke-fast", position = position}
    end

    if ghosts > 0 then
        game.print(string.format(
            "Placed %d silo(s) and %d ghost(s). Clear obstructions (or add rails) to revive the ghosts.",
            placed, ghosts))
    end
    cybersyn_refresh(stop)
end

-- Hand-placed or ghost-revived silos join the nearest station's group;
-- with no station in range they get a private pool.
local function auto_attach(silo)
    local stops = silo.surface.find_entities_filtered{
        type = "train-stop", position = silo.position, radius = 100
    }
    local best, best_score
    for _, stop in pairs(stops) do
        local dx = stop.position.x - silo.position.x
        local dy = stop.position.y - silo.position.y
        local score = dx * dx + dy * dy
        if storage.stop_to_group[stop.unit_number] then
            score = score - 1e9 -- strongly prefer stops that already have a group
        end
        if not best or score < best_score then
            best, best_score = stop, score
        end
    end
    local group
    if best then
        group = group_for_stop(best)
    else
        group = create_group(silo.surface, silo.position, silo.force, nil)
    end
    attach_silo(silo, group)
end

-- ---------------------------------------------------------------------------
-- State rebuild
-- ---------------------------------------------------------------------------
-- Script state lives in `storage`, which is keyed by mod name. When this mod
-- is added to a save that was made with another copy of it (e.g. the original
-- mod this one replaces) `storage` starts empty although the silos and pools
-- are still on the map. Re-register them exactly as live placement would.
-- Recovered from entities: silos, pool of each silo (proxy target), the train
-- stop (pool sits on the stop), orientation, gap style (inferred from the silo
-- layout), Cybersyn helper inserters (adopted). NOT recoverable: station mode
-- (defaults to "load"), the GUI's remembered wagon count, sprites (redrawn).

local function infer_gap_style(group, stop)
    local layout = RAIL_LAYOUT[stop.direction]
    if not layout then return nil end
    local min_slot
    for _, silo in pairs(group.silos) do
        if silo.valid then
            local dx = silo.position.x - stop.position.x - layout.lateral.x
            local dy = silo.position.y - stop.position.y - layout.lateral.y
            local offset = dx * layout.axis.x + dy * layout.axis.y
            local slot = (offset - 3) / WAGON_SPACING
            if math.abs(slot - math.floor(slot + 0.5)) > 0.01 then return nil end
            slot = math.floor(slot + 0.5)
            if not min_slot or slot < min_slot then min_slot = slot end
        end
    end
    return ({[0] = "compact", [1] = "normal", [2] = "extra"})[min_slot]
end

local function rebuild_state()
    init_storage()
    local rebuilt = {}
    local bars = {} -- pool unit_number -> inventory bar as found in the save
    for _, surface in pairs(game.surfaces) do
        for _, silo in pairs(surface.find_entities_filtered{name = SILO_NAME}) do
            if not storage.silo_to_group[silo.unit_number] then
                local pool = silo.proxy_target_entity
                if pool and pool.valid and pool.name == POOL_NAME then
                    local group = storage.groups[pool.unit_number]
                    if not group then
                        local stop = surface.find_entities_filtered{
                            type = "train-stop",
                            area = {
                                {pool.position.x - 0.5, pool.position.y - 0.5},
                                {pool.position.x + 0.5, pool.position.y + 0.5}
                            },
                            limit = 1
                        }[1]
                        if stop and storage.stop_to_group[stop.unit_number] then
                            stop = nil -- that stop already owns another group
                        end
                        bars[pool.unit_number] = pool_inventory({pool = pool}).get_bar()
                        group = create_group(surface, pool.position, pool.force, stop, pool)
                        rebuilt[#rebuilt + 1] = group
                    end
                    attach_silo(silo, group)
                else
                    auto_attach(silo) -- orphaned silo: behaves like a fresh placement
                end
            end
        end
    end
    for _, group in pairs(rebuilt) do
        -- attach_silo recomputed the bar from the current silo count; put back
        -- what the save had so capacity/behaviour is unchanged by the rename
        -- (it is recomputed on the next silo change as usual)
        if group.pool.valid and bars[group.id] then
            pool_inventory(group).set_bar(bars[group.id])
        end
        if group.stop and group.stop.valid and not storage.gap_styles[group.stop.unit_number] then
            storage.gap_styles[group.stop.unit_number] = infer_gap_style(group, group.stop)
        end
        log(string.format("[mbrlp] group %d: stop=%s gap=%s vertical=%s silos=%d mode=%s",
            group.id, group.stop and group.stop.valid and "yes" or "none",
            group.stop and group.stop.valid and tostring(storage.gap_styles[group.stop.unit_number]) or "n/a",
            tostring(group.vertical), table_size(group.silos), group.mode))
    end
    if #rebuilt > 0 then
        log(string.format("[mbrlp] state rebuilt: %d station group(s); mode defaulted to load", #rebuilt))
        game.print(string.format(
            "Bulk loaders: re-registered %d station(s) from the map. Station mode could not be recovered and is set to Load; open each unloading stop and switch it back to Unload.",
            #rebuilt))
    end
end

script.on_init(rebuild_state)
script.on_configuration_changed(rebuild_state)

script.on_event({
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive
}, function(event)
    local entity = event.entity
    if entity and entity.valid and entity.name == SILO_NAME then
        auto_attach(entity)
    end
end)

script.on_event({
    defines.events.on_entity_died,
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity
}, function(event)
    local entity = event.entity
    if entity.name == SILO_NAME then
        detach_silo(entity.unit_number)
    elseif entity.type == "train-stop" then
        local group_id = storage.stop_to_group[entity.unit_number]
        storage.stop_to_group[entity.unit_number] = nil
        local group = group_id and storage.groups[group_id]
        if group then group.stop = nil end
    end
end)

-- ---------------------------------------------------------------------------
-- GUI
-- ---------------------------------------------------------------------------

local function build_stop_gui(player, stop)
    local gui = player.gui.relative
    if gui["mbrlp-frame"] then gui["mbrlp-frame"].destroy() end

    local frame = gui.add{
        type = "frame",
        name = "mbrlp-frame",
        direction = "vertical",
        caption = "Bulk loaders",
        anchor = {
            gui = defines.relative_gui_type.train_stop_gui,
            position = defines.relative_gui_position.left
        }
    }

    frame.add{type = "label", name = "mbrlp-count-label",
        caption = "Wagons: " .. storage.ui_count}.style.font = "heading-2"
    local adjust = frame.add{type = "flow", direction = "horizontal"}
    adjust.add{type = "button", name = "mbrlp-minus", caption = "-"}.style.maximal_width = 52
    adjust.add{type = "button", name = "mbrlp-plus", caption = "+"}.style.maximal_width = 52

    local buttons = frame.add{type = "flow", name = "mbrlp-buttons", direction = "vertical"}
    for i = 0, storage.ui_count do
        buttons.add{
            type = "button",
            name = "mbrlp-count-" .. i,
            caption = tostring(i),
            tags = {count = i}
        }
    end

    frame.add{type = "label", caption = "Locomotives in front:"}
    local gaps = frame.add{type = "flow", direction = "horizontal"}
    for caption, style in pairs({["0"] = "compact", ["1"] = "normal", ["2"] = "extra"}) do
        gaps.add{
            type = "button",
            name = "mbrlp-gap-" .. style,
            caption = caption,
            tags = {gap_style = style}
        }.style.maximal_width = 34
    end

    local group_id = storage.stop_to_group[stop.unit_number]
    local group = group_id and storage.groups[group_id]
    frame.add{type = "label", caption = "Station mode:"}
    frame.add{
        type = "switch",
        name = "mbrlp-mode",
        switch_state = (group and group.mode == "unload") and "right" or "left",
        left_label_caption = "Load",
        right_label_caption = "Unload"
    }
end

script.on_event(defines.events.on_gui_opened, function(event)
    if event.gui_type ~= defines.gui_type.entity then return end
    local entity = event.entity
    if entity and entity.valid and entity.type == "train-stop" then
        build_stop_gui(game.players[event.player_index], entity)
    end
end)

script.on_event(defines.events.on_gui_closed, function(event)
    if event.gui_type ~= defines.gui_type.entity then return end
    local gui = game.players[event.player_index].gui.relative
    if gui["mbrlp-frame"] then gui["mbrlp-frame"].destroy() end
end)

local function opened_stop(player)
    local opened = player.opened
    if opened and opened.object_name == "LuaEntity" and opened.type == "train-stop" then
        return opened
    end
end

script.on_event(defines.events.on_gui_click, function(event)
    local element = event.element
    if not (element and element.valid) then return end
    local name = element.name
    local player = game.players[event.player_index]

    if name == "mbrlp-plus" or name == "mbrlp-minus" then
        storage.ui_count = math.max(0, storage.ui_count + (name == "mbrlp-plus" and 1 or -1))
        local stop = opened_stop(player)
        if stop then build_stop_gui(player, stop) end
    elseif name:match("^mbrlp%-count%-") then
        local stop = opened_stop(player)
        if stop then rebuild_silos(stop, element.tags.count) end
    elseif name:match("^mbrlp%-gap%-") then
        local stop = opened_stop(player)
        if stop then storage.gap_styles[stop.unit_number] = element.tags.gap_style end
    end
end)

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
    local element = event.element
    if not (element and element.valid and element.name == "mbrlp-mode") then return end
    local player = game.players[event.player_index]
    local stop = opened_stop(player)
    if not stop then return end

    local group = group_for_stop(stop)
    group.mode = element.switch_state == "right" and "unload" or "load"
    redraw_group(group)
    if not pool_inventory(group).is_empty() then
        player.print("Note: the shared pool still contains items; they now follow the new mode.")
    end
end)
