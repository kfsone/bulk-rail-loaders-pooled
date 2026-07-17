local util = require("util")

local silo_share = settings.startup["mbrlp-silo-capacity"].value
local max_silos = settings.startup["mbrlp-max-silos"].value

-- Visible silo: a proxy-container window onto the station's shared pool.
-- It has no inventory of its own; all interactions (players, inserters,
-- circuit reads) are forwarded to the pool container at runtime.
local silo = {
    type = "proxy-container",
    name = "mbrlp-silo",
    icon = "__base__/graphics/icons/steel-chest.png",
    icon_size = 64,
    flags = {"player-creation"},
    minable = {mining_time = 1, result = "mbrlp-silo", count = 0},
    max_health = 350,
    collision_box = {{-1.8, -1.8}, {1.8, 1.8}},
    selection_box = {{-1.85, -1.85}, {1.85, 1.85}},
    draw_inventory_content = true,
    circuit_wire_max_distance = 9,
    -- keep the alt-mode content icons small and on the entity itself
    -- (they overlay the tipper grate / hopper instead of floating above)
    icon_draw_specification = {shift = {0, 0.4}, scale = 0.8, scale_for_many = 1.2}
}

-- Hidden shared inventory, one per station. Capacity for the maximum silo
-- count; the usable size is clamped at runtime with set_bar().
local pool = {
    type = "container",
    name = "mbrlp-pool",
    icon = "__base__/graphics/icons/steel-chest.png",
    icon_size = 64,
    hidden = true,
    flags = {
        "placeable-off-grid", "not-on-map", "not-blueprintable",
        "not-deconstructable", "no-copy-paste", "not-upgradable", "not-flammable"
    },
    max_health = 100,
    collision_box = {{0, 0}, {0, 0}},
    collision_mask = {layers = {}},
    selectable_in_game = false,
    inventory_type = "with_bar",
    inventory_size = silo_share * max_silos,
    picture = util.empty_sprite()
}

local silo_item = {
    type = "item",
    name = "mbrlp-silo",
    icon = "__base__/graphics/icons/steel-chest.png",
    icon_size = 64,
    subgroup = "storage",
    order = "b[storage]-c[mbrlp-silo]",
    place_result = "mbrlp-silo",
    stack_size = 50
}

-- Mode-dependent visuals, drawn at runtime so a station can switch between
-- them: a silo above the wagon when loading, a tipper grate under the rails
-- when unloading.
local sprites = {
    {
        type = "sprite",
        name = "mbrlp-loader-horizontal",
        filename = "__modern-bulk-rail-loader-pooled__/graphics/loader-horizontal.png",
        width = 188,
        height = 210,
        shift = util.by_pixel(0, -16)
    },
    {
        type = "sprite",
        name = "mbrlp-loader-vertical",
        filename = "__modern-bulk-rail-loader-pooled__/graphics/loader-vertical.png",
        width = 188,
        height = 210,
        shift = util.by_pixel(0, -16)
    },
    {
        type = "sprite",
        name = "mbrlp-unloader-horizontal",
        filename = "__modern-bulk-rail-loader-pooled__/graphics/unloader-horizontal.png",
        width = 384,
        height = 256,
        scale = 0.5
    },
    {
        type = "sprite",
        name = "mbrlp-unloader-vertical",
        filename = "__modern-bulk-rail-loader-pooled__/graphics/unloader-vertical.png",
        width = 256,
        height = 384,
        scale = 0.5
    }
}

-- Invisible inserter so Cybersyn's stop-layout scan recognises the silos as
-- loading equipment. Only ever created when Cybersyn is present.
local invisible_inserter = table.deepcopy(data.raw["inserter"]["fast-inserter"])
invisible_inserter.name = "mbrlp-invisible-inserter"
invisible_inserter.minable = nil
invisible_inserter.next_upgrade = nil
invisible_inserter.fast_replaceable_group = nil
invisible_inserter.collision_box = {{-0.15, -0.15}, {0.15, 0.15}}
invisible_inserter.selection_box = {{-0.1, -0.1}, {0.1, 0.1}}
invisible_inserter.selectable_in_game = false
invisible_inserter.energy_source = {type = "void"}
local empty_picture = {
    filename = "__core__/graphics/empty.png",
    priority = "extra-high",
    width = 1,
    height = 1,
    frame_count = 1
}
invisible_inserter.hand_base_picture = empty_picture
invisible_inserter.hand_closed_picture = empty_picture
invisible_inserter.hand_open_picture = empty_picture
invisible_inserter.hand_base_shadow = empty_picture
invisible_inserter.hand_closed_shadow = empty_picture
invisible_inserter.hand_open_shadow = empty_picture
invisible_inserter.platform_picture = {sheet = empty_picture}
invisible_inserter.draw_held_item = false

data:extend{silo, pool, silo_item, invisible_inserter}
data:extend(sprites)
